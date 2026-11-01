const std = @import("std");

const lex = @import("lex.zig");
const Token = lex.Token;

const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;

const Error = err.Error;
const ErrorType = err.ErrorType;

const FileTable = @import("file_table.zig").FileTable;

pub const Tag = enum {
    integer,
    string,
    _false,
    _true,
    _null,
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
    unary_op_at,
    unary_op_neg,
    unary_op_not,
    unary_op_decr, // --
    unary_op_incr, // ++
    assign,
    assign_add,
    assign_sub,
    assign_mul,
    assign_div,
    call,
    struct_init,
    field_init,
    block,
    var_stmt,
    fn_stmt,
    param,
    ret_stmt,
    if_stmt,
    for_stmt,
    struct_stmt,
    pub_stmt,
    //class_stmt,
    cast,
};
// No, i do not use DOD.
pub const Data = union {
    token: usize,
    builtin: struct {
        name: usize,
        args: []*Node,
    },
    property_access: struct {
        target: *Node,
        name: usize,
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
        name: usize,
        val: *Node,
    },
    block: struct {
        body: []*Node,
    },
    var_stmt: struct {
        ty: TypeID,
        mut: bool,
        name: usize,
        val: ?*Node,
    },
    fn_stmt: struct {
        name: usize,
        params: ?[]*Node,
        body: []*Node,
        returns: TypeID,
    },
    param: struct {
        name: usize,
        ty: TypeID,
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
        name: usize,
        fields: []*Node,
    },
    pub_stmt: struct {
        stmt: *Node,
    },
    cast: struct {
        expr: *Node,
        ty: TypeID,
    },
};

pub const TypeID = usize;

pub const Field = struct {
    name: []const u8,
    ty: TypeID,
    mut: bool,
};

