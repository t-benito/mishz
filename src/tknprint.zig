const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;
const FileTable = @import("file_table.zig").FileTable;

pub fn print(tokens: []const Token, file_table: *FileTable, io: std.Io, allocator: std.mem.Allocator) !void {
    var buffer = std.ArrayList(u8).empty;

    for (tokens) |tkn| {
        try printTkn(tkn, file_table.getSource(tkn.file), &buffer, allocator);
    }

    try std.Io.File.stdout().writeStreamingAll(io, buffer.items);
}

fn printTkn(token: Token, source: []const u8, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buffer.appendSlice(allocator, @tagName(token.kind));
    const slice = source[token.start..token.end];

    for (0..getPadding(20, @tagName(token.kind).len)) |_| {
        try buffer.append(allocator, ' ');
    }
    const sfmt = try std.fmt.allocPrint(allocator, "'{s}'", .{slice});
    try buffer.appendSlice(allocator, sfmt);

    for (0..getPadding(20, slice.len)) |_| {
        try buffer.append(allocator, ' ');
    }
    const fmt = try std.fmt.allocPrint(allocator, "span: {} - {}", .{ token.start, token.end });
    try buffer.appendSlice(allocator, fmt);

    for (0..getPadding(20, fmt.len)) |_| {
        try buffer.append(allocator, ' ');
    }
    const ffmt = try std.fmt.allocPrint(allocator, "file id: {}\n", .{token.file});
    try buffer.appendSlice(allocator, ffmt);
}

// i dont have an idea for the name
inline fn getPadding(diff: u8, strlen: usize) usize {
    return @intCast(@max(1, diff - @as(i32, @intCast(strlen))));
}
