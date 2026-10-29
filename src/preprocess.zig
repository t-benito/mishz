pub const Preprocessor = @This();

const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;
const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;

const Macro = struct {
    name: []const u8,
    tokens: []Token,
    used: bool,
};

pub const PreprocessorError = error{
    UnexpectedToken,
};

current: usize,

source: []const u8,
tokens: std.ArrayList(Token),
macros: std.ArrayList(Macro),

logger: ErrorLogger,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, source: []const u8, file: []const u8, tokens: []Token) Preprocessor {
    return Preprocessor{
        .source = source,
        .tokens = tokens,
        .macros = std.ArrayList(Macro).empty,
        .logger = ErrorLogger.init(file),
        .allocator = allocator,
    };
}

fn peek(self: *Preprocessor) Token {
    if (self.isAtEnd())
        return self.tokens.last().?;
    return self.tokens[self.current];
}

fn advance(self: *Preprocessor) Token {
    if (self.isAtEnd())
        return self.tokens.last().?;
    const tkn = self.tokens.items[self.current];
    self.current += 1;
    return tkn;
}

fn expect(self: *Preprocessor, expected: Token.Kind) !Token {
    const tkn = self.advance();
    if (tkn.kind != expected) {
        try self.logger.add(self.allocator, .{
            .start = self.peek().start,
            .end = self.peek().end,
            .message = "unexpected token",
            .kind = .{ .PreprocessorError = PreprocessorError.UnexpectedToken },
        });
    }
    return tkn;
}

fn isAtEnd(self: *Preprocessor) bool {
    return self.current >= self.source.len;
}

pub fn run(self: *Preprocessor) !void {
    while (!self.isAtEnd()) {
        try self.checkTkn();
    }
    cleanUp();
}

fn checkTkn(self: *Preprocessor) !bool {
    switch (tkn.kind) {
        .pre_ifdef => return self.ifdef(i),
    }
}

fn ifdef(self: *Preprocessor) !bool {}

fn cleanUp(self: *Preprocessor) void {
    for (self.tokens.items, 0..) |t, i| {
        if (t.kind != .newline and
            t.kind != .pre_define and
            t.kind != .pre_ifdef and
            t.kind != .pre_ifndef and
            t.kind != .pre_endif)
            continue;
        self.tokens.orderedRemove(i);
    }
}
