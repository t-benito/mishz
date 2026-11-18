const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const process = std.process;
const Init = process.Init;
const opts = @import("build_options");

const CmdFn = *const fn (writer: *Writer, init: Init, args: []const [:0]const u8) anyerror!void;

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

pub fn usage(writer: *Writer) !void {
    try writer.writeAll(Usage);
    try writer.flush();
}

pub fn help(writer: *Writer, _: Init, _: []const [:0]const u8) !void {
    try usage(writer);
}

// TODO: redo the wording of these points
const Zen =
    \\* Compilation speed over runtime speed
    \\* Explicit over implicit
    //\\* No hidden control flow
    \\* Achieve the most with the least
;

fn zen(writer: *Writer, _: Init, _: []const [:0]const u8) !void {
    try writer.print("\n{s}\n\n", .{Zen});
    try writer.flush();
}

const compile = @import("Compilation.zig").build;
fn build(writer: *Writer, init: Init, args: []const [:0]const u8) !void {
    try compile(writer, init, args);
}

pub fn fail(comptime fmt: []const u8, args: anytype, writer: *Writer) noreturn {
    writer.writeAll("\x1b[1m\x1b[31merror: \x1b[0m") catch {};
    writer.print(fmt ++ "\n", args) catch {};

    usage(writer) catch {};
    std.process.exit(1);
}
