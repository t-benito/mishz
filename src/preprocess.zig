pub const Preprocessor = @This();

const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;
const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;

const Macro = struct {
    tokens: []Token,
    used: bool = false,
    start: usize,
    end: usize,
};

pub const PreprocessorError = error{
    UnexpectedToken,
    RecursiveMacro,
    UnterminatedDirective,
    NoMatchingDirective,
};

current: usize = 0,

source: []const u8,
tokens: []Token,
macros: std.StringHashMap(Macro),

logger: ErrorLogger,
allocator: std.mem.Allocator,

out: std.ArrayList(Token) = .empty,

root_node: *const std.Progress.Node,
slow: bool,
io: std.Io,

pub fn init(allocator: std.mem.Allocator, source: []const u8, file: []const u8, tokens: []Token, root_node: *const std.Progress.Node, slow: bool, io: std.Io) Preprocessor {
    return Preprocessor{
        .source = source,
        .tokens = tokens,
        .macros = .initContext(allocator, .{}),
        .logger = ErrorLogger.init(file),
        .allocator = allocator,
        .root_node = root_node,
        .slow = slow,
        .io = io,
    };
}

fn sleepIfSlow(self: *Preprocessor, time: u32) void {
    std.Io.sleep(self.io, .fromMicroseconds(time), .awake) catch {};
}

fn spanStr(self: *Preprocessor, start: usize, end: usize) []const u8 {
    return self.source[start..end];
}

fn peek(self: *Preprocessor) Token {
    self.sleepIfSlow(30);

    if (self.isAtEnd())
        return self.tokens[self.current - 1];
    return self.tokens[self.current];
}

fn advance(self: *Preprocessor) Token {
    self.sleepIfSlow(25);

    if (self.isAtEnd())
        return self.tokens[self.current - 1];

    const tkn = self.tokens[self.current];
    self.current += 1;
    return tkn;
}

fn expect(self: *Preprocessor, expected: Token.Kind) !Token {
    self.sleepIfSlow(40);

    const tkn = self.advance();
    if (tkn.kind != expected) {
        try self.logger.add(self.allocator, .{
            .start = tkn.start,
            .end = tkn.end,
            .message = "unexpected token",
            .kind = .{ .PreprocessorError = PreprocessorError.UnexpectedToken },
        });
        return PreprocessorError.UnexpectedToken;
    }
    return tkn;
}

fn isAtEnd(self: *Preprocessor) bool {
    return self.current >= self.tokens.len;
}

pub fn run(self: *Preprocessor) !void {
    while (!self.isAtEnd()) {
        try self.checkTkn();
    }

    self.allocator.free(self.tokens);
    self.tokens = try self.out.toOwnedSlice(self.allocator);

    _ = try self.replace();
    try self.cleanup();

    if (self.logger.dump(self.allocator, self.source))
        return error.pre;
}

fn checkTkn(self: *Preprocessor) !void {
    switch (self.peek().kind) {
        .pre_ifdef => try self.ifdef(false),
        .pre_ifndef => try self.ifndef(false),
        .pre_define => try self.define(),
        .pre_else, .pre_elif, .pre_endif => {
            const tkn = self.advance();
            try self.logger.add(self.allocator, .{
                .start = tkn.start,
                .end = tkn.end,
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

fn checkTknIf(self: *Preprocessor, discard: bool) error{
    OutOfMemory,
    UnexpectedToken,
    UnterminatedDirective,
    RecursiveMacro,
    NoMatchingDirective, // THIS SUCKS OH MY GOD ZIG
}!void {
    switch (self.peek().kind) {
        .pre_ifdef => try self.ifdef(discard),
        .pre_ifndef => try self.ifndef(discard),
        .pre_define => {
            if (discard) {
                self.skipLine();
            } else {
                try self.define();
            }
        },
        .newline => _ = self.advance(),
        else => {
            const tkn = self.advance();
            if (!discard)
                try self.out.append(self.allocator, tkn);
        },
    }
}

fn define(self: *Preprocessor) !void {
    const d = self.advance();
    const n = try self.expect(.identifier);
    const name = self.spanStr(n.start, n.end);

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
    const name = self.spanStr(n.start, n.end);
    const defined = self.macros.contains(name);

    self.skipLine();

    try self.procIf(parent_discard, defined);
}

fn ifndef(self: *Preprocessor, parent_discard: bool) !void {
    _ = self.advance();

    const n = try self.expect(.identifier);
    const name = self.spanStr(n.start, n.end);
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

    return PreprocessorError.NoMatchingDirective;
}

fn elif(self: *Preprocessor) !bool {
    _ = self.advance();

    const n = try self.expect(.identifier);
    const name = self.spanStr(n.start, n.end);

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

    const name = self.spanStr(tkn.start, tkn.end);
    if (self.macros.getPtr(name)) |macro| {
        if (macro.used) {
            try self.logger.add(self.allocator, .{
                .start = macro.start,
                .end = macro.end,
                .kind = .{ .PreprocessorError = PreprocessorError.RecursiveMacro },
                .message = "recursive macro",
                .note = .{
                    .start = tkn.start,
                    .end = tkn.end,
                    .message = "used here",
                },
            });
            return PreprocessorError.RecursiveMacro;
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
            t.kind == .pre_else)
        {
            continue;
        }

        try new.append(self.allocator, t);
    }

    const result = try new.toOwnedSlice(self.allocator);
    self.allocator.free(self.tokens);
    self.tokens = result;
}
