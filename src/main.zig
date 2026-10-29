const clap = @import("clap");
const std = @import("std");

const lex = @import("lex.zig");
const parse = @import("parse.zig");
const sema = @import("sema.zig");
const tknprint = @import("tknprint.zig");
const astprint = @import("astprint.zig");

const CLIArgs = struct {
    help: u32,
    slow: u32,
    ast: u32,
    tokens: u32,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this message
        \\-s, --slow            Artificially slow down the compiler (use this if you want to debug or if you want to see progress)
        \\-a, --ast             Print the AST instead of compiling it
        \\-t, --tokens          Print the tokens instead of compiling it
        \\<FILE>...             The source file to compile (.msh)
    );

    const parsers = comptime .{
        .STR = clap.parsers.string,
        .FILE = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0 or res.positionals[0].len == 0) {
        std.debug.print("Mish compiler v0.0.2p\n\nUsage:\n", .{});
        return clap.helpToFile(io, .stderr(), clap.Help, &params, .{});
    }

    for (res.positionals[0]) |path| {
        const args = CLIArgs{
            .ast = res.args.ast,
            .help = res.args.help,
            .slow = res.args.slow,
            .tokens = res.args.tokens,
        };
        try compileFile(path, init, args);
    }
}

fn compileFile(path: []const u8, init: std.process.Init, args: CLIArgs) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    if (!std.mem.eql(u8, std.fs.path.extension(path), ".msh")) {
        std.log.err("file must have a .msh extension: {s}", .{path});
        std.process.exit(1);
    }

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.log.err("failed opening file '{s}': {}", .{ path, err });
        std.process.exit(1);
    };
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    const source = reader.interface.allocRemaining(allocator, .unlimited) catch |err| {
        std.log.err("could not read file '{s}': {}", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const progress_name = try std.fmt.allocPrint(allocator, "Compile {s}", .{std.fs.path.basename(path)});
    defer allocator.free(progress_name);

    var root_progress = std.Progress.start(io, .{ .root_name = progress_name });
    defer root_progress.end();

    /////////////////////////////////// lexer
    var lexer = lex.Lexer.init(source, path);
    var lexer_progress = root_progress.start("Lexer", source.len / 12 + 3);
    const tokens = lexer.run(arena, lexer_progress, args.slow != 0, if (args.slow != 0) io else null) catch std.process.exit(1);
    lexer_progress.end();

    if (args.tokens != 0) {
        try tknprint.print(tokens, source, io, arena);
        return;
    }

    /////////////////////////////////// parser
    var parser_progress = root_progress.start("Parser", tokens.len / 25);
    if (args.slow != 0) {
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(150), .awake);
    }
    var parser = parse.Parser.init(arena, io, tokens, source, path, parser_progress, args.slow != 0);
    const ast = parser.run() catch std.process.exit(1);
    parser_progress.end();

    if (args.ast != 0) {
        astprint.printAst(ast, 0);
        return;
    }

    /////////////////////////////////// sema
    var checker_progress = root_progress.start("Semantic Analysis", ast.len);
    var checker = sema.Checker.init(arena, io, ast, tokens, parser.types, source, path, &checker_progress, args.slow != 0);
    try checker.run();
    checker_progress.end();
}
