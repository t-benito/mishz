const std = @import("std");

const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;
const FileTable = @import("file_table.zig").FileTable;

pub const Token = struct {
    start: usize,
    end: usize,
    kind: Kind,
    file: u8,

    pub const Kind = enum {
        newline, // used in preprocessor
        eof,

        dot,
        comma,
        semicolon,
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

        open_paren,
        close_paren,
        open_body,
        close_body,
        open_bracket,
        close_bracket,
        at,

        pre_define,
        //pre_macro,
        //pre_endmacro,
        pre_ifdef,
        pre_ifndef,
        pre_else,
        pre_elif,
        pre_endif,
        pre_include,

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
        kw_null,

        kw_mut,
        kw_ret,
        kw_if,
        kw_else,
        kw_for,
        kw_pub,
        kw_struct,
        kw_as,

        identifier,
        string_literal,
        number_literal,
        float_literal,
    };

    pub const Keywords = std.StaticStringMap(Token.Kind).initComptime(.{
        .{ "#define", .pre_define },
        .{ "#ifdef", .pre_ifdef },
        .{ "#ifndef", .pre_ifndef },
        .{ "#endif", .pre_endif },
        .{ "#include", .pre_include },
        .{ "#else", .pre_else },
        .{ "#elif", .pre_elif },

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
        .{ "null", .kw_null },

        .{ "mut", .kw_mut },
        .{ "ret", .kw_ret },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "for", .kw_for },
        .{ "pub", .kw_pub },
        .{ "struct", .kw_struct },
        //.{ "class", .kw_class },
        .{ "as", .kw_as },
    });
};

pub const LexError = error{
    UnknownCharacter,
    UnknownDirective,
    UnclosedStringLiteral,
};

const lexer_slow_sleep_time = std.Io.Duration.fromMilliseconds(25);