pub const Type = union(enum) {
    void,
    nullt,
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
        returns: TypeID,
        params_start: usize,
        params_end: usize,
    },
    ptr: TypeID,
    array: struct {
        ty: TypeID,
        len: *Node,
    },
    slice: TypeID,
    strct: struct {
        name: []const u8,
        fields: []Field,
    },
    named: struct { // TODO remove this
        path: struct { // skip the dots later on
            start: usize,
            end: usize,
        },
        args: ?struct {
            start: TypeID,
            end: usize, // easeier
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
    file: u8,
};

pub const ParseError = error{
    UnexpectedToken,
    ExpectedStatement,
    ExpectedTopLevelStatement,
    ExpectedVariableStmt,
    ExpectedExpression,
    ExpectedTypeExpression,
    UnexpectedKwInStruct,
    UnexpectedDefaultValue,
    MutFunction,
};

pub const Parser = struct {
    file_table: *FileTable,
    tokens: []Token,
    current: usize = 0,

    allocator: std.mem.Allocator,
    io: std.Io,

    logger: ErrorLogger,
    root_node: std.Progress.Node,

    types: std.ArrayList(TypeNode),

    slow: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, tokens: []Token, file_table: *FileTable, progress: std.Progress.Node, slow: bool) Parser {
        return Parser{
            .file_table = file_table,
            .tokens = tokens,
            .allocator = allocator,
            .io = io,
            .logger = .init(file_table),
            .types = std.ArrayList(TypeNode).initCapacity(allocator, tokens.len / 50) catch std.ArrayList(TypeNode).empty,
            .root_node = progress,
            .slow = slow,
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
            .kind = .{ .ParseError = ParseError.UnexpectedToken },
        });
        self.current += 1;
        const newname = try std.fmt.allocPrint(self.allocator, "\x1b[31m{s}\x1b[0m", .{node.getName()});
        node.setName(newname);

        return ParseError.UnexpectedToken;
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
            .kw_mut => "mut",
            .kw_ret => "ret",
            .kw_if => "if",
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
        if (!self.isAtEnd()) _ = self.advance();
        while (!self.isAtEnd()) {
            switch (self.peek().kind) {
                .semicolon => {
                    _ = self.advance();
                    return;
                },
                .close_body,
                .kw_ret,
                .kw_struct,
                .kw_if,
                .kw_for,
                .kw_pub,
                => return,
                else => _ = self.advance(),
            }
        }
    }

    pub fn run(self: *Parser) ![]*Node {
        var nodes = try std.ArrayList(*Node).initCapacity(self.allocator, self.tokens.len / 6);
        while (!self.isAtEnd()) {
            const top = self.parseTop() catch {
                self.syncErr();
                continue;
            };
            try nodes.append(self.allocator, top);
            self.root_node.setEstimatedTotalItems(@max(self.tokens.len / 25, nodes.items.len));
        }
        if (self.logger.dump(self.allocator)) {
            return error.parse;
        }
        const array = try nodes.toOwnedSlice(self.allocator);
        return array;
    }

    fn parseBlock(self: *Parser, previous: *std.Progress.Node) ![]*Node {
        var parent_node = previous.start("Body", 0);
        defer parent_node.end();

        var body = try std.ArrayList(*Node).initCapacity(self.allocator, 8);
        while (!self.isAtEnd()) {
            if (self.peek().kind == .close_body) {
                break;
            }
            parent_node.increaseEstimatedTotalItems(1);
            try body.append(self.allocator, try self.parseStmt(&parent_node));
        }
        return body.toOwnedSlice(self.allocator);
    }

    fn parseTop(self: *Parser) anyerror!*Node {
        const msg = try std.fmt.allocPrint(self.allocator, "Top-level statement (token {})", .{self.current});
        const top_node = self.root_node.start(msg, 1);
        defer top_node.end();

        try self.sleepIfSlow(45);
        switch (self.peek().kind) {
            .kw_struct => return try self.parseStruct(&top_node),
            .kw_pub => return try self.parsePub(&top_node),
            else => {
                if (try self.tryParseVarOrFn(&top_node)) |res| {
                    return res;
                }
            },
        }
        const found_top = self.peek();
        try self.logger.add(self.allocator, .{
            .kind = .{ .ParseError = ParseError.ExpectedTopLevelStatement },
            .start = found_top.start,
            .end = self.next().end,
            .file = found_top.file,
            .message = try self.allocator.print(
                "expected a top-level statement (function, class or global variable), found '{s}' ({s})",
                .{
                    self.file_table.spanStr(found_top.file, found_top.start, found_top.end),
                    @tagName(found_top.kind),
                },
            ),
        });
        return ParseError.ExpectedTopLevelStatement;
    }

    fn parseStmt(self: *Parser, previous: *std.Progress.Node) anyerror!*Node {
        var parent_node = previous.start("Statement", 1);
        defer parent_node.end();
        try self.sleepIfSlow(75);
        switch (self.peek().kind) {
            .kw_ret => {
                const stmt = try self.parseRet(&parent_node);
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
                if (try self.tryParseVar(&parent_node)) |vari| {
                    _ = try self.expect(.semicolon, &parent_node);
                    return vari;
                }
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
            => return 1,
            .equal,
            .not_equal,
            .gt,
            .lt,
            .gt_eq,
            .lt_eq,
            => return 4,
            .add,
            .sub,
            => return 5,
            .star,
            .div,
            => return 6,
            .dot,
            .open_paren,
            .open_bracket,
            .open_body,
            => return 7,
            .increment,
            .decrement,
            => return 8,
            .kw_as => return 3,
            else => return 0,
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
                    .kw_false => ._false,
                    .kw_true => ._true,
                    .kw_null => ._null,
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
                    .file = close_p.file, // random choice
                };
            },
            .open_paren => {
                const expr = try self.parseExpr(0, &parent_node);
                _ = try self.expect(.close_paren, &parent_node);
                break :blk expr.*;
            },
            .not, // unary op
            .sub,
            //.increment,
            //.decrement,
            => {
                const expr = try self.parseExpr(0, &parent_node);
                const tag: Tag = switch (lhs_t.kind) {
                    .not => .unary_op_not,
                    .sub => .unary_op_neg,
                    //.increment => .unary_op_incr,
                    //.decrement => .unary_op_decr,
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
                return ParseError.ExpectedExpression;
            },
        };
        try self.sleepIfSlow(40);
        while (!self.isAtEnd()) {
            const nextt = self.peek();
            const importance = self.getImportance(nextt.kind);
            if (importance == 0 or importance <= min)
                break;

            switch (nextt.kind) {
                .kw_as => {
                    _ = self.advance();
                    const ty = try self.tryParseType(&parent_node);
                    if (ty) |ty_id| {
                        const old = lhs;
                        lhs = try self.allocator.create(Node);
                        lhs.* = Node{
                            .data = .{
                                .cast = .{
                                    .expr = old,
                                    .ty = ty_id,
                                },
                            },
                            .tag = .cast,
                            .start = old.start,
                            .end = self.types.items[ty_id].end,
                            .file = old.file,
                        };
                    } else {
                        return ParseError.ExpectedTypeExpression;
                    }
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
                    var args = std.ArrayList(*Node).empty;
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
                    parent_node.setName("Struct initialization");

                    const start = self.advance();
                    var fields = std.ArrayList(*Node).empty;
                    while (!self.isAtEnd() and !self.matches(.close_body)) {
                        parent_node.increaseEstimatedTotalItems(1);

                        const st = try self.expect(.dot, &parent_node);
                        const name = self.current;
                        _ = try self.expect(.identifier, &parent_node);

                        _ = try self.expect(.assign, &parent_node);
                        const v = try self.parseExpr(0, &parent_node);
                        _ = try self.expect(.semicolon, &parent_node);

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
                        else => unreachable,
                    };

                    const rhs = try self.parseExpr(min, &parent_node);

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
        try self.sleepIfSlow(80);
        return lhs;
    }

    const ModTag = union(enum) {
        ptr,
        array: *Node,
        slice,
    };

    fn tryParseType(self: *Parser, previous: *const std.Progress.Node) anyerror!?TypeID {
        var parent_node = previous.start("Trying to parse type", 1);
        defer parent_node.end();

        const start = self.current;

        var mods = std.ArrayList(ModTag).empty;
        defer mods.deinit(self.allocator);

        var try_node = parent_node.start("Collecting type modifiers", 0);
        errdefer try_node.end();

        while (!self.isAtEnd()) {
            if (self.matches(.star)) {
                try_node.increaseEstimatedTotalItems(1);
                var node = try_node.start("Pointer modifier", 0);
                errdefer node.end();
                try self.sleepIfSlow(20);

                _ = self.advance();
                try mods.append(self.allocator, .ptr);
                node.end();
            } else if (self.matches(.open_bracket)) {
                try_node.increaseEstimatedTotalItems(1);
                var node = try_node.start("Array modifier", 0);
                defer node.end();
                try self.sleepIfSlow(20);

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
        try_node.end();

        try self.sleepIfSlow(50);
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
            .arrow => { // function ->ret_type(args)
                var this_node = parent_node.start("Function type", 2);
                defer this_node.end();

                const return_ty = try self.tryParseType(&this_node);
                if (return_ty == null) {
                    self.current = start;
                    return null;
                }

                const params_start = self.types.items.len;
                // here also no forced parentheses
                if (self.matches(.open_paren)) {
                    _ = try self.expect(.open_paren, &this_node);
                    while (!self.matches(.close_paren)) {
                        if (try self.tryParseType(&this_node) != null)
                            continue;
                        self.current = start;
                        return null;
                    }
                    _ = try self.expect(.close_paren, &this_node);
                }
                const params_end = self.types.items.len - 1;
                break :blk Type{
                    .func = .{
                        .returns = return_ty.?,
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
                try self.sleepIfSlow(60);
                path_node.end();

                var args_node = this_node.start("Arguments", 0);
                defer args_node.end();

                if (self.matches(.open_paren)) {
                    _ = try self.expect(.open_paren, &this_node);
                    const astart = if (self.types.items.len > 0) self.types.items.len - 1 else 0;
                    while (!self.matches(.close_paren)) {
                        if (try self.tryParseType(&this_node)) |ty| {
                            _ = ty;
                        } else {
                            return null;
                        }
                        if (self.peek().kind != .close_paren) {
                            _ = try self.expect(.comma, &this_node);
                        }
                    }
                    _ = try self.expect(.close_paren, &this_node);
                    const aend = self.types.items.len - 1;
                    break :blk Type{
                        .named = .{
                            .path = .{
                                .start = pstart,
                                .end = pend,
                            },
                            .args = .{
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
                            .args = null,
                        },
                    };
                }
            },
            else => {
                self.current = start;
                return null;
            },
        };

        try self.types.append(self.allocator, TypeNode{
            .ty = ty,
            .start = base_t.start,
            .end = base_t.end,
        });

        try self.sleepIfSlow(25);

        try self.sleepIfSlow(15);
        try_node.end();

        for (mods.items) |mod| {
            switch (mod) {
                .ptr => {
                    ty = Type{
                        .ptr = self.types.items.len,
                    };
                },
                .array => {
                    ty = Type{
                        .array = .{
                            .ty = self.types.items.len,
                            .len = mod.array,
                        },
                    };
                },
                .slice => {
                    ty = Type{
                        .slice = self.types.items.len,
                    };
                },
            }
        }

        try self.types.append(self.allocator, TypeNode{
            .ty = ty,
            .start = base_t.start,
            .end = self.peek().end,
        });
        try self.sleepIfSlow(45);
        return self.types.items.len - 1;
    }

    fn tryParseVar(self: *Parser, previous: *const std.Progress.Node) !?*Node {
        var parent_node = previous.start("Try variable", 2);
        defer parent_node.end();

        const start = self.current;
        const ty = try self.tryParseType(&parent_node);
        if (ty == null) {
            self.current = start;
            return null;
        }
        try self.sleepIfSlow(25);
        if (self.peek().kind == .identifier and
            (self.next().kind == .semicolon or self.next().kind == .assign))
        {
            parent_node.setName("Const variable");

            const name = self.current;
            _ = self.advance();

            if (self.peek().kind == .semicolon) {
                const node = try self.allocator.create(Node);
                node.* = Node{
                    .data = .{
                        .var_stmt = .{
                            .name = name,
                            .mut = false,
                            .ty = ty.?,
                            .val = null,
                        },
                    },
                    .tag = .var_stmt,
                    .start = self.types.items[ty.?].start,
                    .end = self.peek().end,
                    .file = self.tokens[name].file,
                };

                return node;
            }
            try self.sleepIfSlow(50);
            _ = try self.expect(.assign, &parent_node);
            const val = try self.parseExpr(0, &parent_node);

            const node = try self.allocator.create(Node);
            node.* = Node{
                .data = .{
                    .var_stmt = .{
                        .name = name,
                        .mut = false,
                        .ty = ty.?,
                        .val = val,
                    },
                },
                .tag = .var_stmt,
                .start = self.types.items[ty.?].start,
                .end = self.peek().end,
                .file = self.tokens[name].file,
            };
            try self.sleepIfSlow(40);
            return node;
            // good enough
        } else if (self.peek().kind == .kw_mut and self.next().kind == .identifier) {
            parent_node.setName("Mut variable");

            _ = self.advance();
            const name = self.current + 1;
            _ = self.advance();

            const node = try self.allocator.create(Node);
            if (self.peek().kind == .semicolon) {
                node.* = .{
                    .data = .{
                        .var_stmt = .{
                            .ty = ty.?,
                            .mut = true,
                            .name = name,
                            .val = null,
                        },
                    },
                    .tag = .var_stmt,
                    .start = self.types.items[ty.?].start,
                    .end = self.peek().end,
                    .file = self.tokens[name].file,
                };
                return node;
            }
            _ = try self.expect(.assign, &parent_node);
            const val = try self.parseExpr(0, &parent_node);

            node.* = .{
                .data = .{
                    .var_stmt = .{
                        .name = name,
                        .mut = true,
                        .ty = ty.?,
                        .val = val,
                    },
                },
                .tag = .var_stmt,
                .start = self.types.items[ty.?].start,
                .end = self.peek().end,
                .file = self.tokens[name].file,
            };
            return node;
        }
        self.current = start;
        return null;
    }

    fn tryParseVarOrFn(self: *Parser, previous: *const std.Progress.Node) !?*Node {
        var parent_node = previous.start("Try variable or function", 1);
        defer parent_node.end();

        try self.sleepIfSlow(50);

        const start = self.current;
        const ty = try self.tryParseType(&parent_node);
        if (ty == null) {
            parent_node.end();
            self.current = start;
            return null;
        }

        const idstart = self.peek();

        var mut = false;
        var mut_t: usize = undefined;
        if (self.peek().kind == .kw_mut) {
            mut = true;
            mut_t = self.current;
            _ = self.advance();
        }

        if (self.peek().kind == .identifier) {
            try self.sleepIfSlow(80);
            switch (self.next().kind) {
                .open_paren => { // fn with params
                    if (mut) {
                        try self.logger.add(self.allocator, .{
                            .start = self.tokens[mut_t].start,
                            .end = self.tokens[mut_t].end,
                            .file = self.tokens[mut_t].file,
                            .message = "function cannot be 'mut'",
                            .kind = .{ .ParseError = ParseError.MutFunction },
                        });
                        return ParseError.MutFunction;
                    }

                    parent_node.setName("Function");
                    parent_node.increaseEstimatedTotalItems(2);

                    const name = self.current;
                    _ = try self.expect(.identifier, &parent_node);
                    _ = try self.expect(.open_paren, &parent_node);

                    var params = try std.ArrayList(*Node).initCapacity(self.allocator, 3);

                    var params_node = parent_node.start("Parsing parameters", 0);
                    errdefer params_node.end();

                    while (!self.isAtEnd() and !self.matches(.close_paren)) {
                        const pstart = self.current;
                        if (try self.tryParseType(&params_node)) |typ| {
                            const pname = self.current;
                            _ = try self.expect(.identifier, &params_node);

                            const node = try self.allocator.create(Node);
                            node.* = Node{
                                .start = self.tokens[pstart].start,
                                .end = self.peek().end,
                                .file = self.peek().file,
                                .data = .{
                                    .param = .{
                                        .name = pname,
                                        .ty = typ,
                                    },
                                },
                                .tag = .param,
                            };
                            try params.append(self.allocator, node);

                            if (self.peek().kind == .comma) {
                                _ = try self.expect(.comma, &params_node);
                            } else {
                                break;
                            }
                        } else {
                            const found_ty = self.peek();
                            try self.logger.add(self.allocator, .{
                                .kind = .{ .ParseError = ParseError.ExpectedTypeExpression },
                                .start = found_ty.start,
                                .end = self.next().end, // cant get any better error highlighting...
                                .file = found_ty.file,
                                .message = try self.allocator.print(
                                    "expected type of parameter, found '{s}' ({s})",
                                    .{
                                        self.file_table.spanStr(found_ty.file, found_ty.start, found_ty.end),
                                        @tagName(found_ty.kind),
                                    },
                                ),
                                .note = .{
                                    .message = "function declared here",
                                    .start = idstart.start,
                                    .end = idstart.end,
                                    .file = idstart.file,
                                },
                            });
                            self.current = start;
                            return ParseError.ExpectedTypeExpression;
                        }
                    }
                    _ = try self.expect(.close_paren, &parent_node);
                    _ = try self.expect(.open_body, &parent_node);

                    params_node.end();

                    const body = try self.parseBlock(&parent_node);
                    _ = try self.expect(.close_body, &parent_node);

                    const node = try self.allocator.create(Node);
                    node.* = Node{
                        .start = start,
                        .end = self.tokens[start].start,
                        .file = self.tokens[start].file,
                        .data = .{
                            .fn_stmt = .{
                                .name = name,
                                .body = body,
                                .params = params.items,
                                .returns = ty.?,
                            },
                        },
                        .tag = .fn_stmt,
                    };
                    return node;
                },
                .open_body => { // fn without params
                    if (mut) {
                        try self.logger.add(self.allocator, .{
                            .start = self.tokens[mut_t].start,
                            .end = self.tokens[mut_t].end,
                            .file = self.tokens[mut_t].file,
                            .message = "functions cannot be 'mut'",
                            .kind = .{ .ParseError = ParseError.MutFunction },
                        });
                        return ParseError.MutFunction;
                    }

                    parent_node.setName("Function");
                    parent_node.increaseEstimatedTotalItems(1);

                    const name = self.current;
                    _ = try self.expect(.identifier, &parent_node);
                    _ = try self.expect(.open_body, &parent_node);

                    const body = try self.parseBlock(&parent_node);
                    _ = try self.expect(.close_body, &parent_node);

                    const node = try self.allocator.create(Node);
                    node.* = .{
                        .start = self.tokens[start].start,
                        .end = self.peek().end,
                        .file = self.tokens[name].file,
                        .data = .{
                            .fn_stmt = .{
                                .name = name,
                                .body = body,
                                .params = null,
                                .returns = ty.?,
                            },
                        },
                        .tag = .fn_stmt,
                    };
                    return node;
                },
                .assign => { // variable
                    parent_node.setName("Variable");
                    parent_node.increaseEstimatedTotalItems(1);

                    const name = self.current;
                    _ = try self.expect(.identifier, &parent_node);
                    _ = try self.expect(.assign, &parent_node);
                    const expr = try self.parseExpr(0, &parent_node);

                    const node = try self.allocator.create(Node);
                    node.* = .{
                        .start = self.tokens[start].start,
                        .end = self.peek().end,
                        .file = expr.file,
                        .data = .{
                            .var_stmt = .{
                                .ty = ty.?,
                                .mut = mut,
                                .name = name,
                                .val = expr,
                            },
                        },
                        .tag = .var_stmt,
                    };
                    return node;
                },
                else => {},
            }
        }
        self.current = start;
        return null;
    }

    fn parseRet(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var ret_node = previous.start("Ret", 1);
        defer ret_node.end();

        const start = self.current;
        _ = try self.expect(.kw_ret, &ret_node);

        var val: ?*Node = undefined; // seg fault if i use null?
        if (!self.matches(.semicolon)) {
            val = try self.parseExpr(0, &ret_node);
        } else {
            val = null;
        }

        try self.sleepIfSlow(80);
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

        _ = try self.expect(.open_paren, &if_node);
        const expr = try self.parseExpr(0, &if_node);
        _ = try self.expect(.close_paren, &if_node);
        try self.sleepIfSlow(50);

        var body: *Node = undefined;
        if (self.matches(.open_body)) {
            const sstart = self.current;
            _ = try self.expect(.open_body, &if_node);
            body = try self.allocator.create(Node);
            body.* = .{
                .data = .{
                    .block = .{
                        .body = try self.parseBlock(&if_node),
                    },
                },
                .tag = .block,
                .start = self.tokens[sstart].start,
                .end = self.peek().end,
                .file = self.tokens[sstart].file,
            };
            _ = try self.expect(.close_body, &if_node);
        } else {
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

        //_ = try self.expect(.open_paren, &parent_node);
        var vari: ?*Node = undefined;
        var cond: ?*Node = undefined;
        var incr: ?*Node = undefined;

        const node = try self.allocator.create(Node);
        //errdefer self.allocator.free(node);
        // special case for ()
        if (self.matches(.open_paren) and self.next().kind == .close_paren) {
            _ = try self.expect(.open_paren, &parent_node);
            _ = try self.expect(.close_paren, &parent_node);
            vari = null;
            cond = null;
            incr = null;

            if (self.matches(.open_body)) {
                const sstart = self.current;
                _ = try self.expect(.open_body, &parent_node);
                const body = try self.allocator.create(Node);
                body.* = .{
                    .data = .{
                        .block = .{
                            .body = try self.parseBlock(&parent_node),
                        },
                    },
                    .tag = .block,
                    .start = self.tokens[sstart].start,
                    .end = self.peek().end,
                    .file = body.file,
                };
                _ = try self.expect(.close_body, &parent_node);
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
            } else {
                const body = try self.parseStmt(&parent_node);
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
        }
        // another special case for no parenthes at all (does the exact same)
        if (!self.matches(.open_paren)) {
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
                    .file = body.file,
                };
                _ = try self.expect(.close_body, &parent_node);
            } else {
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
        _ = try self.expect(.open_paren, &parent_node);

        parent_node.setEstimatedTotalItems(4);

        const errstart1 = self.peek().start;
        if (self.matches(.semicolon)) {
            vari = null;
        } else if (try self.tryParseVar(&parent_node)) |varib| {
            vari = varib;
        } else {
            const found_var = self.peek();
            try self.logger.add(self.allocator, .{
                .kind = .{ .ParseError = ParseError.ExpectedVariableStmt },
                .start = errstart1,
                .end = self.next().end,
                .file = self.peek().file,
                .message = try self.allocator.print(
                    "expected a variable declaration or ';' to start the 'for' header, found '{s}' ({s})",
                    .{
                        self.file_table.spanStr(found_var.file, found_var.start, found_var.end),
                        @tagName(found_var.kind),
                    },
                ),
            });
            return ParseError.ExpectedVariableStmt;
        }
        _ = try self.expect(.semicolon, &parent_node);

        if (self.matches(.semicolon)) {
            cond = null;
        } else {
            cond = try self.parseExpr(0, &parent_node);
        }
        _ = try self.expect(.semicolon, &parent_node);

        try self.sleepIfSlow(50);
        if (self.matches(.close_paren)) {
            incr = null;
        } else {
            incr = try self.parseExpr(0, &parent_node);
        }
        _ = try self.expect(.close_paren, &parent_node);

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
            body = try self.parseStmt(&parent_node);
        }
        try self.sleepIfSlow(50);
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

    //fn parseClass(self: *Parser, previous: *const std.Progress.Node) !*Node {
    //    var parent_node = previous.start("Parsing class", 1);
    //    defer parent_node.end();
    //
    //    const start = self.current;
    //    _ = try self.expect(.kw_class, &parent_node);
    //
    //    const name = self.current;
    //    _ = try self.expect(.identifier, &parent_node);
    //
    // parameters are generics,
    // i call them that because of the parentheses
    //    var params: ?[]usize = undefined;
    //    if (self.matches(.open_paren)) {
    //        parent_node.increaseEstimatedTotalItems(1);
    //        var this_node = parent_node.start("Parsing parameters", 0);
    //        defer this_node.end();
    //        _ = try self.expect(.open_paren, &this_node);

    //       var paramsl = std.ArrayList(usize).empty;
    //        while (!self.isAtEnd() and !self.matches(.close_paren)) {
    //            try paramsl.append(self.allocator, self.current);
    //            _ = try self.expect(.identifier, &this_node);
    //
    //            if (self.matches(.comma)) {
    //                _ = try self.expect(.comma, &this_node);
    //            } else {
    //                break;
    //            }
    //};
    //       _ = try self.expect(.close_paren, &this_node);
    //       params = try paramsl.toOwnedSlice(self.allocator);
    //    } else {
    //        params = null;
    //    }
    //    var parents: ?[]usize = undefined;
    //   if (self.matches(.colon)) {
    //        parent_node.increaseEstimatedTotalItems(1);
    //        var this_node = parent_node.start("Parsing parents", 0);
    //       _ = try self.expect(.colon, &this_node);
    //
    //       var pars = std.ArrayList(usize).empty;
    //       while (!self.isAtEnd()) {
    //            try pars.append(self.allocator, self.current);
    //            _ = try self.expect(.identifier, &this_node);
    //            if (self.matches(.comma)) {
    //                _ = try self.expect(.comma, &this_node);
    //            } else {
    //                break;
    //            }
    //        }
    //         parents = try pars.toOwnedSlice(self.allocator);
    //    } else {
    //        parents = null;
    //     }

    //     const open = try self.expect(.open_body, &parent_node);
    //     var body_node = parent_node.start("Parsing body", 0);
    //     defer body_node.end();

    //     var body = std.ArrayList(*Node).empty;
    //     while (!self.isAtEnd() and !self.matches(.close_body)) {
    //         body_node.increaseEstimatedTotalItems(1);
    //         try self.sleepIfSlow(50);

    //         if (self.matches(.kw_pub)) {
    //             const mem = try self.parsePub(&body_node);
    //             if (mem.data.pub_stmt.stmt.tag == .var_stmt)
    //                 _ = try self.expect(.semicolon, &body_node);
    //
    //            try body.append(self.allocator, mem);
    //        } else if (try self.tryParseVarOrFn(&body_node)) |mem| {
    //            try body.append(self.allocator, mem);
    //            if (mem.tag == .var_stmt)
    //                _ = try self.expect(.semicolon, &body_node);
    //        } else if (try self.tryParseVar(&body_node)) |mem| {
    //            try body.append(self.allocator, mem);
    //            _ = try self.expect(.semicolon, &body_node);
    //        } else {
    //            const found_mem = self.peek();
    //            try self.logger.add(self.allocator, .{
    //                .kind = .{ .ParseError = ParseError.UnexpectedKwInClassBody },
    //                .start = found_mem.start,
    //                .end = found_mem.end,
    //                .note = .{ .message = "class body opened here", .start = open.start, .end = open.end },
    //                .message = try std.fmt.allocPrint(self.allocator, "expected 'pub', a field or a method in class body, found '{s}' ({s})", .{ self.tokenText(found_mem), @tagName(found_mem.kind) }),
    //            });
    //            return ParseError.UnexpectedKwInClassBody;
    //        }
    //    }
    //    _ = try self.expect(.close_body, &parent_node);

    //    const node = try self.allocator.create(Node);
    //    node.* = Node{
    //        .data = .{
    //            .class_stmt = .{
    //                .name = name,
    //                .params = params,
    //                .parents = parents,
    //                .fields = try body.toOwnedSlice(self.allocator),
    //            },
    //        },
    //        .tag = .class_stmt,
    //        .start = self.tokens[start].start,
    //        .end = self.peek().end,
    //    };
    //    return node;
    //}

    fn parseStruct(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var this_node = previous.start("Struct", 0);
        defer this_node.end();

        const start = self.current;
        _ = try self.expect(.kw_struct, &this_node);

        const name = self.current;
        _ = try self.expect(.identifier, &this_node);

        _ = try self.expect(.open_body, &this_node);

        var fields = std.ArrayList(*Node).empty;
        while (!self.isAtEnd() and !self.matches(.close_body)) {
            this_node.increaseEstimatedTotalItems(1);

            if (self.peek().kind == .kw_mut) {}

            if (try self.tryParseVar(&this_node)) |n| {
                if (n.data.var_stmt.val != null) {
                    try self.logger.add(self.allocator, .{
                        .start = n.start,
                        .end = n.end,
                        .file = n.file,
                        .message = "structs cannot have default values",
                        .kind = .{ .ParseError = ParseError.UnexpectedDefaultValue },
                    });
                    return ParseError.UnexpectedDefaultValue;
                }
                try fields.append(self.allocator, n);
            } else {
                try self.logger.add(self.allocator, .{
                    .start = self.peek().start,
                    .end = self.peek().end,
                    .file = self.peek().file,
                    .message = "expected field in struct body",
                    .kind = .{ .ParseError = ParseError.UnexpectedKwInStruct },
                });
                return ParseError.UnexpectedKwInStruct;
            }
            _ = try self.expect(.semicolon, &this_node);
        }
        _ = try self.expect(.close_body, &this_node);

        const node = try self.allocator.create(Node);
        node.* = .{
            .data = .{
                .struct_stmt = .{
                    .name = name,
                    .fields = try fields.toOwnedSlice(self.allocator),
                },
            },
            .tag = .struct_stmt,
            .start = self.tokens[start].start,
            .end = self.peek().end,
            .file = self.tokens[self.current - 1].file,
        };
        return node;
    }

    fn parsePub(self: *Parser, previous: *const std.Progress.Node) !*Node {
        var this_node = previous.start("Pub", 1);
        defer this_node.end();

        const start = self.current;
        _ = try self.expect(.kw_pub, &this_node);

        if (try self.tryParseVar(&this_node)) |mem| {
            const node = try self.allocator.create(Node);
            node.* = Node{
                .data = .{
                    .pub_stmt = .{
                        .stmt = mem,
                    },
                },
                .tag = .pub_stmt,
                .start = self.tokens[start].start,
                .end = self.peek().end,
                .file = self.tokens[start].file, // should be fine assuming the it isnt spread on multiple
            };
            try self.sleepIfSlow(50);
            return node;
        } else if (try self.tryParseVarOrFn(&this_node)) |mem| {
            const node = try self.allocator.create(Node);
            node.* = Node{
                .data = .{
                    .pub_stmt = .{
                        .stmt = mem,
                    },
                },
                .tag = .pub_stmt,
                .start = self.tokens[start].start,
                .end = self.peek().end,
                .file = self.tokens[start].file,
            };
            try self.sleepIfSlow(50);
            return node;
        } else if (self.peek().kind == .kw_struct) {
            const n = try self.allocator.create(Node);
            n.* = .{
                .data = .{
                    .pub_stmt = .{
                        .stmt = try self.parseStruct(&this_node),
                    },
                },
                .tag = .pub_stmt,
                .start = self.tokens[start].start,
                .end = self.peek().end,
                .file = self.tokens[start].file,
            };
            return n;
        }
        const found_pub = self.peek();
        try self.logger.add(self.allocator, .{
            .kind = .{ .ParseError = ParseError.ExpectedStatement },
            .start = found_pub.start,
            .end = found_pub.end,
            .file = found_pub.file,
            .message = try self.allocator.print(
                "expected a variable, function or 'struct' after 'pub', found '{s}' ({s})",
                .{
                    self.file_table.spanStr(found_pub.file, found_pub.start, found_pub.end),
                    @tagName(found_pub.kind),
                },
            ),
        });
        return ParseError.ExpectedStatement;
    }

    fn sleepIfSlow(self: *Parser, milliseconds: u32) !void {
        if (self.slow) try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(milliseconds * 2), .awake);
    }
};
