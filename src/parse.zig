const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const ProgNode = std.Progress.Node;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Tag = Ast.Tag;
const Sema = @import("Sema/Sema.zig");
const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;
const Error = err.Error;
const ErrorType = err.ErrorType;
const FileTable = @import("FileTable.zig");
const FileHandle = FileTable.Handle;
const lex = @import("lex.zig");
const Token = lex.Token;
const typet = @import("Sema/Type.zig");
const Type = typet.Type;
const TypePool = typet.TypePool;

pub const ParseError = enum(u8) {
    UnexpectedToken = 0,
    ExpectedStatement = 1,
    ExpectedTopLevelStatement = 2,
    ExpectedVariableStmt = 3,
    ExpectedExpression = 4,
    ExpectedTypeExpression = 5,
    UnexpectedKwInStruct = 6,
    UnexpectedDefaultValue = 7,
    UnexpectedTypeToken = 9,
    PubTwice = 10,
    ImportFileNotFound = 11,
    ImportError = 12,
    ImportWrongExt = 13,
};

const Err = error{ParseError} || Allocator.Error;

pub const Parser = struct {
    file_table: *FileTable,
    file: FileHandle,
    tokens: []Token,
    current: Token.Handle = 0,

    allocator: Allocator,
    io: Io,

    logger: ErrorLogger,
    writer: *Io.Writer,
    root_node: *const ProgNode,

    lib_dir: []const u8,

    pub fn init(
        allocator: Allocator,
        writer: *Io.Writer,
        io: Io,
        tokens: []Token,
        file_table: *FileTable,
        file: FileHandle,
        lib_dir: []const u8,
        progress: *const ProgNode,
    ) Parser {
        return Parser{
            .file_table = file_table,
            .file = file,
            .tokens = tokens,
            .allocator = allocator,
            .io = io,
            .logger = .init(allocator, file_table, file),
            .writer = writer,
            .lib_dir = lib_dir,
            .root_node = progress,
        };
    }

    fn peek(self: *Parser) Token {
        if (self.isAtEnd())
            return self.tokens[self.tokens.len - 1];
        return self.tokens[self.current];
    }

    fn next(self: *Parser) Token {
        if (self.current + 1 >= self.tokens.len)
            return self.tokens[self.tokens.len - 1];
        return self.tokens[self.current + 1];
    }

    fn advance(self: *Parser) Token {
        if (self.isAtEnd())
            return self.tokens[self.current - 1];
        const token = self.tokens[self.current];
        self.current += 1;
        return token;
    }

    fn expect(self: *Parser, kind: Token.Kind) !Token {
        const t = self.advance();
        if (t.kind == kind) {
            return t;
        }
        const fmt = try self.allocator.print(
            "expected '{s}', found '{s}'",
            .{
                describeKind(kind),
                describeKind(t.kind),
            },
        );
        self.current -= 1;
        try self.logger.add(.{
            .message = fmt,
            .start = t.start,
            .end = t.end,
            .kind = .{ .ParseError = .UnexpectedToken },
        });
        self.current += 1;

        return error.ParseError;
    }

    /// Expect a token but with a custom message
    fn expectMsg(self: *Parser, kind: Token.Kind, msg: []const u8) !Token {
        const t = self.advance();
        if (t.kind == kind) {
            return t;
        }
        self.current -= 1;
        const fmt = try self.allocator.print(
            "{s}, found '{s}'",
            .{
                msg,
                describeKind(t.kind),
            },
        );
        try self.logger.add(Error{
            .message = fmt,
            .start = t.start,
            .end = t.start,
            .kind = .{ .ParseError = .UnexpectedToken },
        });
        self.current += 1;

        return error.ParseError;
    }

    fn describeKind(kind: Token.Kind) []const u8 {
        return switch (kind) {
            .semicolon => ";",
            .comma => ",",
            .dot => ".",
            .assign => "=",
            .equal => "==",
            .not_equal => "!=",
            .not => "!",
            .lt => "<",
            .gt => ">",
            .lt_eq => "<=",
            .gt_eq => ">=",
            .add => "+",
            .add_assign => "+=",
            .increment => "++",
            .sub => "-",
            .sub_assign => "-=",
            .decrement => "--",
            .star => "*",
            .mul_assign => "*=",
            .div => "/",
            .div_assign => "/=",
            .open_paren => "(",
            .close_paren => ")",
            .open_body => "{",
            .close_body => "}",
            .open_bracket => "[",
            .close_bracket => "]",
            .identifier => "<identifier>",
            .number_literal => "<number>",
            .kw_void => "void",
            .kw_i8 => "i8",
            .kw_i16 => "i16",
            .kw_i32 => "i32",
            .kw_i64 => "i64",
            .kw_u8 => "u8",
            .kw_u16 => "u16",
            .kw_u32 => "u32",
            .kw_u64 => "u64",
            .kw_f32 => "f32",
            .kw_f64 => "f64",
            .kw_fn,
            .kw_let,
            .kw_mut,
            .kw_ret,
            .kw_if,
            .kw_and,
            .kw_for,
            .kw_pub,
            .kw_struct,
            .kw_as,
            .kw_import,
            .kw_impl,
            .kw_or,
            => "<keyword>",
            else => @tagName(kind),
        };
    }

    fn matches(self: *Parser, kind: Token.Kind) bool {
        return self.peek().kind == kind;
    }

    fn isAtEnd(self: *Parser) bool {
        return self.current >= self.tokens.len or self.tokens[self.current].kind == .eof;
    }

    fn syncErr(self: *Parser) void {
        if (!self.isAtEnd())
            _ = self.advance();
        while (!self.isAtEnd()) {
            switch (self.peek().kind) {
                .kw_fn,
                .kw_struct,
                .kw_pub,
                => return,
                else => _ = self.advance(),
            }
        }
    }

    pub fn run(self: *Parser) !Ast {
        var nodes = try ArrayList(*Node).initCapacity(self.allocator, self.tokens.len / 28);
        while (!self.isAtEnd()) {
            const top = self.parseTop() catch {
                self.syncErr();
                continue;
            };
            try nodes.append(self.allocator, top);
            self.root_node.setEstimatedTotalItems(@max(self.tokens.len / 25, nodes.items.len));
        }

        if (try self.logger.dump(self.allocator, self.writer)) {
            return error.parse;
        }

        const slice = try nodes.toOwnedSlice(self.allocator);
        return Ast{
            .nodes = slice,
            .tokens = self.tokens,
        };
    }

    fn parseBlock(self: *Parser, previous: *const std.Progress.Node) Err![]*Node {
        var body = try ArrayList(*Node).initCapacity(self.allocator, 24);

        while (!self.isAtEnd()) {
            if (self.peek().kind == .close_body) {
                break;
            }
            previous.increaseEstimatedTotalItems(1);
            try body.append(self.allocator, try self.parseStmt(previous));
        }
        return body.toOwnedSlice(self.allocator);
    }

    fn parseTop(self: *Parser) anyerror!*Node {
        const msg = try self.allocator.print("Top-level statement (token {})", .{self.current});
        const top_node = self.root_node.start(msg, 1);
        defer top_node.end();

        switch (self.peek().kind) {
            .kw_import => {
                const node = try self.parseImport(&top_node);
                _ = try self.expectMsg(.semicolon, "expected ';' after statement");
                return node;
            },
            .kw_struct => {
                const node = try self.parseStruct(&top_node);
                _ = try self.expectMsg(.semicolon, "expected ';' after statement");
                return node;
            },
            .kw_pub => return try self.parsePub(),
            .kw_let => {
                const node = try self.parseLet(&top_node);
                _ = try self.expectMsg(.semicolon, "expected ';' after statement");
                return node;
            },
            .kw_fn => return try self.parseFn(&top_node),
            else => {
                const found_top = self.peek();
                try self.logger.add(.{
                    .kind = .{ .ParseError = .ExpectedTopLevelStatement },
                    .start = found_top.start,
                    .end = self.next().end,
                    .message = try self.allocator.print(
                        "expected a top-level statement ('fn', 'let', 'struct' or 'pub'), found '{s}'",
                        .{
                            describeKind(found_top.kind),
                            //self.file_table.spanStr(found_top.file, found_top.start, found_top.end),
                        },
                    ),
                });
                return error.ParseError;
            },
        }
    }

    fn parseStmt(self: *Parser, previous: *const std.Progress.Node) Err!*Node {
        var parent_node = previous.start("Statement", 1);
        defer parent_node.end();
        switch (self.peek().kind) {
            .kw_ret => {
                const stmt = try self.parseRet(&parent_node);
                _ = try self.expectMsg(.semicolon, "expected ';' after statement");
                return stmt;
            },
            .kw_let => {
                const stmt = try self.parseLet(&parent_node);
                _ = try self.expectMsg(.semicolon, "expected ';' after statement");
                return stmt;
            },
            .kw_if => return try self.parseIf(&parent_node),
            .kw_for => return try self.parseFor(&parent_node),
            .open_body => {
                const start = try self.expect(.open_body);
                const body = try self.parseBlock(&parent_node);

                const node = try self.allocator.create(Node);
                node.* = Node{
                    .data = .{
                        .block = .{
                            .body = body,
                        },
                    },
                    .tag = .block,
                    .start = start.start,
                    .end = self.peek().end,
                };
                _ = try self.expect(.close_body);
                return node;
            },
            else => {
                const expr = try self.parseExpr(0, &parent_node);
                _ = try self.expectMsg(.semicolon, "expected ';' after statement");
                return expr;
            },
        }
    }

    inline fn getImportance(_: *Parser, kind: Token.Kind) u8 {
        return switch (kind) {
            .assign,
            .add_assign,
            .sub_assign,
            .mul_assign,
            .div_assign,
            => 1,
            .bit_or,
            .bit_xor,
            .bit_and,
            => 2,
            .kw_as,
            => 3,
            .equal,
            .not_equal,
            .gt,
            .lt,
            .gt_eq,
            .lt_eq,
            => 4,
            .bit_left,
            .bit_right,
            => 5,
            .add,
            .sub,
            => 6,
            .star,
            .div,
            => 7,
            .dot,
            .open_paren,
            .open_bracket,
            .open_body,
            => 8,
            .increment,
            .decrement,
            .bit_not,
            => 9,
            else => 0,
        };
    }

    fn parseExpr(self: *Parser, min: u8, previous: *const std.Progress.Node) !*Node {
        var parent_node = previous.start("Expression", 0);
        defer parent_node.end();

        const lhs_i = self.current;
        const lhs_t = self.advance();

        var lhs = try self.allocator.create(Node);
        lhs.* = blk: switch (lhs_t.kind) {
            .number_literal => Node{
                .data = .{
                    .token = lhs_i,
                },
                .tag = .integer,
                .start = lhs_t.start,
                .end = lhs_t.end,
            },
            .kw_true,
            .kw_false,
            => Node{
                .data = .{
                    .token = lhs_i,
                },
                .tag = switch (lhs_t.kind) {
                    .kw_false => .false,
                    .kw_true => .true,
                    else => unreachable,
                },
                .start = lhs_t.start,
                .end = lhs_t.end,
            },
            .string_literal => Node{
                .data = .{
                    .token = lhs_i,
                },
                .tag = .string,
                .start = lhs_t.start,
                .end = lhs_t.end,
            },
            .identifier => Node{
                .data = .{
                    .token = lhs_i,
                },
                .tag = .identifier,
                .start = lhs_t.start,
                .end = lhs_t.end,
            },
            .at => {
                const name_tok_i = self.current;
                _ = try self.expect(.identifier);
                _ = try self.expect(.open_paren);

                var args = try ArrayList(*Node).initCapacity(self.allocator, 2);
                while (!self.matches(.close_paren)) {
                    try args.append(self.allocator, try self.parseExpr(0, &parent_node));
                    if (self.matches(.comma)) {
                        _ = self.advance();
                    } else {
                        break;
                    }
                }
                const close_p = try self.expect(.close_paren);

                break :blk Node{
                    .data = .{
                        .builtin = .{
                            .name = name_tok_i,
                            .args = try args.toOwnedSlice(self.allocator),
                        },
                    },
                    .tag = .builtin,
                    .start = lhs_t.start,
                    .end = close_p.end,
                };
            },
            .open_paren => {
                const expr = try self.parseExpr(0, &parent_node);
                _ = try self.expectMsg(.close_paren, "expected ')' to close '('");
                break :blk expr.*;
            },
            .not,
            .sub,
            => {
                const expr = try self.parseExpr(0, &parent_node);
                const tag: Tag = switch (lhs_t.kind) {
                    .not => .unary_op_not,
                    .sub => .unary_op_neg,
                    else => unreachable,
                };
                break :blk Node{
                    .data = .{
                        .unary_op = .{
                            .right = expr,
                        },
                    },
                    .tag = tag,
                    .start = lhs_t.start,
                    .end = expr.end,
                };
            },
            else => {
                try self.logger.add(.{
                    .kind = .{ .ParseError = .ExpectedExpression },
                    .start = lhs_t.start,
                    .end = lhs_t.end,
                    .message = try self.allocator.print(
                        "expected an expression, found '{s}'",
                        .{describeKind(lhs_t.kind)},
                    ),
                });
                return error.ParseError;
            },
        };
        while (!self.isAtEnd()) {
            const nextt = self.peek();
            const importance = self.getImportance(nextt.kind);
            if (importance == 0 or importance <= min)
                break;

            switch (nextt.kind) {
                .kw_as => {
                    _ = self.advance();
                    const ty = try self.parseType(&parent_node);
                    const old = lhs;
                    lhs = try self.allocator.create(Node);
                    lhs.* = Node{
                        .start = old.start,
                        .end = self.peek().end,
                        .ty = ty,
                        .tag = .cast,
                        .data = .{
                            .cast = .{
                                .expr = old,
                            },
                        },
                    };
                },
                .dot => {
                    _ = self.advance();
                    const target = try self.expect(.identifier);

                    const old = lhs;
                    lhs = try self.allocator.create(Node);
                    lhs.* = Node{
                        .data = .{
                            .property_access = .{
                                .target = old,
                                .name = self.current - 1,
                            },
                        },
                        .tag = .property_access,
                        .start = old.start,
                        .end = target.end,
                    };
                },
                .open_paren => {
                    _ = self.advance();

                    var args_node = parent_node.start("Arguments", 0);
                    var args = try ArrayList(*Node).initCapacity(self.allocator, 4);
                    while (!self.matches(.close_paren)) {
                        args_node.increaseEstimatedTotalItems(1);
                        try args.append(self.allocator, try self.parseExpr(0, &args_node));
                        if (self.matches(.comma)) {
                            _ = try self.expect(.comma);
                        } else {
                            break;
                        }
                    }
                    const end = try self.expectMsg(.close_paren, "expected ')' to close function call");
                    args_node.end();
                    const old = lhs;

                    lhs = try self.allocator.create(Node);
                    lhs.* = .{
                        .data = .{
                            .call = .{
                                .args = try args.toOwnedSlice(self.allocator),
                                .callee = old,
                            },
                        },
                        .tag = .call,
                        .start = old.start,
                        .end = end.end,
                    };
                },
                .open_body => {
                    if (self.next().kind != .dot and self.next().kind != .close_body)
                        break;

                    const start = self.advance();
                    var fields = try ArrayList(*Node).initCapacity(self.allocator, 5);
                    while (!self.isAtEnd() and !self.matches(.close_body)) {
                        const sstart = self.current;
                        _ = try self.expect(.dot);
                        const name = self.current;
                        _ = try self.expectMsg(.identifier, "expected field name");

                        _ = try self.expect(.assign);
                        const v = try self.parseExpr(0, &parent_node);

                        const n = try self.allocator.create(Node);
                        n.* = .{
                            .data = .{
                                .field_init = .{
                                    .name = name,
                                    .val = v,
                                },
                            },
                            .tag = .field_init,
                            .start = self.tokens[sstart].start,
                            .end = v.end,
                        };
                        try fields.append(self.allocator, n);

                        if (self.peek().kind == .comma) {
                            _ = self.advance();
                        } else {
                            break;
                        }
                    }
                    _ = try self.expect(.close_body);

                    const node = try self.allocator.create(Node);
                    node.* = .{
                        .data = .{
                            .struct_init = .{
                                .name = lhs,
                                .fields = try fields.toOwnedSlice(self.allocator),
                            },
                        },
                        .tag = .struct_init,
                        .start = start.start,
                        .end = self.peek().end,
                    };
                },
                .assign,
                .add_assign,
                .sub_assign,
                .mul_assign,
                .div_assign,
                => {
                    const op = self.advance();
                    const tag: Tag = switch (op.kind) {
                        .assign => .assign,
                        .add_assign => .assign_add,
                        .sub_assign => .assign_sub,
                        .mul_assign => .assign_mul,
                        .div_assign => .assign_div,
                        else => unreachable,
                    };
                    const val = try self.parseExpr(importance, &parent_node);

                    const old = lhs;
                    lhs = try self.allocator.create(Node);
                    lhs.* = Node{
                        .data = .{
                            .assignment = .{
                                .right = val,
                                .target = old,
                            },
                        },
                        .tag = tag,
                        .start = old.start,
                        .end = val.end,
                    };
                },
                .increment,
                .decrement,
                => {
                    const op = self.advance();
                    const tag: Tag = switch (op.kind) {
                        .increment => .unary_op_incr,
                        .decrement => .unary_op_decr,
                        else => unreachable,
                    };

                    const old = lhs;
                    lhs = try self.allocator.create(Node);
                    lhs.* = Node{
                        .data = .{
                            .unary_op = .{
                                .right = old,
                            },
                        },
                        .tag = tag,
                        .start = old.start,
                        .end = op.end,
                    };
                },
                .open_bracket,
                => {
                    _ = try self.expect(.open_bracket);

                    const val = try self.parseExpr(0, &parent_node);
                    _ = try self.expectMsg(.close_bracket, "expected ']' to close '['");

                    const old = lhs;
                    lhs = try self.allocator.create(Node);
                    lhs.* = Node{
                        .data = .{
                            .array_access = .{
                                .target = old,
                                .value = val,
                            },
                        },
                        .tag = .array_access,
                        .start = old.start,
                        .end = self.peek().end,
                    };
                },
                else => {
                    const op = self.advance();
                    const tag: Tag = switch (op.kind) {
                        .add => .binary_op_add,
                        .sub => .binary_op_sub,
                        .star => .binary_op_mul,
                        .div => .binary_op_div,
                        .equal => .binary_op_eq,
                        .not_equal => .binary_op_not_eq,
                        .gt => .binary_op_gt,
                        .lt => .binary_op_lt,
                        .gt_eq => .binary_op_gt_eq,
                        .lt_eq => .binary_op_lt_eq,
                        .bit_and => .binary_op_bit_and,
                        .bit_or => .binary_op_bit_or,
                        .bit_xor => .binary_op_bit_xor,
                        .bit_not => .binary_op_bit_not,
                        .bit_left => .binary_op_bit_left,
                        .bit_right => .binary_op_bit_right,
                        else => unreachable,
                    };

                    const rhs = try self.parseExpr(importance, &parent_node);

                    const old = lhs;
                    lhs = try self.allocator.create(Node);
                    lhs.* = Node{
                        .data = .{
                            .binary_op = .{
                                .left = old,
                                .right = rhs,
                            },
                        },
                        .tag = tag,
                        .start = old.start,
                        .end = rhs.end,
                    };
                },
            }
        }
        return lhs;
    }

    const ModTag = union(enum) {
        ptr,
        array: *Node,
        slice,
    };

    fn parseType(self: *Parser, previous: *const std.Progress.Node) Err!Type.Handle {
        var mods = try ArrayList(ModTag).initCapacity(self.allocator, 3);
        defer mods.deinit(self.allocator);

        while (!self.isAtEnd()) {
            if (self.matches(.star)) {
                _ = self.advance();
                try mods.append(self.allocator, .ptr);
            } else if (self.matches(.open_bracket)) {
                _ = self.advance();
                var size: ?*Node = null;

                if (self.peek().kind == .close_bracket) {
                    _ = self.advance();
                    try mods.append(self.allocator, .slice);
                    continue;
                }
                size = try self.parseExpr(0, previous);

                _ = try self.expectMsg(.close_bracket, "expected ']' to close '['");

                try mods.append(self.allocator, .{
                    .array = size.?,
                });
            } else break;
        }

        const base_t = self.advance();
        var ty: Type.Handle = blk: switch (base_t.kind) {
            .kw_i8 => .i8,
            .kw_i16 => .i16,
            .kw_i32 => .i32,
            .kw_i64 => .i64,
            .kw_u8 => .u8,
            .kw_u16 => .u16,
            .kw_u32 => .u32,
            .kw_u64 => .u64,
            .kw_void => .void,
            .kw_bool => .bool,
            .arrow => {
                const return_ty = try self.parseType(previous);

                var params = try ArrayList(Type.Handle).initCapacity(self.allocator, 5);
                if (self.matches(.open_paren)) {
                    _ = try self.expect(.open_paren);
                    while (!self.matches(.close_paren)) {
                        const h = try self.parseType(previous);
                        try params.append(self.allocator, h);
                    }
                    _ = try self.expectMsg(.close_paren, "expected ')' to close '('");
                }

                break :blk try self.file_table.getOrAddType(.{
                    .@"fn" = .{
                        .return_type = return_ty,
                        .params = try params.toOwnedSlice(self.allocator),
                    },
                });
            },
            .identifier => {
                const pstart = self.current - 1;

                while (self.matches(.dot)) {
                    _ = try self.expect(.dot);
                    _ = try self.expect(.identifier);
                }
                const pend = self.current;

                if (self.matches(.lt)) {
                    _ = self.advance();
                    var generics = try ArrayList(Type.Handle).initCapacity(self.allocator, 2);

                    while (!self.matches(.gt) and !self.isAtEnd()) {
                        const h = try self.parseType(previous);
                        try generics.append(self.allocator, h);
                        if (self.matches(.comma)) {
                            _ = self.advance();
                        } else {
                            break;
                        }
                    }
                    _ = try self.expectMsg(.gt, "expected '>' to close '<'");

                    break :blk try self.file_table.getOrAddType(.{
                        .named = .{
                            .path = .{
                                .start = pstart,
                                .end = pend,
                            },
                            .generics = try generics.toOwnedSlice(self.allocator),
                        },
                    });
                } else {
                    break :blk try self.file_table.getOrAddType(.{
                        .named = .{
                            .path = .{
                                .start = pstart,
                                .end = pend,
                            },
                        },
                    });
                }
            },
            else => {
                try self.logger.add(.{
                    .start = base_t.start,
                    .end = base_t.end,
                    .kind = .{ .ParseError = .UnexpectedTypeToken },
                    .message = try self.allocator.print(
                        "expected type expression, found '{s}'",
                        .{self.file_table.tokenStr(self.peek(), self.file)},
                    ),
                });
                return error.ParseError;
            },
        };

        for (mods.items) |mod| {
            switch (mod) {
                .ptr => {
                    ty = try self.file_table.getOrAddType(.{
                        .ptr = .{
                            .inner = ty,
                        },
                    });
                },
                .array => {
                    ty = try self.file_table.getOrAddType(.{
                        .array = .{
                            .inner = ty,
                            .length = mod.array,
                        },
                    });
                },
                .slice => {
                    ty = try self.file_table.getOrAddType(.{
                        .slice = .{
                            .inner = ty,
                        },
                    });
                },
            }
        }

        return ty;
    }

    fn parseFn(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var pn = previous.start("Fn", 3);
        defer pn.end();

        const start = (try self.expect(.kw_fn)).start;

        const namei = self.current;
        _ = try self.expect(.identifier);

        var generics = try ArrayList(Type.Handle).initCapacity(self.allocator, 2);
        if (self.matches(.lt)) {
            _ = self.advance();
            while (!self.isAtEnd() and !self.matches(.gt)) {
                const h = try self.parseType(&pn);
                try generics.append(self.allocator, h);
            }
            _ = try self.expectMsg(.gt, "expected '>' to close '<'");
        }
        _ = try self.expect(.open_paren);

        var params = try ArrayList(*Node).initCapacity(self.allocator, 4);

        while (!self.isAtEnd() and !self.matches(.close_paren)) {
            const pname = self.current;
            _ = try self.expectMsg(.identifier, "expected parameter name");
            _ = try self.expectMsg(.colon, "expected ':' before parameter type");

            const pty = try self.parseType(&pn);

            const node = try self.allocator.create(Node);
            node.* = Node{
                .start = self.tokens[pname].start,
                .end = self.peek().end,
                .ty = pty,
                .tag = .param,
                .data = .{
                    .param = .{
                        .name = pname,
                    },
                },
            };
            try params.append(self.allocator, node);
        }
        _ = try self.expect(.close_paren);

        const retty = try self.parseType(&pn);

        _ = try self.expect(.open_body);
        const body = try self.parseBlock(previous);
        const end = try self.expect(.close_body);

        const node = try self.allocator.create(Node);
        node.* = Node{
            .start = start,
            .end = end.end,
            .ty = retty,
            .tag = .fn_stmt,
            .data = .{
                .fn_stmt = .{
                    .name = namei,
                    .body = body,
                    .params = try params.toOwnedSlice(self.allocator),
                    .generics = try generics.toOwnedSlice(self.allocator),
                },
            },
        };
        return node;
    }

    fn parseLet(self: *Parser, previous: *const std.Progress.Node) !*Node {
        const start = try self.expect(.kw_let);

        var mut = false;
        if (self.matches(.kw_mut)) {
            _ = self.advance();
            mut = true;
        }

        const name = self.current;
        _ = try self.expectMsg(.identifier, "expected variable name");

        var ty: ?Type.Handle = null;
        if (self.matches(.colon)) {
            _ = self.advance();
            ty = try self.parseType(previous);
        }

        _ = try self.expect(.assign);
        const val = try self.parseExpr(0, previous);

        const node = try self.allocator.create(Node);
        node.* = Node{
            .start = start.start,
            .end = self.peek().end,
            .ty = ty,
            .tag = if (mut) .let_mut_stmt else .let_stmt,
            .data = .{
                .let_stmt = .{
                    .name = name,
                    .val = val,
                },
            },
        };
        return node;
    }

    fn parseRet(self: *Parser, previous: *const std.Progress.Node) !*Node {
        const start = self.current;
        _ = try self.expect(.kw_ret);

        var val: ?*Node = undefined;
        if (!self.matches(.semicolon)) {
            val = try self.parseExpr(0, previous);
        } else {
            val = null;
        }

        const node = try self.allocator.create(Node);
        node.* = Node{
            .data = .{
                .ret_stmt = .{
                    .val = val,
                },
            },
            .tag = .ret_stmt,
            .start = self.tokens[start].start,
            .end = self.peek().end,
        };
        return node;
    }

    fn parseIf(self: *Parser, previous: *const std.Progress.Node) (error{ParseError} || Allocator.Error)!*Node {
        const start = self.current;
        _ = try self.expect(.kw_if);

        const expr = try self.parseExpr(0, previous);

        var body: *Node = undefined;
        if (self.matches(.open_body)) {
            const sstart = self.current;
            _ = self.advance();

            const block = try self.parseBlock(previous);
            _ = try self.expect(.close_body);

            body = try self.allocator.create(Node);
            body.* = .{
                .data = .{
                    .block = .{
                        .body = block,
                    },
                },
                .tag = .block,
                .start = self.tokens[sstart].start,
                .end = self.peek().end,
            };
        } else {
            _ = try self.expectMsg(.colon, "expected ':' or '{' to begin if statement");
            body = try self.parseStmt(previous);
        }

        var else_branch: ?*Node = null;
        if (self.matches(.kw_else)) {
            _ = self.advance();

            if (self.matches(.open_body)) {
                const estart = self.advance();

                const block = try self.parseBlock(previous);
                else_branch = try self.allocator.create(Node);
                else_branch.?.* = Node{
                    .data = .{
                        .block = .{
                            .body = block,
                        },
                    },
                    .tag = .block,
                    .start = estart.start,
                    .end = self.peek().end,
                };

                _ = try self.expect(.close_body);
            } else {
                else_branch = try self.parseStmt(previous);
            }
        }

        const node = try self.allocator.create(Node);
        node.* = Node{
            .data = .{
                .if_stmt = .{
                    .cond = expr,
                    .body = body,
                    .else_branch = else_branch,
                },
            },
            .tag = .if_stmt,
            .start = self.tokens[start].start,
            .end = self.peek().end,
        };
        return node;
    }

    fn parseFor(self: *Parser, previous: *const std.Progress.Node) !*Node {
        const start = self.current;
        _ = try self.expect(.kw_for);

        var vari: ?*Node = null;
        var cond: ?*Node = undefined;
        var incr: ?*Node = undefined;

        const node = try self.allocator.create(Node);
        // special case for nothing
        if (self.matches(.open_body) or self.matches(.colon)) {
            var body: *Node = undefined;
            if (self.matches(.open_body)) {
                const sstart = self.current;
                _ = self.advance();

                body = try self.allocator.create(Node);
                body.* = .{
                    .data = .{
                        .block = .{
                            .body = try self.parseBlock(previous),
                        },
                    },
                    .tag = .block,
                    .start = self.tokens[sstart].start,
                    .end = self.peek().end,
                };
                _ = try self.expect(.close_body);
            } else {
                _ = try self.expectMsg(.colon, "expected ':' or '{' to begin for statement");
                body = try self.parseStmt(previous);
            }
            node.* = Node{
                .data = .{
                    .for_stmt = .{
                        .vari = null,
                        .cond = null,
                        .incr = null,
                        .body = body,
                    },
                },
                .tag = .for_stmt,
                .start = start,
                .end = self.peek().end,
            };
            return node;
        }
        // special case for an expression (while)
        if (!self.matches(.kw_let) and !self.matches(.semicolon)) {
            cond = try self.parseExpr(0, previous);

            var body: *Node = undefined;
            if (self.matches(.open_body)) {
                const sstart = self.current;
                _ = self.advance();

                body = try self.allocator.create(Node);
                body.* = Node{
                    .data = .{
                        .block = .{
                            .body = try self.parseBlock(previous),
                        },
                    },
                    .tag = .block,
                    .start = self.tokens[sstart].start,
                    .end = self.peek().end,
                };
            } else {
                _ = try self.expect(.colon);
                body = try self.parseStmt(previous);
            }

            node.* = Node{
                .data = .{
                    .for_stmt = .{
                        .vari = null,
                        .incr = null,
                        .cond = cond,
                        .body = body,
                    },
                },
                .tag = .for_stmt,
                .start = self.tokens[start].start,
                .end = self.peek().end,
            };
            return node;
        }

        if (self.matches(.kw_let)) {
            vari = try self.parseLet(previous);
        }
        _ = try self.expect(.semicolon);

        if (self.matches(.semicolon)) {
            cond = null;
        } else {
            cond = try self.parseExpr(0, previous);
        }
        _ = try self.expect(.semicolon);

        if (self.matches(.colon) or self.matches(.open_body)) {
            incr = null;
        } else {
            incr = try self.parseExpr(0, previous);
        }

        var body: *Node = undefined;
        if (self.matches(.open_body)) {
            const sstart = self.current;
            _ = try self.expect(.open_body);
            body = try self.allocator.create(Node);
            body.* = .{
                .data = .{
                    .block = .{
                        .body = try self.parseBlock(previous),
                    },
                },
                .tag = .block,
                .start = self.tokens[sstart].start,
                .end = self.peek().end,
            };
            _ = try self.expect(.close_body);
        } else {
            _ = try self.expect(.colon);
            body = try self.parseStmt(previous);
        }
        node.* = Node{
            .data = .{
                .for_stmt = .{
                    .vari = vari,
                    .cond = cond,
                    .incr = incr,
                    .body = body,
                },
            },
            .tag = .for_stmt,
            .start = start,
            .end = self.peek().end,
        };
        return node;
    }

    fn parseStruct(self: *Parser, previous: *const std.Progress.Node) !*Node {
        const start = self.current;
        _ = try self.expect(.kw_struct);

        const name = self.current;
        _ = try self.expect(.identifier);

        _ = try self.expect(.open_body);
        var fields = try ArrayList(*Node).initCapacity(self.allocator, 5);
        while (!self.isAtEnd() and !self.matches(.close_body)) {
            const fname = self.current;

            var @"pub" = false;
            if (self.matches(.kw_pub)) {
                _ = self.advance();
                @"pub" = true;
            }

            var mut = false;
            if (self.matches(.kw_mut)) {
                _ = self.advance();
                mut = true;
            }

            _ = try self.expectMsg(.identifier, "expected field name");
            _ = try self.expectMsg(.colon, "expected ':' before field type");
            const ftype = try self.parseType(previous);

            const node = try self.allocator.create(Node);
            node.* = Node{
                .start = self.tokens[fname].start,
                .end = self.peek().end,
                .ty = ftype,
                .tag = .struct_field,
                .data = .{
                    .struct_field = .{
                        .name = fname,
                        .@"pub" = @"pub",
                        .mut = mut,
                    },
                },
            };

            try fields.append(self.allocator, node);
            if (self.matches(.comma)) {
                _ = self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.close_body);

        const node = try self.allocator.create(Node);
        node.* = Node{
            .data = .{
                .struct_stmt = .{
                    .name = name,
                    .fields = try fields.toOwnedSlice(self.allocator),
                },
            },
            .tag = .struct_stmt,
            .start = self.tokens[start].start,
            .end = self.peek().end,
        };
        return node;
    }

    fn parsePub(self: *Parser) !*Node {
        const start = self.current;
        _ = try self.expect(.kw_pub);

        const stmt = try self.parseTop();
        if (stmt.tag == .pub_stmt) {
            try self.logger.add(.{
                .start = self.tokens[start].start,
                .end = self.tokens[start].end,
                .kind = .{ .ParseError = .PubTwice },
                .message = "top level statement cannot be pub twice",
            });
            return error.ParseError;
        }

        const node = try self.allocator.create(Node);
        node.* = Node{
            .start = self.tokens[start].start,
            .end = node.end,
            .tag = .pub_stmt,
            .data = .{
                .pub_stmt = .{
                    .stmt = node,
                },
            },
        };
        return node;
    }

    pub fn parseImport(self: *Parser, prev: *const std.Progress.Node) !*Node {
        var pnt = prev.start("Parsing import", 0);
        defer pnt.end();

        const start = self.current;
        _ = try self.expect(.kw_import);

        // allow multiple import { }
        if (self.matches(.open_body)) {
            var imports = try std.ArrayList(*Node).initCapacity(self.allocator, 3);
            while (!self.isAtEnd() and !self.matches(.close_body)) {
                const this_start = self.current;
                var handle: FileHandle = undefined;
                if (self.matches(.string_literal)) {
                    const tkni = self.current;
                    const tkn = self.advance();

                    const rel_path = self.file_table.spanStr(
                        self.file,
                        tkn.start,
                        tkn.end,
                    );
                    const abs_path = try std.fs.path.join(self.allocator, &.{
                        self.file_table.getPath(self.file),
                        rel_path,
                    });

                    handle = try self.loadFile(abs_path, tkni, &pnt);
                } else {
                    _ = try self.expectMsg(.lt, "expected '<(file)>' or '\"(file)\"'");
                    const tkni = self.current;
                    const tkn = try self.expectMsg(.identifier, "expected file name");
                    _ = try self.expectMsg(.gt, "expected '>' to close '<'");

                    const rel_path = self.file_table.spanStr(
                        self.file,
                        tkn.start,
                        tkn.end,
                    );
                    const abs_path = try std.fs.path.join(self.allocator, &.{
                        self.lib_dir,
                        rel_path,
                    });
                    handle = try self.loadFile(abs_path, tkni, &pnt);
                }
                _ = try self.expectMsg(.kw_as, "mish requires explicit namespace naming");
                const alias = self.current;
                _ = try self.expectMsg(.identifier, "expected module alias");

                const node = try self.allocator.create(Node);
                node.* = Node{
                    .start = self.tokens[this_start].start,
                    .end = self.peek().end,
                    .tag = .import,
                    .data = .{
                        .import_stmt = .{
                            .file = handle,
                            .alias = alias,
                        },
                    },
                };
                try imports.append(self.allocator, node);
            }
            const end = self.current;
            _ = try self.expectMsg(.close_body, "expected '}' to close '{' of import");

            const node = try self.allocator.create(Node);
            node.* = Node{
                .start = self.tokens[start].start,
                .end = self.tokens[end].end,
                .tag = .import_collection,
                .data = .{
                    .block = .{
                        .body = try imports.toOwnedSlice(self.allocator),
                    },
                },
            };
            return node;
        }
        // single import
        var handle: FileHandle = undefined;
        if (self.matches(.string_literal)) {
            const tkni = self.current;
            const tkn = self.advance();

            const rel_path = self.file_table.tokenStr(tkn, self.file);
            const abs_path = try std.fs.path.join(self.allocator, &.{
                std.fs.path.dirname(self.file_table.getPath(self.file)).?,
                rel_path,
            });
            handle = try self.loadFile(abs_path, tkni, &pnt);
        } else {
            _ = try self.expectMsg(.lt, "expected '<(file)>' or '\"(file)\"'");
            const tkni = self.current;
            const tkn = try self.expectMsg(.identifier, "expected file name");
            _ = try self.expectMsg(.gt, "expected '>' to close '<'");

            const rel_path = self.file_table.tokenStr(tkn, self.file);
            const abs_path = try std.fs.path.join(self.allocator, &.{
                self.lib_dir,
                rel_path,
            });
            handle = try self.loadFile(abs_path, tkni, &pnt);
        }
        _ = try self.expectMsg(.kw_as, "mish requires explicit namespace naming using 'as <name>'");
        const alias = self.current;
        _ = try self.expectMsg(.identifier, "expected module alias");

        const node = try self.allocator.create(Node);
        node.* = Node{
            .start = self.tokens[start].start,
            .end = self.peek().end,
            .tag = .import,
            .data = .{
                .import_stmt = .{
                    .file = handle,
                    .alias = alias,
                },
            },
        };
        return node;
    }

    pub fn loadFile(self: *Parser, abs_path: []const u8, tkn: Token.Handle, prev: *const std.Progress.Node) !FileHandle {
        if (self.file_table.fromPath(abs_path)) |handle| {
            return handle;
        }

        const file = std.Io.Dir.openFileAbsolute(self.io, abs_path, .{}) catch |erro| {
            switch (erro) {
                error.FileNotFound => try self.logger.add(Error{
                    .start = self.tokens[tkn].start,
                    .end = self.tokens[tkn].end,
                    .kind = .{ .ParseError = .ImportFileNotFound },
                    .message = "file not found",
                }),
                else => try self.logger.add(Error{
                    .start = self.tokens[tkn].start,
                    .end = self.tokens[tkn].end,
                    .kind = .{ .ParseError = .ImportError },
                    .message = try self.allocator.print("could not import file: {s}", .{@errorName(erro)}),
                }),
            }
            return error.ParseError;
        };
        defer file.close(self.io);

        const ext = std.fs.path.extension(abs_path);
        if (!std.mem.eql(u8, ext, ".msh")) {
            try self.logger.add(Error{
                .start = self.tokens[tkn].start,
                .end = self.tokens[tkn].end,
                .kind = .{ .ParseError = .ImportWrongExt },
                .message = try self.allocator.print("file must have a .msh extension, got '{s}'", .{ext}),
            });
            return error.ParseError;
        }

        var read_buf: [1024]u8 = undefined;
        var reader = file.reader(self.io, &read_buf);

        const source = try reader.interface.allocRemaining(self.allocator, .unlimited);
        const handle = try self.file_table.addFile(.{ .path = abs_path, .source = source });

        var lexer = lex.Lexer.init(self.allocator, handle, self.file_table);
        const tokens = try lexer.run(self.writer, prev.*);

        var parser = init(
            self.allocator,
            self.writer,
            self.io,
            tokens,
            self.file_table,
            handle,
            self.lib_dir,
            prev,
        );
        self.file_table.files.items(.ast)[handle] = try parser.run();

        var checker = Sema.init(
            self.allocator,
            self.writer,
            self.file_table,
            handle,
            prev,
        );
        try checker.run();

        return handle;
    }
};
