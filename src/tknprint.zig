const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;
const FileTable = @import("file_table.zig").FileTable;

pub fn print(tokens: []const Token, file_table: *FileTable, writer: *std.Io.Writer) !void {
    for (tokens) |tkn| {
        try printTkn(tkn, file_table.getSource(tkn.file), writer);
    }
    try writer.flush();
}

fn printTkn(token: Token, source: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeAll(@tagName(token.kind));
    const slice = source[token.start..token.end];

    for (0..getPadding(20, @tagName(token.kind).len)) |_| {
        try writer.writeAll(" ");
    }
    try writer.print("'{s}'", .{slice});

    for (0..getPadding(20, slice.len)) |_| {
        try writer.writeAll(" ");
    }
    try writer.print("span: {} - {}", .{ token.start, token.end });
    const len = std.fmt.count("span: {} - {}", .{ token.start, token.end });

    for (0..getPadding(20, len)) |_| {
        try writer.writeAll(" ");
    }
    try writer.print("file id: {}\n", .{token.file});
}

inline fn getPadding(diff: u8, strlen: usize) usize {
    return @intCast(@max(1, diff - @as(i32, @intCast(strlen))));
}
