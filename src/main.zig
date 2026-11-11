const std = @import("std");

const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    const args = try init.minimal.args.toSlice(gpa);

    var stdout_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &writer.interface;

    if (args.len < 2) {
        try cli.usage(stdout);
        return;
    }

    if (cli.cmds.get(args[1])) |argFn| {
        try argFn(stdout, init, args);
    } else {
        std.log.err("unknown command '{s}'", .{args[1]});
        try cli.usage(stdout);
        return;
    }
}
