const std = @import("std");

const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;
const FileTable = @import("FileTable.zig");
const FileHandle = FileTable.Handle;
const SourceHandle = @import("Ast.zig").SourceHandle;

pub const Token = struct {
    pub const Handle = u32;

    start: SourceHandle,
    end: SourceHandle,
    kind: Kind,

    pub const Kind = enum {
        eof,

        dot,
        comma,
        semicolon,
        colon,
        arrow,

        assign,
        equal,
        not_equal,
        not,
        lt,
        gt,
        lt_eq,
        gt_eq,
        add,
        add_assign,
        increment,
        sub,
        sub_assign,
        decrement,
        star,
        mul_assign,
        div,
        div_assign,
        bit_and,
        bit_or,
        bit_xor,
        bit_not,
        bit_left,
        bit_right,

        open_paren,
        close_paren,
        open_body,
        close_body,
        open_bracket,
        close_bracket,
        at,

        kw_void,
        kw_i8,
        kw_i16,
        kw_i32,
        kw_i64,
        kw_u8,
        kw_u16,
        kw_u32,
        kw_u64,
        kw_f32,
        kw_f64,
        kw_bool,
        kw_false,
        kw_true,

        kw_fn,
        kw_let,
        kw_mut,
        kw_ret,
        kw_if,
        kw_else,
        kw_for,
        kw_pub,
        kw_struct,
        kw_as,
        kw_and,
        kw_or,
        kw_import,
        kw_use,
        kw_impl,

        identifier,
        string_literal,
        number_literal,
        float_literal,
    };

    pub const Keywords = std.StaticStringMap(Token.Kind).initComptime(.{
        .{ "void", .kw_void },
        .{ "i8", .kw_i8 },
        .{ "i16", .kw_i16 },
        .{ "i32", .kw_i32 },
        .{ "i64", .kw_i64 },
        .{ "u8", .kw_u8 },
        .{ "u16", .kw_u16 },
        .{ "u32", .kw_u32 },
        .{ "u64", .kw_u64 },
        .{ "f32", .kw_f32 },
        .{ "f64", .kw_f64 },
        .{ "bool", .kw_bool },
        .{ "true", .kw_true },
        .{ "false", .kw_false },

        .{ "fn", .kw_fn },
        .{ "let", .kw_let },
        .{ "mut", .kw_mut },
        .{ "ret", .kw_ret },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "for", .kw_for },
        .{ "pub", .kw_pub },
        .{ "struct", .kw_struct },
        .{ "as", .kw_as },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "import", .kw_import },
        .{ "use", .kw_use },
        .{ "impl", .kw_impl },
    });
};

pub const LexError = enum(u8) {
    UnknownCharacter = 0,
    UnknownDirective = 1,
    UnclosedStringLiteral = 2,
    UnclosedStringIdentifier = 3,
    InvalidIdentifier = 4,
    InvalidEscape = 5,
    ReservedUsage = 6,
};

