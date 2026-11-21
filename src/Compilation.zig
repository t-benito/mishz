const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const fmt = std.fmt;
const process = std.process;
const fs = std.fs;
const log = std.log;

const FileTable = @import("FileTable.zig");
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const Sema = @import("Sema/Sema.zig");
const Codegen = @import("Codegen.zig");
const tknprint = @import("tknprint.zig");
const astprint = @import("astprint.zig");

const cli = @import("cli.zig");
const fail = cli.fail;

const BuildFlags = struct {
    tokens: bool = false,
    ast: bool = false,
    typedast: bool = false,
    @"emit-qbe": ?[]const u8 = null,
    out: ?[]const u8 = null,

    pub fn parse(writer: *Writer, args: []const [:0]const u8) !BuildFlags {
        var result = BuildFlags{};

        var i: usize = 0;
        while (i < args.len) {
            const arg = args[i];

            if (mem.eql(u8, "--tokens", arg) or std.mem.eql(u8, "-t", arg)) {
                result.tokens = true;
            } else if (mem.eql(u8, "--ast", arg) or std.mem.eql(u8, "-a", arg)) {
                result.ast = true;
            } else if (mem.eql(u8, "--typedast", arg) or std.mem.eql(u8, "-ta", arg)) {
                result.typedast = true;
            } else if (mem.eql(u8, "--out", arg) or std.mem.eql(u8, "-o", arg)) {
                if (i == args.len - 1) {
                    fail("need a path after --out or -o", .{}, writer);
                }
                result.out = args[i + 1];
                i += 1; // skip over path
            } else if (mem.eql(u8, "--emit-qbe", arg) or std.mem.eql(u8, "-qbe", arg)) {
                if (i == args.len - 1) {
                    fail("need a path after --emit-qbe or -qbe", .{}, writer);
                }
                result.@"emit-qbe" = args[i + 1];
                i += 1;
            } else {
                fail("unknown build flag '{s}'", .{arg}, writer);
            }

            i += 1;
        }
        return result;
    }
};

pub fn build(writer: *Writer, init: process.Init, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        fail("too few arguments", .{}, writer);
    }

    const path = args[2];
    const flags = try BuildFlags.parse(writer, if (args.len > 3) args[3..] else &.{});

    const io = init.io;
    const arena = init.arena.allocator();

    if (!mem.eql(u8, fs.path.extension(path), ".msh")) {
        log.err("file must have a .msh extension '{s}'", .{path});
        process.exit(1);
    }

    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        log.err("failed opening file '{s}': {}", .{ path, err });
        process.exit(1);
    };
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    const source = reader.interface.allocRemaining(arena, .unlimited) catch |err| {
        log.err("could not read file '{s}': {}", .{ path, err });
        process.exit(1);
    };

    const progress_name = try arena.print("Compile {s}", .{std.fs.path.basename(path)});

    var root_progress = std.Progress.start(io, .{ .root_name = progress_name });
    defer root_progress.end();

    // file table
    const cwd = try process.currentPathAlloc(io, arena);
    const total = try fs.path.join(arena, &.{
        cwd,
        path,
    });
    var file_table = try FileTable.init(arena, total, source);

    var exe_buf: [fs.max_path_bytes]u8 = undefined;
    const exe_blen = try process.executableDirPath(io, &exe_buf);
    exe_buf[exe_blen] = 0;
    const lib_path = try fs.path.join(arena, &.{
        &exe_buf,
        "lib",
    });

    // lexer
    var lexer = lex.Lexer.init(arena, 0, &file_table);
    var lexer_progress = root_progress.start("Lexer", source.len / 9 + 3);
    const tokens = lexer.run(writer, lexer_progress) catch std.process.exit(1);
    lexer_progress.end();

    if (flags.tokens) {
        try tknprint.print(tokens, 0, &file_table, writer);
        return;
    }

    // parser
    var parser_progress = root_progress.start("Parser", tokens.len / 25);
    var parser = parse.Parser.init(
        arena,
        writer,
        io,
        tokens,
        &file_table,
        0,
        lib_path,
        &parser_progress,
    );
    const ast = parser.run() catch process.exit(1);
    parser_progress.end();
    // set main ast
    file_table.files.items(.ast)[0] = ast;

    if (flags.ast) {
        for (file_table.files.items(.ast), 0..) |tast, i| {
            if (tast == null)
                continue;
            try writer.print("- ast of file {} (path {s})\n", .{ i, file_table.getPath(@intCast(i)) });
            try astprint.printAst(&file_table, tast.?.nodes, 1, writer);
        }
        try writer.flush();
        return;
    }

    // sema
    var checker_progress = root_progress.start("Semantic Analysis", ast.nodes.len);
    var checker = Sema.init(
        arena,
        writer,
        &file_table,
        0,
        &checker_progress,
    );
    checker.run() catch process.exit(1);
    checker_progress.end();

    if (flags.typedast) {
        for (file_table.files.items(.ast), 0..) |tast, i| {
            if (tast == null)
                continue;
            try writer.print("- ast of file {} (path {s})\n", .{ i, file_table.getPath(@intCast(i)) });
            try astprint.printAst(&file_table, tast.?.nodes, 1, writer);
        }
        try writer.flush();
        return;
    }

    // codegen
    var cwd_dir = Io.Dir.cwd();
    var target_dir = try cwd_dir.openDir(io, std.fs.path.dirname(total).?, .{});

    var group: Io.Group = .init;
    for (file_table.files.items(.ast), 0..) |maybeast, i| {
        if (maybeast == null)
            break;
        const in_ssa = if (flags.@"emit-qbe") |q|
            try arena.dupeSentinel(u8, q, 0)
        else
            try arena.printSentinel(".temp_{d}.ssa", .{i}, 0);

        const out_asm = if (flags.out) |o|
            try arena.dupeSentinel(u8, o, 0)
        else
            try arena.printSentinel(".asm_{d}.s", .{i}, 0);

        group.async(io, codegenFileThread, .{
            init.gpa,
            in_ssa,
            out_asm,
            &target_dir,
            writer,
            io,
            &file_table,
            @intCast(i),
            &root_progress,
            flags,
        });
    }
    try group.await(io);

    // todo: turn .s to .o and link
}

