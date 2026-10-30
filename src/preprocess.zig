pub const Preprocessor = @This();

const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;
const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;

const Macro = struct {
    tokens: []Token,
    used: bool,
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

skipping: bool = false,
skip_nesting: usize = 0,

root_node: *const std.Progress.Node,
slow: bool,
io: std.Io,

pub fn init(allocator: std.mem.Allocator, source: []const u8, file: []const u8, tokens: []Token, root_node: *const std.Progress.Node, slow: bool, io: std.Io) Preprocessor {
    return Preprocessor{
        .source = source,
        .tokens = tokens,
        .macros = std.StringHashMap(Macro).initContext(allocator, .{}), // TODO: use init??
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
            .start = self.peek().start,
            .end = self.peek().end,
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
    _ = try self.replace();
    try self.cleanup();

    if (self.logger.dump(self.allocator, self.source)) {
        return error.pre;
    }
}

fn checkTkn(self: *Preprocessor) !void {
    switch (self.peek().kind) {
        .pre_ifdef => try self.ifdef(),
        .pre_ifndef => try self.ifndef(),
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
        },
        else => _ = self.advance(),
    }
}

fn define(self: *Preprocessor) !void {
    const d = self.advance();
    const n = try self.expect(.identifier);
    const name = self.spanStr(n.start, n.end);

    var tokens = std.ArrayList(Token).empty;
    while (!self.isAtEnd() and self.peek().kind != .newline) {
        try tokens.append(self.allocator, self.advance());
    }

    try self.macros.put(name, Macro{
        .tokens = try tokens.toOwnedSlice(self.allocator),
        .used = false,
        .start = d.start,
        .end = d.end,
    });
}

fn ifdef(self: *Preprocessor) !void {
    const d = self.advance();
    const n = try self.expect(.identifier);

    if (self.skipping) {
        self.skip_nesting += 1;
        return;
    }

    const defined = self.macros.contains(self.spanStr(n.start, n.end));
    if (!defined) {
        try self.skipUntil(.pre_endif, d.start, d.end);
    } else {
        while (!self.isAtEnd() and self.advance().kind != .pre_endif) {}
    }
}

fn ifndef(self: *Preprocessor) !void {
    const d = self.advance();
    const n = try self.expect(.identifier);

    if (self.skipping) {
        self.skip_nesting += 1;
        return;
    }

    const defined = self.macros.contains(self.spanStr(n.start, n.end));
    if (!defined)
        while (!self.isAtEnd() and self.advance().kind != .pre_endif) {};
    try self.skipUntil(.pre_endif, d.start, d.end);
}

fn elif(self: *Preprocessor) !bool {
    const n = try self.expect(.identifier);

    const defined = self.macros.contains(self.spanStr(n.start, n.end));
    if (!defined)
        return false;
    self.skip_nesting = 0;
    self.skipping = false;
    return true;
}

fn skipUntil(self: *Preprocessor, kind: Token.Kind, dir_start: usize, dir_end: usize) !void {
    self.skipping = true;
    self.skip_nesting = 1;

    while (self.skip_nesting > 0) {
        const t = self.advance();

        if (t.kind == .eof) {
            try self.logger.add(self.allocator, .{
                .start = dir_start,
                .end = dir_end,
                .kind = .{ .PreprocessorError = PreprocessorError.UnterminatedDirective },
                .message = "unterminated processor directive",
            });
            return PreprocessorError.UnterminatedDirective;
        }

        if (self.skip_nesting == 1 and t.kind != kind) {
            if (t.kind == .pre_elif) {
                if (!try self.elif())
                    continue;
                return;
            } else if (t.kind == .pre_else) {
                self.skip_nesting = 0;
                self.skipping = false;
                return;
            }
        }

        if (t.kind == .pre_ifdef or t.kind == .pre_ifndef) {
            self.skip_nesting += 1;
            continue;
        }

        if (t.kind == kind) {
            self.skip_nesting -= 1;
            if (self.skip_nesting > 0)
                continue;
            self.skipping = false;
            _ = self.advance();
            return;
        }
    }
    self.skipping = false;
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

    if (found_any)
        self.tokens = try new.toOwnedSlice(self.allocator);
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

        for (macro.tokens) |stkn| {
            _ = try self.expand(stkn, new);
        }
        return true;
    }

    try new.append(self.allocator, tkn);
    return false;
}

fn cleanup(self: *Preprocessor) !void {
    var new = std.ArrayList(Token).empty;

    var i: usize = 0;
    while (i < self.tokens.len) : (i += 1) {
        const t = self.tokens[i];
        if (t.kind == .newline)
            continue;
        if (t.kind == .pre_define or
            t.kind == .pre_ifdef or
            t.kind == .pre_ifndef or
            t.kind == .pre_endif or
            t.kind == .pre_elif or
            t.kind == .pre_else)
        {
            while (i < self.tokens.len and self.tokens[i].kind != .newline)
                i += 1;
            continue;
        }
        try new.append(self.allocator, t);
    }
    self.tokens = try new.toOwnedSlice(self.allocator);
}
