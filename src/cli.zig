const std = @import("std");

const CmdFn = *const fn (writer: *std.Io.Writer, init: std.process.Init, args: []const [:0]const u8) anyerror!void;

pub const cmds =
    std.StaticStringMap(CmdFn).initComptime(.{
        .{ "help", help },
        .{ "build", build },
        .{ "zen", zen },
    });

const Usage =
    \\Mish compiler v0.0.2ya
    \\
    \\Usage:
    \\  mishz <command> [options]
    \\
    \\Commands:
    \\  build <file.msh>   Compile a Mish source file
    \\  help               Display this help message
    \\  zen                Print the current Zen of Mish
    \\
    \\Build Options:
    \\  -t,  --tokens      Print the lexed tokens instead of compiling
    \\  -a,  --ast         Print the AST instead of compiling
    \\  -ta, --typedast    Print the typechecked AST instead of compiling
    \\
;

pub fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(Usage);
    try writer.flush();
}

pub fn help(writer: *std.Io.Writer, _: std.process.Init, _: []const [:0]const u8) !void {
    try usage(writer);
}

// TODO: redo the wording of these points
const Zen =
    \\* Compilation speed over runtime speed
    \\* Explicit over implicit
    //\\* No hidden control flow
    \\* Achieve the most with the least
;

fn zen(writer: *std.Io.Writer, _: std.process.Init, _: []const [:0]const u8) !void {
    try writer.print("\n{s}\n\n", .{Zen});
    try writer.flush();
}

const BuildFlags = struct {
    tokens: bool = false,
    ast: bool = false,
    typedast: bool = false,

    pub fn parse(writer: *std.Io.Writer, args: []const [:0]const u8) !BuildFlags {
        var result = BuildFlags{};
        for (args) |arg| {
            if (std.mem.eql(u8, "--tokens", arg) or std.mem.eql(u8, "-t", arg)) {
                result.tokens = true;
            } else if (std.mem.eql(u8, "--ast", arg) or std.mem.eql(u8, "-a", arg)) {
                result.ast = true;
            } else if (std.mem.eql(u8, "--typedast", arg) or std.mem.eql(u8, "-ta", arg)) {
                result.typedast = true;
            } else {
                std.log.err("unknown build flag '{s}'", .{arg});
                try usage(writer);
                std.process.exit(1);
            }
        }
        return result;
    }
};

const FileTable = @import("file_table.zig").FileTable;
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const sema = @import("sema.zig");
const tknprint = @import("tknprint.zig");
const astprint = @import("astprint.zig");

pub fn build(writer: *std.Io.Writer, init: std.process.Init, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        std.log.err("too few arguments", .{});
        try usage(writer);
        std.process.exit(1);
    }

    const path = args[2];
    const flags = try BuildFlags.parse(writer, if (args.len > 3) args[3..] else &.{});

    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    if (!std.mem.eql(u8, std.fs.path.extension(path), ".msh")) {
        std.log.err("file must have a .msh extension '{s}'", .{path});
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

    const progress_name = try allocator.print("Compile {s}", .{std.fs.path.basename(path)});
    defer allocator.free(progress_name);

    var root_progress = std.Progress.start(io, .{ .root_name = progress_name });
    defer root_progress.end();

    // file table
    const cwd = try std.process.currentPathAlloc(io, arena);
    const total = try std.fs.path.join(arena, &.{
        cwd,
        path,
    });
    var file_table = FileTable.init(total, source);

    // lexer
    var lexer = lex.Lexer.init(0, &file_table);
    var lexer_progress = root_progress.start("Lexer", source.len / 9 + 3);
    const tokens = lexer.run(arena, writer, lexer_progress) catch std.process.exit(1);
    lexer_progress.end();

    if (flags.tokens) {
        try tknprint.print(tokens, &file_table, writer);
        return;
    }

    // parser
    var parser_progress = root_progress.start("Parser", tokens.len / 25);
    var parser = parse.Parser.init(
        arena,
        writer,
        tokens,
        &file_table,
        &parser_progress,
    );
    const ast = parser.run() catch std.process.exit(1);
    parser_progress.end();

    if (flags.ast) {
        try astprint.printAst(ast, 0, writer);
        try writer.flush();
        return;
    }

    // sema
    var checker_progress = root_progress.start("Semantic Analysis", ast.len);
    var checker = sema.Checker.init(
        arena,
        writer,
        ast,
        tokens,
        parser.types,
        &file_table,
        &checker_progress,
    );
    checker.run() catch std.process.exit(1);
    checker_progress.end();

    if (flags.typedast) {
        try astprint.printAst(ast, 0, writer);
        try writer.flush();
        return;
    }
}
