const std = @import("std");

const lex = @import("lex.zig");
const Token = lex.Token;
pub const TokenHandle = lex.TokenHandle;

const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;

const Error = err.Error;
const ErrorType = err.ErrorType;

const ft = @import("file_table.zig");
const FileTable = ft.FileTable;
const FileHandle = ft.FileHandle;

pub const Tag = enum {
    integer,
    string,
    false,
    true,
    null,
    identifier,
    builtin,
    property_access,
    array_access,
    binary_op_add,
    binary_op_sub,
    binary_op_mul,
    binary_op_div,
    binary_op_eq,
    binary_op_not_eq,
    binary_op_gt,
    binary_op_lt,
    binary_op_lt_eq,
    binary_op_gt_eq,
    binary_op_bit_and,
    binary_op_bit_or,
    binary_op_bit_xor,
    binary_op_bit_not,
    binary_op_bit_left,
    binary_op_bit_right,
    unary_op_at,
    unary_op_neg,
    unary_op_not,
    unary_op_decr,
    unary_op_incr,
    assign,
    assign_add,
    assign_sub,
    assign_mul,
    assign_div,
    call,
    struct_init,
    field_init,
    block,
    let_stmt,
    fn_stmt,
    param,
    ret_stmt,
    if_stmt,
    for_stmt,
    struct_stmt,
    pub_stmt,
    cast,
};

pub const Data = union {
    token: TokenHandle,
    builtin: struct {
        name: TokenHandle,
        args: []*Node,
    },
    property_access: struct {
        target: *Node,
        name: TokenHandle,
    },
    array_access: struct {
        target: *Node,
        value: *Node,
    },
    binary_op: struct {
        left: *Node,
        right: *Node,
    },
    unary_op: struct {
        right: *Node,
    },
    assignment: struct {
        target: *Node,
        right: *Node,
    },
    call: struct {
        args: []*Node,
        callee: *Node,
    },
    struct_init: struct {
        name: ?*Node,
        fields: []*Node,
    },
    field_init: struct {
        name: TokenHandle,
        val: *Node,
    },
    block: struct {
        body: []*Node,
    },
    let_stmt: struct {
        ty: ?TypeHandle,
        mut: bool,
        name: TokenHandle,
        val: ?*Node,
    },
    fn_stmt: struct {
        name: TokenHandle,
        params: []*Node,
        gens: struct {
            start: TypeHandle,
            end: TypeHandle,
        },
        body: []*Node,
        returns: TypeHandle,
    },
    param: struct {
        name: TokenHandle,
        ty: TypeHandle,
    },
    ret_stmt: struct {
        val: ?*Node,
    },
    if_stmt: struct {
        cond: *Node,
        body: *Node,
        else_branch: ?*Node,
    },
    for_stmt: struct {
        vari: ?*Node,
        cond: ?*Node,
        incr: ?*Node,
        body: *Node,
    },
    struct_stmt: struct {
        name: TokenHandle,
        fields: []*Node,
    },
    pub_stmt: struct {
        stmt: *Node,
    },
    cast: struct {
        expr: *Node,
        ty: TypeHandle,
    },
    import_stmt: struct {
        file: FileHandle,
        alias: TokenHandle,
    },
};

pub const TypeHandle = usize;

pub const Field = struct {
    name: []const u8,
    ty: TypeHandle,
    mut: bool,
};

pub const Type = union(enum) {
    void,
    null,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    bool,
    func: struct {
        returns: TypeHandle,
        params_start: usize,
        params_end: usize,
    },
    ptr: TypeHandle,
    array: struct {
        ty: TypeHandle,
        len: *Node,
    },
    slice: TypeHandle,
    strct: struct {
        name: []const u8,
        fields: []Field,
    },
    named: struct {
        path: struct {
            start: TokenHandle,
            end: TokenHandle,
        },
        gens: ?struct {
            start: TypeHandle,
            end: TypeHandle,
        },
    },
};

pub const TypeNode = struct {
    ty: Type,
    start: usize,
    end: usize,
};

pub const Node = struct {
    data: Data,
    tag: Tag,
    start: usize,
    end: usize,
    file: FileHandle,
};

