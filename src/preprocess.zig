pub const Preprocessor = @This();

const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;
const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;
const FileTable = @import("file_table.zig").FileTable;

const Macro = struct {
    tokens: []Token,
    used: bool = false,
    start: usize,
    end: usize,
};

pub const PreprocessorError = enum(u8) {
    UnexpectedToken = 0,
    RecursiveMacro = 1,
    RecursiveInclude = 2,
    UnterminatedDirective = 3,
    NoMatchingDirective = 4,
    IncludeError = 5,
};

current: usize = 0,

tokens: []Token,
macros: std.StringHashMap(Macro),

logger: ErrorLogger,
writer: *std.Io.Writer,
allocator: std.mem.Allocator,

out: std.ArrayList(Token),

root_node: *const std.Progress.Node,
io: std.Io,

libc_path: []const u8,
file_table: *FileTable,

pub fn init(
    allocator: std.mem.Allocator,
    tokens: []Token,
    root_node: *const std.Progress.Node,
    file_table: *FileTable,
    io: std.Io,
    writer: *std.Io.Writer,
) !Preprocessor {
    return Preprocessor{
        .tokens = tokens,
        .macros = .initContext(allocator, .{}),
        .logger = .init(file_table),
        .allocator = allocator,
        .out = try .initCapacity(allocator, tokens.len),
        .root_node = root_node,
        .io = io,
        .writer = writer,
        .libc_path = try std.fs.path.join(allocator, &.{
            try std.process.executableDirPathAlloc(io, allocator),
            "libc",
            "std",
        }),
        .file_table = file_table,
    };
}

fn peek(self: *Preprocessor) Token {
    if (self.isAtEnd())
        return self.tokens[self.current - 1];
    return self.tokens[self.current];
}

fn advance(self: *Preprocessor) Token {
    if (self.isAtEnd())
        return self.tokens[self.current - 1];

    const tkn = self.tokens[self.current];
    self.current += 1;
    return tkn;
}

fn expect(self: *Preprocessor, expected: Token.Kind) !Token {
    const tkn = self.advance();
    if (tkn.kind != expected) {
        try self.logger.add(self.allocator, .{
            .start = tkn.start,
            .end = tkn.end,
            .file = tkn.file,
            .message = "unexpected token",
            .kind = .{ .PreprocessorError = PreprocessorError.UnexpectedToken },
        });
        return error.UnexpectedToken;
    }
    return tkn;
}

fn isAtEnd(self: *Preprocessor) bool {
    return self.current >= self.tokens.len;
}

pub fn run(self: *Preprocessor) !void {
    while (!self.isAtEnd()) {
        self.checkTkn() catch break;
    }

    self.allocator.free(self.tokens);
    self.tokens = try self.out.toOwnedSlice(self.allocator);

    _ = try self.replace();
    try self.cleanup();

    if (try self.logger.dump(self.allocator, self.writer))
        return error.pre;
}

fn checkTkn(self: *Preprocessor) !void {
    switch (self.peek().kind) {
        .pre_ifdef => try self.ifdef(false),
        .pre_ifndef => try self.ifndef(false),
        .pre_define => try self.define(),
        .pre_include => try self.include(),
        .pre_else, .pre_elif, .pre_endif => {
            const tkn = self.advance();
            try self.logger.add(self.allocator, .{
                .start = tkn.start,
                .end = tkn.end,
                .file = self.peek().file,
                .kind = .{ .PreprocessorError = PreprocessorError.NoMatchingDirective },
                .message = switch (tkn.kind) {
                    .pre_else => "unexpected '#else' without matching '#ifdef' or '#ifndef'",
                    .pre_elif => "unexpected '#elif' without matching '#ifdef' or '#ifndef'",
                    .pre_endif => "unexpected '#endif' without matching '#ifdef' or '#ifndef'",
                    else => unreachable,
                },
            });
            self.skipLine();
        },
        .newline => _ = self.advance(),
        else => try self.out.append(self.allocator, self.advance()),
    }
}
//                                                fuck it
fn checkTknIf(self: *Preprocessor, discard: bool) anyerror //error{
//OutOfMemory,
//UnexpectedToken,
//UnterminatedDirective,
//R//ecursiveMacro,
//NoMatchingDirective,
//IncludeError, // THIS SUCKS OH MY GOD ZIG
//}!void {
!void {
    switch (self.peek().kind) {
        .pre_ifdef => try self.ifdef(discard),
        .pre_ifndef => try self.ifndef(discard),
        .pre_define => {
            if (discard)
                self.skipLine()
            else
                try self.define();
        },
        .pre_include => {
            if (discard)
                self.skipLine()
            else
                try self.include();
        },
        .newline => _ = self.advance(),
        else => {
            const tkn = self.advance();
            if (!discard)
                try self.out.append(self.allocator, tkn);
        },
    }
}

