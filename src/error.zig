const std = @import("std");

const ft = @import("file_table.zig");
const FileTable = ft.FileTable;
const FileHandle = ft.FileHandle;

const Lex_Error = @import("lex.zig").LexError;
const Parse_Error = @import("parse.zig").ParseError;
const Type_Error = @import("sema.zig").TypeError;

pub const ErrorType = union(enum(u8)) {
    ParseError: Parse_Error = 1,
    LexError: Lex_Error = 2,
    TypeError: Type_Error = 3,
};

pub const Note = struct {
    message: []const u8,
    start: usize,
    end: usize,
    file: FileHandle,
};

pub const Error = struct {
    message: []const u8,
    kind: ErrorType,
    file: FileHandle,
    start: usize,
    end: usize,
    note: ?Note = null,
    help: ?[]const u8 = null,
};

const RED = "\x1b[1;31m";
const BLUE = "\x1b[1;34m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

pub const ErrorLogger = struct {
    errors: std.ArrayList(Error),
    file_table: *FileTable,

    pub fn init(file_table: *FileTable) ErrorLogger {
        return .{
            .errors = .empty,
            .file_table = file_table,
        };
    }

    pub fn add(self: *ErrorLogger, allocator: std.mem.Allocator, err: Error) !void {
        try self.errors.append(allocator, err);
    }

    fn writeErr(writer: *std.Io.Writer, kind: ErrorType) !void {
        const _1: u16 = @intCast(@backingInt(kind));
        const _2: u16 = @intCast(switch (kind) {
            .LexError => |e| @backingInt(e),
            .ParseError => |e| @backingInt(e),
            .TypeError => |e| @backingInt(e),
        });

        try writer.print("E{d}", .{_1 * 1000 + _2});
    }

    pub fn dump(self: *ErrorLogger, allocator: std.mem.Allocator, writer: *std.Io.Writer) !bool {
        defer self.errors.deinit(allocator);
        if (self.errors.items.len == 0) return false;

        for (self.errors.items, 0..) |err, idx| {
            const source = self.file_table.getSource(err.file);
            const path = self.file_table.getPath(err.file);
            if (idx > 0)
                try writer.print("\n", .{});

            render(
                writer,
                source,
                path,
                err.message,
                err.start,
                err.end,
                false,
                err.kind,
            ) catch {
                try writer.print("{s}error{s}: {s} (could not render snippet)\n", .{ RED, RESET, err.message });
            };
            if (err.note) |n| {
                const nsource = self.file_table.getSource(n.file);
                const npath = self.file_table.getPath(n.file);
                render(
                    writer,
                    nsource,
                    npath,
                    n.message,
                    n.start,
                    n.end,
                    true,
                    null,
                ) catch {};
            }
        }
        try writer.writeAll("\n");
        try writer.flush();
        return true;
    }

    fn render(
        writer: *std.Io.Writer,
        source: []const u8,
        path: []const u8,
        message: []const u8,
        start: usize,
        end: usize,
        is_note: bool,
        err: ?ErrorType,
    ) !void {
        const s = @min(start, source.len);
        var e = @min(end, source.len);
        if (e <= s) e = @min(s + 1, source.len);

        var line_start = s;
        while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}

        var line_end = s;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

        var line: usize = 1;
        for (source[0..line_start]) |c| {
            if (c == '\n') line += 1;
        }
        const col = s - line_start + 1;

        if (is_note) {
            try writer.print("\n{s}note{s}: {s}\n", .{ BLUE, RESET, message });
        } else {
            try writer.print(
                "{s}{s}{s}:\n{s}error{s}{s}[",
                .{
                    DIM,
                    path,
                    RESET,
                    // :\n
                    RED,
                    RESET,
                    DIM,
                },
            );
            std.debug.assert(err != null); // just in case
            try writeErr(writer, err.?);
            try writer.print(
                "]{s}: {s}\n",
                .{
                    RESET,
                    message,
                },
            );
        }
        try writer.print("  {s}-->{s} {d}:{d}\n\n", .{ CYAN, RESET, line, col });

        var tmp = line;
        var digits: usize = 1;
        while (tmp >= 10) : (tmp /= 10) {
            digits += 1;
        }

        const slice = source[line_start..line_end];
        try writer.print(" {d} {s}|{s} {s}\n", .{ line, CYAN, RESET, slice });

        try writer.writeAll(" ");
        for (0..digits) |_| {
            try writer.writeAll(" ");
        }
        try writer.print(" {s}|{s} ", .{ CYAN, RESET });

        const width = line_end - line_start;
        try writer.print("{s}", .{if (is_note) BLUE else "\x1b[31m"});
        if (width == 0) {
            try writer.writeAll("^");
        } else {
            var a = s - line_start;
            if (a >= width)
                a = width - 1;

            var b = e - line_start;
            if (b > width)
                b = width;
            if (b <= a)
                b = a + 1;
            for (0..a) |_|
                try writer.writeByte(' ');
            for (a..b) |_|
                try writer.writeByte('^');
        }
        try writer.print("{s}\n", .{RESET});
    }
};