pub const Lexer = struct {
    file_id: FileHandle,
    file_table: *FileTable,

    source: []const u8,

    current: SourceHandle,
    col: SourceHandle,
    row: SourceHandle,

    logger: ErrorLogger,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, file_id: FileHandle, file_table: *FileTable) Lexer {
        return .{
            .file_id = file_id,
            .file_table = file_table,
            .source = file_table.getSource(file_id),
            .current = 0,
            .col = 0,
            .row = 0,
            .logger = .init(allocator, file_table, file_id),
            .allocator = allocator,
        };
    }

    fn peek(self: *Lexer) u8 {
        if (!self.isAtEnd()) return self.source[self.current];
        return '0';
    }

    fn next(self: *Lexer) u8 {
        if (self.current + 1 < self.source.len) return self.source[self.current + 1];
        return '0';
    }

    fn advance(self: *Lexer) u8 {
        const c = self.peek();
        self.current += 1;
        self.col += 1;
        if (c == '\n') {
            self.col = 1;
            self.row += 1;
        }
        return c;
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.source.len;
    }

    pub fn run(self: *Lexer, writer: *std.Io.Writer, progress: std.Progress.Node) ![]Token {
        var allocator = self.allocator;

        var inits = progress.start("Initializing", 0);
        var tokens = try std.ArrayList(Token).initCapacity(allocator, self.source.len / 2);

        var run_progress = progress.start("Running", 0);

        inits.end();
        var runs: usize = 0;
        while (!self.isAtEnd()) {
            runs += 1;

            progress.setEstimatedTotalItems(@max(self.source.len / 7, runs + 1));
            progress.setCompletedItems(runs);

            while (!self.isAtEnd() and std.ascii.isWhitespace(self.peek()))
                _ = self.advance();
            if (self.isAtEnd()) break;

            if (self.peek() == '/') {
                const nextc = self.next();
                if (nextc == '/') {
                    while (!self.isAtEnd()) {
                        if (self.peek() != '\n') {
                            _ = self.advance();
                            continue;
                        }
                        break;
                    }
                    continue;
                } else if (nextc == '*') {
                    while (!self.isAtEnd()) {
                        if (self.advance() == '*' and self.peek() == '/') {
                            _ = self.advance();
                            break;
                        }
                    }
                    continue;
                }
            }

            const start = self.current;

            if (self.peek() == '@' and self.next() == '"') {
                _ = self.advance();
                _ = self.advance();
                var got = false;
                var first = true;
                var valid = true;

                while (!self.isAtEnd() and !got) {
                    const c = self.advance();
                    if (c == '"') {
                        got = true;
                    }
                    if (first) {
                        if (!std.ascii.isAlphabetic(c) and c != '.' and c != '_') {
                            valid = false;
                        }
                        first = false;
                    } else {
                        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '$') {
                            valid = false;
                        }
                    }
                }
                if (!got) {
                    try self.logger.add(.{
                        .kind = .{ .LexError = .UnclosedStringIdentifier },
                        .message = "string identifier missing closing \"",
                        .start = start,
                        .end = self.current,
                    });
                    continue;
                }
                if (first) {
                    try self.logger.add(.{
                        .kind = .{ .LexError = .InvalidIdentifier },
                        .message = "string identifier cannot be empty",
                        .start = start,
                        .end = self.current,
                    });
                    continue;
                }
                if (!valid) {
                    try self.logger.add(.{
                        .kind = .{ .LexError = .InvalidIdentifier },
                        .message = "string identifiers can only contain letters, digits, '.', '_' and '$', not starting with '$' or a digit",
                        .start = start,
                        .end = self.current,
                    });
                }

                if (std.mem.startsWith(
                    u8,
                    self.file_table.spanStr(self.file_id, start + 2, self.current - 1),
                    "___.",
                )) {
                    try self.logger.add(.{
                        .kind = .{ .LexError = .ReservedUsage },
                        .message = "identifiers starting with '___.' are reserved for compiler internals",
                        .start = start,
                        .end = self.current,
                    });
                }

                try tokens.append(allocator, .{
                    .start = start + 2,
                    .end = self.current - 1,
                    .kind = .identifier,
                });
                continue;
            }

            if (self.parseDouble()) |kind| {
                _ = self.advance();
                _ = self.advance();
                try tokens.append(allocator, .{
                    .start = start,
                    .end = self.current,
                    .kind = kind,
                });
                continue;
            }

            if (self.parseSingle()) |kind| {
                _ = self.advance();
                try tokens.append(allocator, .{
                    .start = start,
                    .end = self.current,
                    .kind = kind,
                });
                continue;
            }

            if (self.peek() == '"') {
                _ = self.advance();
                var got = false;

                while (!self.isAtEnd() and !got) {
                    if (self.advance() == '"')
                        got = true;
                }
                if (!got) {
                    try self.logger.add(.{
                        .kind = .{ .LexError = .UnclosedStringLiteral },
                        .message = "string literal missing closing \"",
                        .start = start,
                        .end = self.current,
                    });
                    continue;
                }
                try tokens.append(allocator, .{
                    .start = start + 1,
                    .end = self.current - 1,
                    .kind = .string_literal,
                });
                continue;
            }

            if (std.ascii.isAlphabetic(self.peek()) or self.peek() == '_') {
                while (!self.isAtEnd() and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) {
                    _ = self.advance();
                }
                const str = self.source[start..self.current];
                if (Token.Keywords.get(str)) |k| {
                    try tokens.append(allocator, .{
                        .start = start,
                        .end = self.current,
                        .kind = k,
                    });
                    continue;
                }
                try tokens.append(allocator, .{
                    .start = start,
                    .end = self.current,
                    .kind = .identifier,
                });
                continue;
            }

            if (std.ascii.isDigit(self.peek())) { // TODO: floats
                while (!self.isAtEnd() and std.ascii.isDigit(self.peek()) or self.peek() == '_') {
                    _ = self.advance();
                }
                try tokens.append(allocator, Token{
                    .start = start,
                    .end = self.current,
                    .kind = .number_literal,
                });
                continue;
            }

            const bad = self.source[start];
            _ = self.advance();
            const emsg = try allocator.print("unknown character '{c}'", .{bad});

            try self.logger.add(.{
                .message = emsg,
                .kind = .{ .LexError = LexError.UnknownCharacter },
                .start = start,
                .end = self.current,
            });
        }
        try tokens.append(allocator, .{
            .start = @intCast(self.source.len - 1),
            .end = @intCast(self.source.len - 1),
            .kind = .eof,
        });

        var dump = progress.start("Dumping", 0);
        progress.increaseEstimatedTotalItems(2);
        if (try self.logger.dump(allocator, writer)) {
            return error.lexer;
        }

        var finish = run_progress.start("Lexer finished!", 0);
        dump.end();
        finish.end();
        run_progress.end();

        return try tokens.toOwnedSlice(allocator);
    }

    fn parseSingle(self: *Lexer) ?Token.Kind {
        return switch (self.peek()) {
            '.' => .dot,
            ',' => .comma,
            ';' => .semicolon,
            ':' => .colon,
            '=' => .assign,
            '!' => .not,
            '>' => .gt,
            '<' => .lt,
            '+' => .add,
            '-' => .sub,
            '*' => .star,
            '/' => .div,
            '&' => .bit_and,
            '|' => .bit_or,
            '^' => .bit_xor,
            '~' => .bit_not,
            '(' => .open_paren,
            ')' => .close_paren,
            '{' => .open_body,
            '}' => .close_body,
            '[' => .open_bracket,
            ']' => .close_bracket,
            '@' => .at,
            else => null,
        };
    }

    fn parseDouble(self: *Lexer) ?Token.Kind {
        const str = pack2(self.peek(), self.next());
        return switch (str) {
            comptime pack2('-', '>') => .arrow,
            comptime pack2('-', '-') => .decrement,
            comptime pack2('+', '+') => .increment,
            comptime pack2('=', '=') => .equal,
            comptime pack2('!', '=') => .not_equal,
            comptime pack2('<', '=') => .lt_eq,
            comptime pack2('>', '=') => .gt_eq,
            comptime pack2('+', '=') => .add_assign,
            comptime pack2('-', '=') => .sub_assign,
            comptime pack2('*', '=') => .mul_assign,
            comptime pack2('/', '=') => .div_assign,
            comptime pack2('<', '<') => .bit_left,
            comptime pack2('>', '>') => .bit_right,
            else => null,
        };
    }
    /// helper function for the parseDouble to not have to use string comparison
    inline fn pack2(first: u8, second: u8) u16 {
        return (@as(u16, first) << 8) | @as(u16, second);
    }
};
