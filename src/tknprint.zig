const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;
const FileTable = @import("FileTable.zig");
const FileHandle = FileTable.Handle;

pub fn print(tokens: []const Token, file: FileHandle, file_table: *FileTable, writer: *std.Io.Writer) !void {
    for (tokens) |tkn| {
        try printTkn(tkn, file_table.getSource(file), writer);
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
    try writer.print("span: {} - {}\n", .{ token.start, token.end });
}

inline fn getPadding(diff: u8, strlen: usize) usize {
    return @intCast(@max(1, diff - @as(i32, @intCast(strlen))));
}