fn include(self: *Preprocessor) !void {
    const d = self.advance();
    const s = self.advance();
    switch (s.kind) {
        .string_literal => {
            const n = self.file_table.spanStr(s.file, s.start, s.end);

            const base = self.file_table.getPath(s.file);
            const dir = std.fs.path.dirname(base) orelse ".";
            const total = try std.fs.path.resolve(self.allocator, &.{
                dir,
                n,
            });

            try self.inclFile(total, false, s.start, s.end, s.file);
        },
        .lt => {
            var name = std.ArrayList(u8).empty;
            while (!self.isAtEnd() and self.peek().kind != .gt) {
                const t = self.advance();
                try name.appendSlice(self.allocator, self.file_table.spanStr(t.file, t.start, t.end));
            }
            _ = try self.expect(.gt);

            const path = try std.fs.path.join(self.allocator, &.{
                self.libc_path,
                try name.toOwnedSlice(self.allocator),
            });
            try self.inclFile(path, true, s.start, s.end, s.file);
        },
        else => {
            self.current -= 1;
            try self.logger.add(self.allocator, .{
                .start = d.start,
                .end = s.end,
                .file = s.file,
                .message = "expected string or '<' after '#include'",
                .kind = .{ .PreprocessorError = PreprocessorError.UnexpectedToken },
            });
            return error.UnexpectedToken;
        },
    }
}

fn define(self: *Preprocessor) !void {
    const d = self.advance();
    const n = try self.expect(.identifier);
    const name = self.file_table.spanStr(n.file, n.start, n.end);

    var tokens = std.ArrayList(Token).empty;

    while (!self.isAtEnd() and self.peek().kind != .newline)
        try tokens.append(self.allocator, self.advance());

    self.skipLine();

    try self.macros.put(name, Macro{
        .start = d.start,
        .end = n.end,
        .tokens = try tokens.toOwnedSlice(self.allocator),
    });
}

fn ifdef(self: *Preprocessor, parent_discard: bool) !void {
    _ = self.advance();

    const n = try self.expect(.identifier);
    const name = self.file_table.spanStr(n.file, n.start, n.end);
    const defined = self.macros.contains(name);

    self.skipLine();

    try self.procIf(parent_discard, defined);
}

fn ifndef(self: *Preprocessor, parent_discard: bool) !void {
    _ = self.advance();

    const n = try self.expect(.identifier);
    const name = self.file_table.spanStr(n.file, n.start, n.end);
    const defined = self.macros.contains(name);

    self.skipLine();

    try self.procIf(parent_discard, !defined);
}

fn procIf(self: *Preprocessor, parent_discard: bool, condition: bool) !void {
    var discard = parent_discard or !condition;
    var branch_taken = !parent_discard and condition;

    while (!self.isAtEnd()) {
        switch (self.peek().kind) {
            .pre_endif => {
                self.endif();
                return;
            },
            .pre_elif => {
                if (parent_discard or branch_taken) {
                    self.skipLine();
                    discard = true;
                } else {
                    const result = try self.elif();
                    discard = !result;
                    branch_taken = result;
                }
            },
            .pre_else => {
                self.elsee(discard);
                discard = parent_discard or branch_taken;

                if (!parent_discard)
                    branch_taken = true;
            },
            else => try self.checkTknIf(discard),
        }
    }

    return error.NoMatchingDirective;
}

fn elif(self: *Preprocessor) !bool {
    _ = self.advance();

    const n = try self.expect(.identifier);
    const name = self.file_table.spanStr(n.file, n.start, n.end);

    self.skipLine();
    return self.macros.contains(name);
}

fn elsee(self: *Preprocessor, discarded: bool) void {
    _ = discarded;
    self.skipLine();
}

fn endif(self: *Preprocessor) void {
    _ = self.advance();
    self.skipLine();
}

fn skipLine(self: *Preprocessor) void {
    while (!self.isAtEnd() and self.peek().kind != .newline)
        _ = self.advance();

    if (!self.isAtEnd())
        _ = self.advance();
}

