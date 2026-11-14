const std = @import("std");
const opts = @import("build_options");

const CmdFn = *const fn (writer: *std.Io.Writer, init: std.process.Init, args: []const [:0]const u8) anyerror!void;

pub const cmds =
    std.StaticStringMap(CmdFn).initComptime(.{
        .{ "help", help },
        .{ "build", build },
        .{ "zen", zen },
    });

const Usage = std.fmt.comptimePrint(
    \\Mish compiler {s}
    \\
    \\Usage:
    \\  mishz <command> [options]
    \\
    \\Commands:
    \\  build <file.msh>         Compile a Mish source file
    \\  help                     Display this help message
    \\  zen                      Print the current Zen of Mish
    \\
    \\Build Options:
    \\  -t,       --tokens       Print the lexed tokens instead of compiling
    \\  -a,        --ast         Print the AST instead of compiling
    \\  -ta,       --typedast    Print the typechecked AST instead of compiling
    \\ --emit-qbe, -qbe <file>   Write QBE IL to <file>.ssa
    \\  -o,        --out <file>  Write output to <file>
    \\
, .{opts.version});

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
    @"emit-qbe": ?[]const u8 = null,
    out: ?[]const u8 = null,

    pub fn parse(writer: *std.Io.Writer, args: []const [:0]const u8) !BuildFlags {
        var result = BuildFlags{};

        var i: usize = 0;
        while (i < args.len) {
            const arg = args[i];

            if (std.mem.eql(u8, "--tokens", arg) or std.mem.eql(u8, "-t", arg)) {
                result.tokens = true;
            } else if (std.mem.eql(u8, "--ast", arg) or std.mem.eql(u8, "-a", arg)) {
                result.ast = true;
            } else if (std.mem.eql(u8, "--typedast", arg) or std.mem.eql(u8, "-ta", arg)) {
                result.typedast = true;
            } else if (std.mem.eql(u8, "--out", arg) or std.mem.eql(u8, "-o", arg)) {
                if (i == args.len - 1) {
                    fail("need a path after --out or -o", writer);
                }
                result.out = args[i + 1];
                i += 1; // skip over path
            } else if (std.mem.eql(u8, "--emit-qbe", arg) or std.mem.eql(u8, "-qbe", arg)) {
                if (i == args.len - 1) {
                    fail("need a path after --emit-qbe or -qbe", writer);
                }
                result.@"emit-qbe" = args[i + 1];
                i += 1;
            } else {
                std.log.err("unknown build flag '{s}'", .{arg});
                try usage(writer);
                std.process.exit(1);
            }

            i += 1;
        }
        return result;
    }
};

const FileTable = @import("file_table.zig").FileTable;
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const sema = @import("sema.zig");
const codegen = @import("codegen.zig");
const tknprint = @import("tknprint.zig");
const astprint = @import("astprint.zig");

pub fn build(writer: *std.Io.Writer, init: std.process.Init, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        fail("too few arguments", writer);
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
        0,
        &parser_progress,
    );
    var ast = parser.run() catch std.process.exit(1);
    parser_progress.end();

    if (flags.ast) {
        try astprint.printAst(ast.nodes, 0, writer);
        try writer.flush();
        return;
    }

    // sema
    var checker_progress = root_progress.start("Semantic Analysis", ast.nodes.len);
    var checker = sema.Checker.init(
        arena,
        writer,
        &ast,
        &checker_progress,
    );
    checker.run() catch std.process.exit(1);
    checker_progress.end();

    if (flags.typedast) {
        try astprint.printAst(ast.nodes, 0, writer);
        try writer.flush();
        return;
    }

    // codegen
    var in_file: std.Io.File = undefined;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var in_path: [:0]const u8 = undefined;
    var end_at_qbe = false;

    if (flags.@"emit-qbe") |out| {
        end_at_qbe = true;
        if (std.mem.eql(u8, out, "-")) {
            in_file = std.Io.File.stdout();
        } else {
            in_file = try std.Io.Dir.cwd().createFile(io, out, .{});

            const len = try in_file.realPath(io, &path_buf);
            path_buf[len] = 0;
            in_path = path_buf[0..len :0];
        }
    } else {
        in_file = try std.Io.Dir.cwd().createFile(io, ".temp.ssa", .{});

        const len = try in_file.realPath(io, &path_buf);
        path_buf[len] = 0;
        in_path = path_buf[0..len :0];
    }
    defer in_file.close(io);

    var in_buf: [4096]u8 = undefined;
    var in_file_writer = file.writer(io, &in_buf);
    const in_writer = &in_file_writer.interface;

    var codegen_progress = root_progress.start("Codegen", ast.nodes.len);
    var gen = codegen.init(arena, in_writer, &codegen_progress, &ast);
    try gen.run();
    codegen_progress.end();

    if (end_at_qbe) {
        return;
    }

    const compileSsa = @import("qbe_shim.zig").compileSsa;

    var out_path: [:0]const u8 = undefined;

    var out_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPath(io, &out_path_buf);
    out_path_buf[len] = 0;

    if (flags.out) |out| {
        out_path = try arena.dupeSentinel(u8, try std.fs.path.join(arena, &.{
            out_path_buf[0..len],
            out,
        }), 0);
    } else {
        out_path = try arena.dupeSentinel(u8, try std.fs.path.join(arena, &.{
            out_path_buf[0..len],
            "comp.out",
        }), 0);
    }

    try compileSsa(in_path, out_path);
    try std.Io.Dir.cwd().deleteFile(io, in_path);
}

fn fail(msg: []const u8, writer: *std.Io.Writer) noreturn {
    std.log.err("{s}", .{msg});
    usage(writer) catch {};
    std.process.exit(1);
}
