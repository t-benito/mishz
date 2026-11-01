const std = @import("std");

const FileTable = @import("file_table.zig").FileTable;

const Lex_Error = @import("lex.zig").LexError;
const Parse_Error = @import("parse.zig").ParseError;
const Type_Error = @import("sema.zig").TypeError;
const Pre_Error = @import("preprocess.zig").Preprocessor.PreprocessorError;

pub const ErrorType = union(enum) {
    ParseError: Parse_Error,
    LexError: Lex_Error,
    TypeError: Type_Error,
    PreprocessorError: Pre_Error,
};

pub const Note = struct {
    message: []const u8,
    start: usize,
    end: usize,
    file: u8,
};

pub const Error = struct {
    message: []const u8,
    kind: ErrorType,
    file: u8,
    start: usize,
    end: usize,
    note: ?Note = null,
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
            .errors = std.ArrayList(Error).empty,
            .file_table = file_table,
        };
    }

    pub fn add(self: *ErrorLogger, allocator: std.mem.Allocator, err: Error) !void {
        try self.errors.append(allocator, err);
    }

    fn hashEStr(str: []const u8) u32 {
        var h: u32 = 2333;
        for (str) |c| {
            h ^= c;
            h = h *% 16245;
        }
        return h % 10000;
    }

    fn kindName(allocator: std.mem.Allocator, kind: ErrorType) []const u8 {
        const errname = switch (kind) {
            .LexError => |e| @errorName(e),
            .PreprocessorError => |e| @errorName(e),
            .ParseError => |e| @errorName(e),
            .TypeError => |e| @errorName(e),
        };
        return allocator.print("E{d}", .{hashEStr(errname)}) catch "E-1";
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
                kindName(allocator, err.kind),
                err.message,
                err.start,
                err.end,
                false,
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
                    "note",
                    n.message,
                    n.start,
                    n.end,
                    true,
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
        label: []const u8,
        message: []const u8,
        start: usize,
        end: usize,
        is_note: bool,
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
            try writer.print("{s}{s}{s}:\n{s}error{s}{s}[{s}]{s}: {s}\n", .{ DIM, path, RESET, RED, RESET, DIM, label, RESET, message });
        }
        try writer.print(" {s}-->{s} {d}:{d}\n\n", .{ CYAN, RESET, line, col });

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
            for (0..a) |_| {
                try writer.writeByte('^');
            }
        }
        std.debug.print("{s}\n", .{RESET});
    }
};