fn inclFile(self: *Preprocessor, path: []const u8, comptime from_libc: bool, start: usize, end: usize, filei: u8) anyerror!void {
    var parent_node = self.root_node.start("Including file", 1);
    defer parent_node.end();
    // check for integer overflow
    if (filei == std.math.maxInt(u8)) {
        try self.logger.add(self.allocator, .{
            .start = start,
            .end = end,
            .file = filei,
            .message = "reached maximum file import limit (255)",
            .kind = .{ .PreprocessorError = PreprocessorError.IncludeError },
        });
        return error.IncludeError;
    }
    // check extension
    if (!std.mem.eql(u8, std.fs.path.extension(path), ".msh")) {
        try self.logger.add(self.allocator, .{
            .start = start,
            .end = end,
            .file = filei,
            .message = "file name does not end in .msh",
            .kind = .{ .PreprocessorError = PreprocessorError.IncludeError },
        });
        return error.IncludeError;
    }
    // check for same path
    const cleanp1 = try std.fs.path.resolveAlloc(self.allocator, &.{path});
    const cleanp2 = try std.fs.path.resolveAlloc(self.allocator, &.{self.file_table.getPath(filei)});
    if (std.mem.eql(u8, cleanp1, cleanp2)) {
        try self.logger.add(self.allocator, .{
            .start = start,
            .end = end,
            .file = filei,
            .message = "recursive include",
            .kind = .{ .PreprocessorError = PreprocessorError.RecursiveInclude },
            .note = .{
                .start = start,
                .end = end,
                .file = filei,
                .message = "a file including itself would result in an infinite loop, crashing the compiler",
            },
        });
        return error.IncludeError;
    }
    // open file
    const file = std.Io.Dir.openFileAbsolute(self.io, path, .{
        .mode = .read_only,
    }) catch |e| {
        try self.logger.add(self.allocator, .{
            .start = start,
            .end = end,
            .file = filei,
            .message = try self.allocator.print("encountered error opening file: {s}", .{@errorName(e)}),
            .kind = .{ .PreprocessorError = PreprocessorError.IncludeError },
            .note = if (from_libc) .{
                .start = start,
                .end = end,
                .file = filei,
                .message = "this file is from libc: if it was not found, reinstall the compiler or move it back",
            } else null,
        });
        return error.IncludeError;
    };
    defer file.close(self.io);

    var buf: [128]u8 = undefined;
    var reader = file.reader(self.io, &buf);

    const source = reader.interface.allocRemaining(self.allocator, .unlimited) catch |e| {
        try self.logger.add(self.allocator, .{
            .start = start,
            .end = end,
            .file = filei,
            .message = try self.allocator.print("encountered error reading file: {s}", .{@errorName(e)}),
            .kind = .{ .PreprocessorError = PreprocessorError.IncludeError },
        });
        return error.IncludeError;
    };
    // now we can finally read it...
    const id = self.file_table.addFile(path, source);
    // lexer
    var lex_progress = parent_node.start("Lexer", source.len / 27);

    var lexer = lex.Lexer.init(id, self.file_table);
    const tokens = try lexer.run(self.allocator, self.writer, lex_progress);

    lex_progress.end();
    // preprocessor
    var pre_progress = parent_node.start("Preprocessor", tokens.len / 5);

    var sub = try Preprocessor.init(
        self.allocator,
        tokens,
        &pre_progress,
        self.file_table,
        self.io,
        self.writer,
    );
    sub.macros = self.macros;
    try sub.run();

    try self.out.appendSlice(self.allocator, sub.tokens[0 .. sub.tokens.len - 1]);
    self.macros = sub.macros;

    pre_progress.end();
}

fn replace(self: *Preprocessor) !bool {
    var new = std.ArrayList(Token).empty;
    defer new.deinit(self.allocator);

    var found_any = false;
    for (self.tokens) |tkn| {
        const c = try self.expand(tkn, &new);
        if (c)
            found_any = true;
    }

    if (found_any) {
        const result = try new.toOwnedSlice(self.allocator);
        self.allocator.free(self.tokens);
        self.tokens = result;
    }

    return found_any;
}

fn expand(self: *Preprocessor, tkn: Token, new: *std.ArrayList(Token)) !bool {
    if (tkn.kind != .identifier) {
        try new.append(self.allocator, tkn);
        return false;
    }

    const name = self.file_table.spanStr(tkn.file, tkn.start, tkn.end);
    if (self.macros.getPtr(name)) |macro| {
        if (macro.used) {
            try self.logger.add(self.allocator, .{
                .start = macro.start,
                .end = macro.end,
                .file = tkn.file,
                .kind = .{ .PreprocessorError = PreprocessorError.RecursiveMacro },
                .message = "recursive macro",
                .note = .{
                    .start = tkn.start,
                    .end = tkn.end,
                    .file = tkn.file,
                    .message = "used here",
                },
            });
            return error.RecursiveMacro;
        }

        macro.used = true;
        defer macro.used = false;

        for (macro.tokens) |stkn|
            _ = try self.expand(stkn, new);

        return true;
    }

    try new.append(self.allocator, tkn);
    return false;
}

fn cleanup(self: *Preprocessor) !void {
    var new = std.ArrayList(Token).empty;

    for (self.tokens) |t| {
        if (t.kind == .newline)
            continue;

        if (t.kind == .pre_define or
            t.kind == .pre_ifdef or
            t.kind == .pre_ifndef or
            t.kind == .pre_endif or
            t.kind == .pre_elif or
            t.kind == .pre_else or
            t.kind == .pre_include)
        {
            continue;
        }

        try new.append(self.allocator, t);
    }

    const result = try new.toOwnedSlice(self.allocator);
    self.allocator.free(self.tokens);
    self.tokens = result;
}
