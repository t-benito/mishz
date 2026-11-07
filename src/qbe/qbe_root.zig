pub const QbeRoot = @This();

const d = @import("sdef.zig");
const std = @import("std");

writer: *std.Io.Writer,