pub const ParseError = enum(u8) {
    UnexpectedToken = 0,
    ExpectedStatement = 1,
    ExpectedTopLevelStatement = 2,
    ExpectedVariableStmt = 3,
    ExpectedExpression = 4,
    ExpectedTypeExpression = 5,
    UnexpectedKwInStruct = 6,
    UnexpectedDefaultValue = 7,
    MutFunction = 8,
    UnexpectedTypeToken = 9,
};

pub const Parser = struct {
    file_table: *FileTable,
    tokens: []Token,
    current: TokenHandle = 0,

    allocator: std.mem.Allocator,

    logger: ErrorLogger,
    writer: *std.Io.Writer,
    root_node: *const std.Progress.Node,

    types: std.ArrayList(TypeNode),

    pub fn init(
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        tokens: []Token,
        file_table: *FileTable,
        progress: *const std.Progress.Node,
    ) Parser {
        return Parser{
            .file_table = file_table,
            .tokens = tokens,
            .allocator = allocator,
            .logger = .init(file_table),
            .writer = writer,
            .types = std.ArrayList(TypeNode).initCapacity(allocator, tokens.len / 30) catch std.ArrayList(TypeNode).empty,
            .root_node = progress,
        };
    }

    fn peek(self: *Parser) Token {
        if (self.isAtEnd()) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.current];
    }

    fn next(self: *Parser) Token {
        if (self.current + 1 >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.current + 1];
    }

    fn advance(self: *Parser) Token {
        if (self.isAtEnd())
            return self.tokens[self.current - 1];
        const token = self.tokens[self.current];
        self.current += 1;
        return token;
    }

    fn expect(self: *Parser, kind: Token.Kind, node: *std.Progress.Node) !Token {
        const t = self.advance();
        if (t.kind == kind) {
            return t;
        }
        const fmt = try self.allocator.print(
            "expected '{s}', found '{s}' ({s})",
            .{
                describeKind(kind),
                self.file_table.spanStr(t.file, t.start, t.end),
                @tagName(t.kind),
            },
        );
        self.current -= 1;
        try self.logger.add(self.allocator, Error{
            .message = fmt,
            .start = t.start,
            .end = t.end,
            .file = t.file,
            .kind = .{ .ParseError = .UnexpectedToken },
        });
        self.current += 1;
        const newname = try self.allocator.print("\x1b[31m{s}\x1b[0m", .{node.getName()});
        node.setName(newname);

        return error.UnexpectedToken;
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
            .kw_fn => "fn",
            .kw_let => "let",
            .kw_mut => "mut",
            .kw_ret => "ret",
            .kw_if => "if",
            .kw_and => "and",
            .kw_or => "or",
            .kw_for => "for",
            .kw_pub => "pub",
            .kw_struct => "struct",
            .kw_as => "as",
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

    pub fn run(self: *Parser) ![]*Node {
        var nodes = try std.ArrayList(*Node).initCapacity(self.allocator, self.tokens.len / 12);
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
        const array = try nodes.toOwnedSlice(self.allocator);
        return array;
    }

    fn parseBlock(self: *Parser, previous: *std.Progress.Node) ![]*Node {
        //var parent_node = previous.start("Body", 0);
        //defer parent_node.end();

        var body = try std.ArrayList(*Node).initCapacity(self.allocator, 24);

        while (!self.isAtEnd()) {
            if (self.peek().kind == .close_body) {
                break;
            }
            previous.increaseEstimatedTotalItems(1);
            try body.append(self.allocator, try self.parseStmt(previous)); //&parent_node));
        }
        return body.toOwnedSlice(self.allocator);
    }

    fn parseTop(self: *Parser) anyerror!*Node {
        const msg = try self.allocator.print("Top-level statement (token {})", .{self.current});
        const top_node = self.root_node.start(msg, 1);
        defer top_node.end();

        switch (self.peek().kind) {
            //.kw_struct => return try self.parseStruct(&top_node),
            .kw_pub => return try self.parsePub(&top_node),
            .kw_let => return try self.parseLet(&top_node),
            .kw_fn => return try self.parseFn(&top_node),
            else => {
                const found_top = self.peek();
                try self.logger.add(self.allocator, .{
                    .kind = .{ .ParseError = ParseError.ExpectedTopLevelStatement },
                    .start = found_top.start,
                    .end = self.next().end,
                    .file = found_top.file,
                    .message = try self.allocator.print(
                        "expected a top-level statement ('fn', 'let', 'struct' or 'pub'), found '{s}' ({s})",
                        .{
                            self.file_table.spanStr(found_top.file, found_top.start, found_top.end),
                            @tagName(found_top.kind),
                        },
                    ),
                });
                return error.ExpectedTopLevelStatement;
            },
        }
    }

    fn parseStmt(self: *Parser, previous: *std.Progress.Node) anyerror!*Node {
        var parent_node = previous.start("Statement", 1);
        defer parent_node.end();
        switch (self.peek().kind) {
            .kw_ret => {
                const stmt = try self.parseRet(&parent_node);
                _ = try self.expect(.semicolon, &parent_node);
                return stmt;
            },
            .kw_let => {
                const stmt = try self.parseLet(&parent_node);
                _ = try self.expect(.semicolon, &parent_node);
                return stmt;
            },
            .kw_if => return try self.parseIf(&parent_node),
            .kw_for => return try self.parseFor(&parent_node),
            .open_body => {
                const start = try self.expect(.open_body, &parent_node);
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
                    .file = start.file,
                };
                _ = try self.expect(.close_body, &parent_node);
                return node;
            },
            else => {
                const expr = try self.parseExpr(0, &parent_node);
                _ = try self.expect(.semicolon, &parent_node);
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

    fn parseExpr(self: *Parser, min: u8, previous: *std.Progress.Node) !*Node {
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
                .file = lhs_t.file,
            },
            .kw_true,
            .kw_false,
            .kw_null,
            => Node{
                .data = .{
                    .token = lhs_i,
                },
                .tag = switch (lhs_t.kind) {
                    .kw_false => .false,
                    .kw_true => .true,
                    .kw_null => .null,
                    else => unreachable,
                },
                .start = lhs_t.start,
                .end = lhs_t.end,
                .file = lhs_t.file,
            },
            .string_literal => Node{
                .data = .{
                    .token = lhs_i,
                },
                .tag = .string,
                .start = lhs_t.start,
                .end = lhs_t.end,
                .file = lhs_t.file,
            },
            .identifier => Node{
                .data = .{
                    .token = lhs_i,
                },
                .tag = .identifier,
                .start = lhs_t.start,
                .end = lhs_t.end,
                .file = lhs_t.file,
            },
            .at => {
                const name_tok_i = self.current;
                _ = try self.expect(.identifier, &parent_node);
                _ = try self.expect(.open_paren, &parent_node);

                var args = std.ArrayList(*Node).empty;
                while (!self.matches(.close_paren)) {
                    try args.append(self.allocator, try self.parseExpr(0, &parent_node));
                    if (self.matches(.comma)) {
                        _ = self.advance();
                    } else {
                        break;
                    }
                }
                const close_p = try self.expect(.close_paren, &parent_node);

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
                    .file = close_p.file,
                };
            },
            .open_paren => {
                const expr = try self.parseExpr(0, &parent_node);
                _ = try self.expect(.close_paren, &parent_node);
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
                    .file = expr.file,
                };
            },
            else => {
                try self.logger.add(self.allocator, .{
                    .kind = .{ .ParseError = ParseError.ExpectedExpression },
                    .start = lhs_t.start,
                    .end = lhs_t.end,
                    .file = lhs_t.file,
                    .message = try self.allocator.print(
                        "expected an expression, found '{s}' ({s})",
                        .{
                            self.file_table.spanStr(lhs_t.file, lhs_t.start, lhs_t.end),
                            @tagName(lhs_t.kind),
                        },
                    ),
                });
                return error.ExpectedExpression;
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
                        .end = self.types.items[ty].end,
                        .file = old.file,
                        .tag = .cast,
                        .data = .{
                            .cast = .{
                                .expr = old,
                                .ty = ty,
                            },
                        },
                    };
                },
                .dot => {
                    parent_node.setName("Property access");

                    _ = self.advance();
                    const target = try self.expect(.identifier, &parent_node);

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
                        .file = old.file,
                    };
                },
                .open_paren => {
                    _ = self.advance();
                    parent_node.setName("Function call");
                    parent_node.setEstimatedTotalItems(1);

                    var args_node = parent_node.start("Arguments", 0);
                    var args = try std.ArrayList(*Node).initCapacity(self.allocator, 4);
                    while (!self.matches(.close_paren)) {
                        args_node.increaseEstimatedTotalItems(1);
                        try args.append(self.allocator, try self.parseExpr(0, &args_node));
                        if (self.matches(.comma)) {
                            _ = try self.expect(.comma, &args_node);
                        } else {
                            break;
                        }
                    }
                    const end = try self.expect(.close_paren, &args_node);
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
                        .file = old.file,
                    };
                },
                .open_body => {
                    if (self.next().kind != .dot and self.next().kind != .close_body)
                        break;

                    parent_node.setName("Struct initialization");

                    const start = self.advance();
                    var fields = try std.ArrayList(*Node).initCapacity(self.allocator, 10);
                    while (!self.isAtEnd() and !self.matches(.close_body)) {
                        parent_node.increaseEstimatedTotalItems(1);

                        const st = try self.expect(.dot, &parent_node);
                        const name = self.current;
                        _ = try self.expect(.identifier, &parent_node);

                        _ = try self.expect(.assign, &parent_node);
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
                            .start = st.start,
                            .end = v.end,
                            .file = v.file,
                        };
                        try fields.append(self.allocator, n);

                        if (self.peek().kind == .comma) {
                            _ = self.advance();
                        } else {
                            break;
                        }
                    }
                    _ = try self.expect(.close_body, &parent_node);

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
                        .file = start.file,
                    };
                },
                .assign,
                .add_assign,
                .sub_assign,
                .mul_assign,
                .div_assign,
                => {
                    parent_node.setName("Assignment");
                    parent_node.setEstimatedTotalItems(1);

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
                        .file = old.file,
                    };
                },
                .increment,
                .decrement,
                => {
                    parent_node.setName("Unary operator");

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
                        .file = old.file,
                    };
                },
                .open_bracket,
                => {
                    _ = try self.expect(.open_bracket, &parent_node);
                    parent_node.setName("Array access");
                    parent_node.setEstimatedTotalItems(1);

                    const val = try self.parseExpr(0, &parent_node);
                    _ = try self.expect(.close_bracket, &parent_node);

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
                        .file = old.file,
                    };
                },
                else => {
                    parent_node.setName("Generic binary op");
                    parent_node.setEstimatedTotalItems(1);

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
                        .file = old.file,
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

    fn parseType(self: *Parser, previous: *const std.Progress.Node) error{
        OutOfMemory,
        UnexpectedTypeToken,
        UnexpectedToken,
        ExpectedExpression,
    }!TypeHandle {
        var parent_node = previous.start("Type", 1);
        defer parent_node.end();

        var mods = try std.ArrayList(ModTag).initCapacity(self.allocator, 3);
        defer mods.deinit(self.allocator);

        var try_node = parent_node.start("Collecting Modifiers", 0);
        errdefer try_node.end();
        while (!self.isAtEnd()) {
            if (self.matches(.star)) {
                try_node.increaseEstimatedTotalItems(1);
                var node = try_node.start("Pointer", 0);
                errdefer node.end();

                _ = self.advance();
                try mods.append(self.allocator, .ptr);
                node.end();
            } else if (self.matches(.open_bracket)) {
                try_node.increaseEstimatedTotalItems(1);
                var node = try_node.start("Array", 0);
                defer node.end();

                _ = self.advance();
                var size: ?*Node = null;

                if (self.peek().kind == .close_bracket) {
                    _ = self.advance();
                    try mods.append(self.allocator, .slice);
                    continue;
                }
                node.increaseEstimatedTotalItems(1);
                size = try self.parseExpr(0, &node);

                _ = try self.expect(.close_bracket, &node);

                try mods.append(self.allocator, .{
                    .array = size.?,
                });
            } else break;
        }

        const base_t = self.advance();
        var ty: Type = blk: switch (base_t.kind) {
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
                var this_node = parent_node.start("Function type", 2);
                defer this_node.end();

                const return_ty = try self.parseType(&this_node);
                const params_start = self.types.items.len;

                if (self.matches(.open_paren)) {
                    _ = try self.expect(.open_paren, &this_node);
                    while (!self.matches(.close_paren)) {
                        _ = try self.parseType(&this_node);
                    }
                    _ = try self.expect(.close_paren, &this_node);
                }
                const params_end = self.types.items.len - 1;
                break :blk Type{
                    .func = .{
                        .returns = return_ty,
                        .params_start = params_start,
                        .params_end = params_end,
                    },
                };
            },
            .identifier => {
                var this_node = parent_node.start("Named type", 2);
                defer this_node.end();

                const pstart = self.current - 1;

                var path_node = this_node.start("Path", 0);

                while (self.matches(.dot)) {
                    _ = try self.expect(.dot, &this_node);
                    _ = try self.expect(.identifier, &this_node);
                }
                const pend = self.current;
                path_node.end();

                var args_node = this_node.start("Arguments", 0);
                defer args_node.end();

                if (self.matches(.lt)) {
                    _ = try self.expect(.lt, &this_node);
                    const astart: TypeHandle = if (self.types.items.len > 0) self.types.items.len - 1 else 0;
                    while (!self.matches(.gt) and !self.isAtEnd()) {
                        _ = try self.parseType(&this_node);
                        if (self.matches(.comma)) {
                            _ = self.advance();
                        } else {
                            break;
                        }
                    }
                    _ = try self.expect(.gt, &this_node);
                    const aend: TypeHandle = if (self.types.items.len > 0) self.types.items.len - 1 else 0;
                    break :blk Type{
                        .named = .{
                            .path = .{
                                .start = pstart,
                                .end = pend,
                            },
                            .gens = .{
                                .start = astart,
                                .end = aend,
                            },
                        },
                    };
                } else {
                    break :blk Type{
                        .named = .{
                            .path = .{
                                .start = pstart,
                                .end = pend,
                            },
                            .gens = null,
                        },
                    };
                }
            },
            else => {
                try self.logger.add(self.allocator, .{
                    .start = base_t.start,
                    .end = base_t.end,
                    .file = base_t.file,
                    .kind = .{ .ParseError = .UnexpectedTypeToken },
                    .message = "expected type",
                });
                return error.UnexpectedTypeToken;
            },
        };

        try self.types.append(self.allocator, TypeNode{
            .ty = ty,
            .start = base_t.start,
            .end = base_t.end,
        });

        try_node.end();

        for (mods.items) |mod| {
            switch (mod) {
                .ptr => {
                    ty = Type{
                        .ptr = self.types.items.len - 1,
                    };
                },
                .array => {
                    ty = Type{
                        .array = .{
                            .ty = self.types.items.len - 1,
                            .len = mod.array,
                        },
                    };
                },
                .slice => {
                    ty = Type{
                        .slice = self.types.items.len - 1,
                    };
                },
            }
        }

        try self.types.append(self.allocator, TypeNode{
            .ty = ty,
            .start = base_t.start,
            .end = self.peek().end,
        });
        return self.types.items.len - 1;
    }

    fn parseFn(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var pn = previous.start("Fn", 3);
        defer pn.end();

        const start = (try self.expect(.kw_fn, &pn)).start;

        const namei = self.current;
        _ = try self.expect(.identifier, &pn);

        const generics_start = @max(@as(isize, @intCast(self.types.items.len)) - 1, 0);
        if (self.matches(.lt)) {
            pn.increaseEstimatedTotalItems(1);
            const this = pn.start("Generics", 0);
            defer this.end();

            _ = self.advance();
            while (!self.isAtEnd() and !self.matches(.gt)) {
                pn.increaseEstimatedTotalItems(1);
                _ = try self.parseType(&pn);
            }
            _ = try self.expect(.gt, &pn);
        }
        const generics_end = @max(@as(isize, @as(isize, @intCast(self.types.items.len)) - 1), 0);

        _ = try self.expect(.open_paren, &pn);

        var params = try std.ArrayList(*Node).initCapacity(self.allocator, 4);
        var paramsn = pn.start("Params", 0);
        while (!self.isAtEnd() and !self.matches(.close_paren)) {
            const pname = self.current;
            _ = try self.expect(.identifier, &pn);
            _ = try self.expect(.colon, &pn);

            pn.increaseEstimatedTotalItems(1);
            const pty = try self.parseType(&pn);

            const node = try self.allocator.create(Node);
            node.* = Node{
                .start = self.tokens[pname].start,
                .end = self.types.items[pty].end,
                .file = self.tokens[pname].file,
                .tag = .param,
                .data = .{
                    .param = .{
                        .name = pname,
                        .ty = pty,
                    },
                },
            };
            try params.append(self.allocator, node);
        }
        _ = try self.expect(.close_paren, &paramsn);
        paramsn.end();

        const retty = try self.parseType(&pn);

        _ = try self.expect(.open_body, &pn);
        var blockn = pn.start("Body", 0);
        const body = try self.parseBlock(&blockn);
        const end = try self.expect(.close_body, &pn);
        blockn.end();

        const node = try self.allocator.create(Node);
        node.* = Node{
            .start = start,
            .end = end.end,
            .file = end.file,
            .tag = .fn_stmt,
            .data = .{
                .fn_stmt = .{
                    .name = namei,
                    .body = body,
                    .params = try params.toOwnedSlice(self.allocator),
                    .gens = .{
                        .start = generics_start,
                        .end = generics_end,
                    },
                    .returns = retty,
                },
            },
        };
        return node;
    }

    fn parseLet(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var pn = previous.start("Let", 0);
        defer pn.end();

        const start = try self.expect(.kw_let, &pn);

        var mut = false;
        if (self.matches(.kw_mut)) {
            _ = self.advance();
            mut = true;
        }

        const name = self.current;
        _ = try self.expect(.identifier, &pn);

        var ty: ?TypeHandle = null;
        if (self.matches(.colon)) {
            pn.increaseEstimatedTotalItems(1);
            _ = self.advance();
            ty = try self.parseType(&pn);
        }

        var val: ?*Node = null;
        if (self.matches(.assign)) {
            pn.increaseEstimatedTotalItems(1);
            _ = self.advance();
            val = try self.parseExpr(0, &pn);
        }

        const node = try self.allocator.create(Node);
        node.* = Node{
            .start = start.start,
            .end = self.peek().end,
            .file = start.file,
            .tag = .let_stmt,
            .data = .{
                .let_stmt = .{
                    .name = name,
                    .mut = mut,
                    .ty = ty,
                    .val = val,
                },
            },
        };
        return node;
    }

    fn parseRet(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var ret_node = previous.start("Ret", 1);
        defer ret_node.end();

        const start = self.current;
        _ = try self.expect(.kw_ret, &ret_node);

        var val: ?*Node = undefined;
        if (!self.matches(.semicolon)) {
            val = try self.parseExpr(0, &ret_node);
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
            .start = start,
            .end = self.peek().end,
            .file = self.tokens[start].file,
        };
        return node;
    }

    fn parseIf(self: *Parser, previous: *const std.Progress.Node) anyerror!*Node {
        var if_node = previous.start("If", 2);
        defer if_node.end();

        const start = self.current;
        _ = try self.expect(.kw_if, &if_node);

        const expr = try self.parseExpr(0, &if_node);

        var body: *Node = undefined;
        if (self.matches(.open_body)) {
            const sstart = self.current;
            _ = try self.expect(.open_body, &if_node);
            const block = try self.parseBlock(&if_node);
            _ = try self.expect(.close_body, &if_node);
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
                .file = self.tokens[sstart].file,
            };
        } else {
            _ = try self.expect(.colon, &if_node);
            body = try self.parseStmt(&if_node);
        }

        var else_branch: ?*Node = undefined;
        if (self.matches(.kw_else)) {
            if_node.increaseEstimatedTotalItems(1);
            var else_node = if_node.start("Else branch", 1);
            defer else_node.end();

            _ = try self.expect(.kw_else, &else_node);

            if (self.matches(.open_body)) {
                const estart = self.advance();

                const block = try self.parseBlock(&else_node);
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
                    .file = estart.file,
                };

                _ = try self.expect(.close_body, &else_node);
            } else {
                else_branch = try self.parseStmt(&else_node);
            }
        } else {
            else_branch = null;
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
            .file = self.tokens[start].file,
        };
        return node;
    }

    fn parseFor(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var parent_node = previous.start("For", 1);
        defer parent_node.end();

        const start = self.current;
        _ = try self.expect(.kw_for, &parent_node);

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
                            .body = try self.parseBlock(&parent_node),
                        },
                    },
                    .tag = .block,
                    .start = self.tokens[sstart].start,
                    .end = self.peek().end,
                    .file = self.tokens[sstart].file,
                };
                _ = try self.expect(.close_body, &parent_node);
            } else {
                _ = try self.expect(.colon, &parent_node);
                body = try self.parseStmt(&parent_node);
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
                .file = body.file,
            };
            return node;
        }
        // special case for an expression (while)
        if (!self.matches(.kw_let) and !self.matches(.semicolon)) {
            parent_node.increaseEstimatedTotalItems(1);

            cond = try self.parseExpr(0, &parent_node);

            var body: *Node = undefined;
            if (self.matches(.open_body)) {
                const sstart = self.current;
                _ = self.advance();

                body = try self.allocator.create(Node);
                body.* = Node{
                    .data = .{
                        .block = .{
                            .body = try self.parseBlock(&parent_node),
                        },
                    },
                    .tag = .block,
                    .start = self.tokens[sstart].start,
                    .end = self.peek().end,
                    .file = self.tokens[sstart].file,
                };
            } else {
                _ = try self.expect(.colon, &parent_node);
                body = try self.parseStmt(&parent_node);
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
                .file = self.tokens[start].file,
            };
        }

        parent_node.setEstimatedTotalItems(4);

        if (self.matches(.kw_let)) {
            vari = try self.parseLet(&parent_node);
        }
        _ = try self.expect(.semicolon, &parent_node);

        if (self.matches(.semicolon)) {
            cond = null;
        } else {
            cond = try self.parseExpr(0, &parent_node);
        }
        _ = try self.expect(.semicolon, &parent_node);

        if (self.matches(.colon) or self.matches(.open_body)) {
            incr = null;
        } else {
            incr = try self.parseExpr(0, &parent_node);
        }

        var body: *Node = undefined;
        if (self.matches(.open_body)) {
            const sstart = self.current;
            _ = try self.expect(.open_body, &parent_node);
            body = try self.allocator.create(Node);
            body.* = .{
                .data = .{
                    .block = .{
                        .body = try self.parseBlock(&parent_node),
                    },
                },
                .tag = .block,
                .start = self.tokens[sstart].start,
                .end = self.peek().end,
                .file = self.tokens[sstart].file,
            };
            _ = try self.expect(.close_body, &parent_node);
        } else {
            _ = try self.expect(.colon, &parent_node);
            body = try self.parseStmt(&parent_node);
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
            .file = body.file,
        };
        return node;
    }

    fn parsePub(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var this_node = previous.start("Pub", 1);
        defer this_node.end();

        const start = self.current;
        _ = try self.expect(.kw_pub, &this_node);

        const old_root = self.root_node;
        self.root_node = &this_node;

        const mem = try self.parseTop();

        self.root_node = old_root;

        const node = try self.allocator.create(Node);
        node.* = Node{
            .start = self.tokens[start].start,
            .end = mem.end,
            .file = mem.file,
            .tag = .pub_stmt,
            .data = .{
                .pub_stmt = .{
                    .stmt = mem,
                },
            },
        };
        return node;
    }
};
