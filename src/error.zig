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
};

pub const Error = struct {
    message: []const u8,
    kind: ErrorType,
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
    file: u8,
    file_table: *FileTable,

    pub fn init(file_id: u8, file_table: *FileTable) ErrorLogger {
        return .{
            .errors = std.ArrayList(Error).empty,
            .file = file_id,
            .file_table = file_table,
        };
    }

    pub fn add(self: *ErrorLogger, allocator: std.mem.Allocator, err: Error) !void {
        try self.errors.append(allocator, err);
    }

    fn kindName(allocator: std.mem.Allocator, kind: ErrorType) []const u8 {
        var err: usize = @as(usize, @intCast(@backingInt(kind))) * 1000;
        switch (kind) {
            .ParseError => |e| err += @intFromError(e),
            .LexError => |e| err += @intFromError(e),
            .TypeError => |e| err += @intFromError(e),
            .PreprocessorError => |e| err += @intFromError(e),
        }
        return allocator.print("E{d}", .{err}) catch "(OUT OF MEMORY)";
    }

    pub fn dump(self: *ErrorLogger, allocator: std.mem.Allocator) bool {
        const source = self.file_table.getSource(self.file);
        defer self.errors.clearAndFree(allocator);
        if (self.errors.items.len == 0) return false;

        for (self.errors.items, 0..) |err, idx| {
            if (idx > 0) std.debug.print("\n", .{});
            self.render(allocator, source, kindName(allocator, err.kind), err.message, err.start, err.end, false) catch {
                std.debug.print("{s}error{s}: {s} (could not render snippet)\n", .{ RED, RESET, err.message });
            };
            if (err.note) |n| {
                self.render(allocator, source, "note", n.message, n.start, n.end, true) catch {};
            }
        }
        return true;
    }

    fn render(self: *ErrorLogger, allocator: std.mem.Allocator, source: []const u8, label: []const u8, message: []const u8, start: usize, end: usize, is_note: bool) !void {
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
            std.debug.print("\n{s}note{s}: {s}\n", .{ BLUE, RESET, message });
        } else {
            std.debug.print("{s}{s}{s}: {s}error{s}{s}[{s}]{s}: {s}\n", .{ DIM, self.file_table.getPath(self.file), RESET, RED, RESET, DIM, label, RESET, message });
        }
        std.debug.print(" {s}-->{s} {d}:{d}\n\n", .{ CYAN, RESET, line, col });

        var tmp = line;
        var digits: usize = 1;
        while (tmp >= 10) : (tmp /= 10) {
            digits += 1;
        }

        const slice = source[line_start..line_end];
        std.debug.print(" {d} {s}|{s} {s}\n", .{ line, CYAN, RESET, slice });

        std.debug.print(" ", .{});
        for (0..digits) |_| {
            std.debug.print(" ", .{});
        }
        std.debug.print(" {s}|{s} ", .{ CYAN, RESET });

        const width = line_end - line_start;
        std.debug.print("{s}", .{if (is_note) BLUE else "\x1b[31m"});
        if (width == 0) {
            std.debug.print("^", .{});
        } else {
            const marks = try allocator.alloc(u8, width);
            @memset(marks, ' ');

            var a = s - line_start;
            if (a >= width) a = width - 1;

            var b = e - line_start;
            if (b > width) b = width;
            if (b <= a) b = a + 1;

            @memset(marks[a..b], '^');
            std.debug.print("{s}", .{marks});
        }
        std.debug.print("{s}\n", .{RESET});
    }
};