pub const Lexer = struct {
    file_id: u8,
    file_table: *FileTable,

    source: []const u8,

    current: usize,
    col: usize,
    row: usize,

    logger: ErrorLogger,

    pub fn init(file_id: u8, file_table: *FileTable) Lexer {
        return .{
            .file_id = file_id,
            .file_table = file_table,
            .source = file_table.getSource(file_id),
            .current = 0,
            .col = 0,
            .row = 0,
            .logger = .init(file_table),
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

    pub fn run(self: *Lexer, allocator: std.mem.Allocator, progress: std.Progress.Node, slow: bool, io: ?std.Io) ![]Token {
        var inits = progress.start("Initializing", 0);
        var tokens = try std.ArrayList(Token).initCapacity(allocator, self.source.len / 7);

        var run_progress = progress.start("Running", 0);

        inits.end();
        var runs: usize = 0;
        while (!self.isAtEnd()) {
            if (slow) {
                try std.Io.sleep(io.?, lexer_slow_sleep_time, .awake);
            }

            runs += 1;
            //const msg = try std.fmt.allocPrint(allocator, "Running (run {})", .{runs});
            //defer allocator.free(msg);

            progress.setEstimatedTotalItems(@max(self.source.len / 7, runs + 1));
            // this is to increase the count shown in the progress bar..
            run_progress.end();
            run_progress = progress.start("Running", 0);

            if (self.peek() == '\n') {
                _ = self.advance();
                try tokens.append(allocator, .{
                    .start = self.current,
                    .end = self.current,
                    .file = self.file_id,
                    .kind = .newline,
                });
                continue;
            }

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
                        if (self.peek() != '*') {
                            _ = self.advance();
                            continue;
                        }
                        _ = self.advance();

                        if (self.peek() != '/') {
                            _ = self.advance();
                            continue;
                        }
                        _ = self.advance();
                        break;
                    }
                    continue;
                }
            }

            const start = self.current;

            if (self.parseDouble()) |kind| {
                _ = self.advance();
                _ = self.advance();
                try tokens.append(allocator, .{
                    .start = start,
                    .end = self.current,
                    .file = self.file_id,
                    .kind = kind,
                });
                continue;
            }

            if (self.parseSingle()) |kind| {
                _ = self.advance();
                try tokens.append(allocator, .{
                    .start = start,
                    .end = self.current,
                    .file = self.file_id,
                    .kind = kind,
                });
                continue;
            }

            if (self.peek() == '"') {
                _ = self.advance();
                var got = false;

                while (!self.isAtEnd()) {
                    if (self.advance() == '"') {
                        got = true;
                        break;
                    }
                }
                if (!got) {
                    try self.logger.add(allocator, .{
                        .kind = .{ .LexError = LexError.UnclosedStringLiteral },
                        .message = "unclosed string literal (missing closing '\"')",
                        .start = start,
                        .end = self.current,
                        .file = self.file_id,
                    });
                    continue;
                }
                try tokens.append(allocator, .{
                    .start = start + 1,
                    .end = self.current - 1,
                    .kind = .string_literal,
                    .file = self.file_id,
                });
                continue;
            }

            if (std.ascii.isAlphabetic(self.peek())) {
                while (!self.isAtEnd() and std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_' or self.peek() == ':') {
                    _ = self.advance();
                }
                const str = self.source[start..self.current];
                if (Token.Keywords.get(str)) |k| {
                    try tokens.append(allocator, .{
                        .start = start,
                        .end = self.current,
                        .file = self.file_id,
                        .kind = k,
                    });
                    continue;
                }
                try tokens.append(allocator, .{
                    .start = start,
                    .end = self.current,
                    .file = self.file_id,
                    .kind = .identifier,
                });
                continue;
            }
            if (self.peek() == '#') {
                //dont _ = self.advance(); // skip #
                while (!self.isAtEnd() and std.ascii.isAlphanumeric(self.peek()) or self.peek() == '#') {
                    _ = self.advance();
                }

                const str = self.source[start..self.current];
                if (Token.Keywords.get(str)) |k| {
                    try tokens.append(allocator, .{
                        .start = start,
                        .end = self.current,
                        .file = self.file_id,
                        .kind = k,
                    });
                    continue;
                }
                try self.logger.add(allocator, .{
                    .message = try std.fmt.allocPrint(allocator, "unknown processor directive '{s}'", .{str}),
                    .kind = .{ .LexError = LexError.UnknownDirective },
                    .start = start,
                    .end = self.current,
                    .file = self.file_id,
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
                    .file = self.file_id,
                    .kind = .number_literal,
                });
                continue;
            }

            const bad = self.source[start];
            _ = self.advance();

            if (self.peek() == '#') {
                try self.logger.add(allocator, .{
                    .message = "unknown character '#'",
                    .kind = .{ .LexError = LexError.UnknownCharacter },
                    .start = start,
                    .end = self.current,
                    .file = self.file_id,
                    .note = .{
                        .start = start,
                        .end = self.current,
                        .file = self.file_id,
                        .message = "mishz does not allow spaces between '#' and preprocessor directive",
                    },
                });
                continue;
            }

            const emsg = try std.fmt.allocPrint(allocator, "unknown character '{c}'", .{bad});

            try self.logger.add(allocator, .{
                .message = emsg,
                .kind = .{ .LexError = LexError.UnknownCharacter },
                .start = start,
                .end = self.current,
                .file = self.file_id,
            });
        }
        try tokens.append(allocator, .{
            .start = 0,
            .end = 0,
            .file = self.file_id,
            .kind = .eof,
        });

        var dump = progress.start("Dumping", 0);
        progress.increaseEstimatedTotalItems(2);
        if (self.logger.dump(allocator)) {
            return error.lexer;
        }
        if (slow) {
            try std.Io.sleep(io.?, lexer_slow_sleep_time, .awake);
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
            '=' => .assign,
            '!' => .not,
            '>' => .gt,
            '<' => .lt,
            '+' => .add,
            '-' => .sub,
            '*' => .star,
            '/' => .div,
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
            pack2('-', '>') => .arrow,
            pack2('-', '-') => .decrement,
            pack2('+', '+') => .increment,
            pack2('=', '=') => .equal,
            pack2('!', '=') => .not_equal,
            pack2('<', '=') => .lt_eq,
            pack2('>', '=') => .gt_eq,
            pack2('+', '=') => .add_assign,
            pack2('-', '=') => .sub_assign,
            pack2('*', '=') => .mul_assign,
            pack2('/', '=') => .div_assign,
            else => null,
        };
    }
    /// helper function for the parseDouble to not have to use string comparison
    inline fn pack2(first: u8, second: u8) u16 {
        return (@as(u16, first) << 8) | @as(u16, second);
    }
};