fn codegenFileThread(
    gpa: Allocator,
    path: [:0]const u8,
    out: [:0]const u8,
    dir: *Io.Dir,
    writer: *Io.Writer,
    io: Io,
    file_table: *FileTable,
    file: FileTable.Handle,
    root_progress: *const std.Progress.Node,
    flags: BuildFlags,
) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    codegenFile(
        arena.allocator(),
        path,
        out,
        dir,
        writer,
        io,
        file_table,
        file,
        root_progress,
        flags,
    ) catch {
        writer.print("codegen failed in file: {s}\n", .{file_table.getPath(file)}) catch {};
        writer.flush() catch {};
        process.exit(1);
    };
}

const compileSsa = @import("qbe_shim.zig").compileSsa;

fn codegenFile(
    arena: Allocator,
    path: [:0]const u8,
    out: [:0]const u8,
    dir: *Io.Dir,
    writer: *Io.Writer,
    io: Io,
    file_table: *FileTable,
    file: FileTable.Handle,
    root_progress: *const std.Progress.Node,
    flags: BuildFlags,
) !void {
    var in_file: Io.File = try dir.createFile(io, path, .{});

    var in_buf: [4096]u8 = undefined;
    var in_file_writer = in_file.writer(io, &in_buf);
    const in_writer = &in_file_writer.interface;

    const ast = &file_table.files.items(.ast)[file].?;

    const prog_name = try arena.print("Codegen: File {}", .{file});
    var codegen_progress = root_progress.start(prog_name, ast.nodes.len);
    var gen = try Codegen.init(
        arena,
        in_writer,
        &codegen_progress,
        file_table,
        file,
    );
    try gen.run();
    codegen_progress.end();
    try in_writer.flush();

    if (flags.@"emit-qbe" != null) {
        in_file.close(io);
        return;
    }

    in_file.close(io);
    defer dir.deleteFile(io, path) catch |err| {
        writer.print("couldnt delete temp IL: {s}\n", .{@errorName(err)}) catch {};
        writer.flush() catch {};
    };

    try compileSsa(path, out);
}
