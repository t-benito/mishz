const std = @import("std");

const parse = @import("parse.zig");
const Node = parse.Node;
const Data = parse.Data;
const Tag = parse.Tag;
const Type = parse.Type;
const TypeNode = parse.TypeNode;
const TypeHandle = parse.TypeHandle;

const lex = @import("lex.zig");
const Token = lex.Token;
const TokenHandle = lex.TokenHandle;

const err = @import("error.zig");
const Error = err.Error;
const Note = err.Note;

const ft = @import("file_table.zig");
const FileTable = ft.FileTable;
const FileHandle = ft.FileHandle;

const Symbol = struct {
    data: Symbol.Data,
    kind: Kind,
    start: usize,
    end: usize,
    file: FileHandle,
    public: bool = true,

    pub const Kind = enum {
        vari,
        func,
        strct,
        param,
    };
    pub const Data = union {
        vari: TypeHandle,
        func: struct {
            params: []TypeHandle,
            returns: TypeHandle,
        },
        param: TypeHandle,
    };
};

const ScopeMap = struct {
    maps: std.ArrayList(std.StringHashMap(Symbol)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ScopeMap {
        return ScopeMap{
            .maps = std.ArrayList(std.StringHashMap(Symbol)).empty,
            .allocator = allocator,
        };
    }

    /// exit the current scope
    pub fn exit(self: *ScopeMap) void {
        var popped = self.maps.pop();
        if (popped) |_| {
            popped.?.deinit();
        }
    }

    /// enter a new scope
    pub fn enter(self: *ScopeMap) !void {
        try self.maps.append(self.allocator, std.StringHashMap(Symbol).init(self.allocator));
    }

    /// defines a symbol in current scope,
    /// enters new scope if no scope has yet been entered
    pub fn define(self: *ScopeMap, name: []const u8, symbol: Symbol, logger: *err.ErrorLogger) !void {
        if (self.maps.last() == null) {
            try self.enter();
        }

        if (self.lookup(name)) |old| {
            try logger.add(self.allocator, .{
                .start = symbol.start,
                .end = symbol.end,
                .file = symbol.file,
                .kind = .{ .TypeError = TypeError.NameAlreadyDefined },
                .message = "symbol already defined",
                .note = .{
                    .start = old.start,
                    .end = old.end,
                    .file = old.file,
                    .message = "first defined here",
                },
            });
            return;
        }

        var l = self.maps.lastPtr().?;
        try l.put(name, symbol);
    }

    pub fn lookup(self: *ScopeMap, name: []const u8) ?*const Symbol {
        if (self.maps.items.len == 0)
            return null;
        var i: i32 = @intCast(self.maps.items.len - 1);
        while (i >= 0) : (i -= 1) {
            if (self.maps.items[@intCast(i)].getPtr(name)) |sym| {
                return sym;
            }
        }
        return null;
    }
};

pub const TypeError = enum(u8) {
    IncompatibleTypes = 0,
    UnknownType = 1,
    UnexpectedType = 2,
    CannotIndexType = 3,
    NonFunctionCall = 4,
    NotPublic = 5,
    UndeclaredIdentifier = 6,
    TypeMismatch = 7,
    NotAMember = 8,
    IndexByNonInt = 9,
    NameAlreadyDefined = 10,
    ExpectedStatement = 11,
    MismatchedVariableType = 12,
    UnknownSliceProperty = 13,
    MustBeInit = 14,
};

pub const Checker = struct {
    scope_map: ScopeMap,

    ast: []*Node,
    writer: *std.Io.Writer,
    types: std.ArrayList(TypeNode),
    tokens: []Token,
    file_table: *FileTable,

    allocator: std.mem.Allocator,
    root_node: *const std.Progress.Node,
    logger: err.ErrorLogger,

    string_ty_id: TypeHandle,

    pub fn init(
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        ast: []*Node,
        tokens: []Token,
        types: std.ArrayList(TypeNode),
        file_table: *FileTable,
        root_node: *const std.Progress.Node,
    ) Checker {
        return .{
            .scope_map = .init(allocator),
            .ast = ast,
            .writer = writer,
            .types = types,
            .tokens = tokens,
            .file_table = file_table,

            .allocator = allocator,
            .root_node = root_node,
            .logger = .init(file_table),

            .string_ty_id = 0,
        };
    }

    pub fn run(self: *Checker) !void {
        try self.buildCache();

        try self.scope_map.enter();
        for (self.ast) |node| {
            self.precheckTop(node, self.root_node, false) catch {};
        }

        for (self.ast) |node| {
            self.checkTop(node, self.root_node) catch continue;
        }
        if (try self.logger.dump(self.allocator, self.writer)) {
            return error.checker;
        }
    }

    fn precheckTop(self: *Checker, node: *Node, previous: *const std.Progress.Node, public: bool) !void {
        var parent_node = previous.start("Precheck ...", 1);
        defer parent_node.end();

        switch (node.tag) {
            .fn_stmt => {
                const name = self.file_table.spanStr(
                    node.file,
                    self.tokens[node.data.fn_stmt.name].start,
                    self.tokens[node.data.fn_stmt.name].end,
                );
                parent_node.setName(try self.allocator.print("Precheck {s}", .{name}));

                var param_types: []TypeHandle = &.{};
                if (node.data.fn_stmt.params) |params| {
                    var p_types = try std.ArrayList(TypeHandle).initCapacity(self.allocator, params.len);
                    for (params) |param| {
                        try p_types.append(self.allocator, param.data.param.ty);
                    }
                    param_types = try p_types.toOwnedSlice(self.allocator);
                }

                try self.scope_map.define(
                    name,
                    Symbol{
                        .kind = .func,
                        .start = node.start,
                        .end = node.end,
                        .file = node.file,
                        .public = public,
                        .data = .{
                            .func = .{
                                .params = param_types,
                                .returns = node.data.fn_stmt.returns,
                            },
                        },
                    },
                    &self.logger,
                );

                if (node.data.fn_stmt.params) |params| {
                    for (params) |param| {
                        try self.scope_map.define(
                            self.file_table.spanStr(
                                param.file,
                                self.tokens[param.data.param.name].start,
                                self.tokens[param.data.param.name].end,
                            ),
                            Symbol{
                                .kind = .param,
                                .start = param.start,
                                .end = param.end,
                                .file = param.file,
                                .public = true,
                                .data = .{
                                    .param = param.data.param.ty,
                                },
                            },
                            &self.logger,
                        );
                    }
                }
            },
            .var_stmt => {
                const name = self.file_table.spanStr(
                    node.file,
                    self.tokens[node.data.var_stmt.name].start,
                    self.tokens[node.data.var_stmt.name].end,
                );
                parent_node.setName(try self.allocator.print("Precheck {s}", .{name}));

                try self.scope_map.define(
                    self.file_table.spanStr(
                        node.file,
                        self.tokens[node.data.var_stmt.name].start,
                        self.tokens[node.data.var_stmt.name].end,
                    ),
                    Symbol{
                        .kind = .vari,
                        .start = node.start,
                        .end = node.end,
                        .file = node.file,
                        .public = public,
                        .data = .{ .vari = node.data.var_stmt.ty },
                    },
                    &self.logger,
                );
            },
            .pub_stmt => {
                parent_node.setName("Precheck pub top-level statement");

                try self.precheckTop(node.data.pub_stmt.stmt, &parent_node, true);
            },
            else => unreachable, // TODO
        }
    }

    fn buildCache(self: *Checker) !void {
        var parent_node = self.root_node.start("Building cache", 0);
        defer parent_node.end();
        var u8_type_id: ?TypeHandle = null;
        for (self.types.items, 0..) |t, idx| {
            switch (t.ty) {
                .u8 => {
                    u8_type_id = idx;
                    break;
                },
                else => {},
            }
        }
        if (u8_type_id) |u8_id| {
            for (self.types.items, 0..) |t, idx| {
                switch (t.ty) {
                    .slice => |inner| {
                        if (inner == u8_id) {
                            self.string_ty_id = idx;
                            break;
                        }
                    },
                    else => {},
                }
            }
            if (self.string_ty_id == 0) {
                self.string_ty_id = self.types.items.len;
                try self.types.append(self.allocator, TypeNode{
                    .ty = .{ .slice = u8_id },
                    .start = 0,
                    .end = 0,
                });
            }
        } else {
            const u8_id = self.types.items.len;
            try self.types.append(self.allocator, TypeNode{
                .ty = .u8,
                .start = 0,
                .end = 0,
            });
            const slice_id = self.types.items.len;
            try self.types.append(self.allocator, TypeNode{
                .ty = .{ .slice = u8_id },
                .start = 0,
                .end = 0,
            });
            self.string_ty_id = slice_id;
        }
    }

    fn checkTop(self: *Checker, node: *Node, previous: *const std.Progress.Node) !void {
        var parent_node = previous.start("Check...", 1);
        defer parent_node.end();

        switch (node.tag) {
            .fn_stmt => {
                const name = self.file_table.spanStr(
                    node.file,
                    self.tokens[node.data.fn_stmt.name].start,
                    self.tokens[node.data.fn_stmt.name].end,
                );
                parent_node.setName(name);
                for (node.data.fn_stmt.body) |stmt| {
                    try self.checkStmt(
                        stmt,
                        self.types.items[node.data.fn_stmt.returns].ty,
                        node,
                        &parent_node,
                    );
                }
            },
            .var_stmt => try self.checkStmt(node, .void, null, &parent_node),
            .pub_stmt => {
                parent_node.setName("Public");
                try self.checkTop(node.data.pub_stmt.stmt, &parent_node);
            },
            .struct_stmt => {}, // TODO: make
            else => unreachable, // ?
        }
    }

    fn checkStmt(self: *Checker, stmt: *Node, ret_ty: Type, fn_start: ?*Node, previous: *const std.Progress.Node) !void {
        var parent_node = previous.start("Statement", 0);
        defer parent_node.end();
        switch (stmt.tag) {
            .var_stmt => {
                parent_node.setName("Variable");

                const v = &stmt.data.var_stmt;
                try self.scope_map.define(
                    self.file_table.spanStr(stmt.file, self.tokens[v.name].start, self.tokens[v.name].end),
                    Symbol{
                        .start = stmt.start,
                        .end = stmt.end,
                        .file = stmt.file,
                        .kind = .vari,
                        .data = .{ .vari = v.ty },
                    },
                    &self.logger,
                );

                if (v.val) |val| {
                    const init_ty = try self.checkExpr(val);
                    const decl_ty = self.types.items[v.ty].ty;
                    if (!isTyEql(init_ty, decl_ty)) {
                        try self.logger.add(self.allocator, Error{
                            .start = val.start,
                            .end = val.end,
                            .file = val.file,
                            .kind = .{ .TypeError = TypeError.MismatchedVariableType },
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "cannot assign type '{s}' to variable of type '{s}'",
                                .{ @tagName(init_ty), @tagName(decl_ty) },
                            ),
                        });
                    }
                }
            },
            .ret_stmt => {
                parent_node.setName("Return");

                const v = &stmt.data.ret_stmt;
                if (v.val) |val| {
                    const returned = try self.checkExpr(val);
                    if (!isTyEql(ret_ty, returned)) {
                        try self.logger.add(self.allocator, Error{
                            .start = val.start,
                            .end = val.end,
                            .file = val.file,
                            .kind = .{ .TypeError = TypeError.TypeMismatch },
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "return type '{s}' mismatched with expected type '{s}'",
                                .{ @tagName(returned), @tagName(ret_ty) },
                            ),
                            .note = if (fn_start) |fn_stmt| Note{
                                .start = self.types.items[fn_stmt.data.fn_stmt.returns].start,
                                .end = self.types.items[fn_stmt.data.fn_stmt.returns].end,
                                .file = val.file,
                                .message = "return type declared here",
                            } else null,
                        });
                    }
                } else if (ret_ty != .void) {
                    try self.logger.add(self.allocator, Error{
                        .start = stmt.start,
                        .end = stmt.end,
                        .file = stmt.file,
                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                        .message = "expected non-void return value",
                        .note = if (fn_start) |fn_stmt| Note{
                            .start = self.types.items[fn_stmt.data.fn_stmt.returns].start,
                            .end = self.types.items[fn_stmt.data.fn_stmt.returns].end,
                            .file = stmt.file,
                            .message = "return type declared here",
                        } else null,
                    });
                }
            },
            .if_stmt => {
                parent_node.setName("If");

                const cond_ty = try self.checkExpr(stmt.data.if_stmt.cond);
                if (cond_ty != .bool) {
                    try self.logger.add(self.allocator, Error{
                        .start = stmt.data.if_stmt.cond.start,
                        .end = stmt.data.if_stmt.cond.end,
                        .file = stmt.data.if_stmt.cond.file,
                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                        .message = "condition of an if statement must be a bool",
                    });
                }
                var block = false;
                if (stmt.data.if_stmt.body.tag != .block) {
                    try self.scope_map.enter();
                    block = true;
                }
                try self.checkStmt(stmt.data.if_stmt.body, ret_ty, fn_start, &parent_node);
                if (block)
                    self.scope_map.exit();
                if (stmt.data.if_stmt.else_branch) |els| {
                    parent_node.setName("Else");

                    block = els.tag == .block;
                    if (block)
                        try self.scope_map.enter();
                    try self.checkStmt(els, ret_ty, fn_start, &parent_node);
                    if (block)
                        self.scope_map.exit();
                }
            },
            .block => {
                parent_node.setName("Block");

                try self.scope_map.enter();
                defer self.scope_map.exit();
                for (stmt.data.block.body) |stmt_i| {
                    parent_node.increaseEstimatedTotalItems(1);
                    try self.checkStmt(stmt_i, ret_ty, fn_start, &parent_node);
                }
            },
            .assign => {
                parent_node.setName("Assignment");

                const assi = &stmt.data.assignment;

                const lhs_ty = try self.checkExpr(assi.target);
                const rhs_ty = try self.checkExpr(assi.right);
                if (!isTyEql(lhs_ty, rhs_ty)) {
                    try self.logger.add(self.allocator, Error{
                        .start = stmt.start,
                        .end = stmt.end,
                        .file = stmt.file,
                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "incompatible types '{s}' and '{s}' in assignment",
                            .{ @tagName(lhs_ty), @tagName(rhs_ty) },
                        ),
                    });
                }
            },
            .for_stmt => {
                parent_node.setName("For");

                const f = &stmt.data.for_stmt;
                try self.scope_map.enter();
                defer self.scope_map.exit();

                if (f.vari) |vari| {
                    const n = self.tokens[vari.data.var_stmt.name];
                    try self.scope_map.define(
                        self.file_table.spanStr(n.file, n.start, n.end),
                        Symbol{
                            .start = vari.start,
                            .end = vari.end,
                            .file = vari.file,
                            .kind = .vari,
                            .data = .{
                                .vari = vari.data.var_stmt.ty,
                            },
                        },
                        &self.logger,
                    );

                    if (!isNum(self.types.items[vari.data.var_stmt.ty].ty))
                        try self.logger.add(self.allocator, .{
                            .start = vari.start,
                            .end = vari.end,
                            .file = vari.file,
                            .kind = .{ .TypeError = TypeError.TypeMismatch },
                            .message = "expected number as for loop variable type",
                        });
                    if (vari.data.var_stmt.val == null or try self.checkExpr(vari.data.var_stmt.val.?) == .null)
                        try self.logger.add(self.allocator, .{
                            .start = vari.start,
                            .end = vari.end,
                            .file = vari.file,
                            .kind = .{ .TypeError = TypeError.MustBeInit },
                            .message = "incrementor of for loop must be initialized and not null",
                        });

                    if (f.cond) |cond| {
                        _ = try self.checkExpr(cond);
                        if (f.incr) |incr| {
                            _ = try self.checkExpr(incr);
                        }
                    }
                }
                try self.checkStmt(f.body, ret_ty, fn_start, &parent_node);
            },
            .call => {
                parent_node.setName("Call");
                _ = try self.checkExpr(stmt);
            },
            else => try self.logger.add(self.allocator, .{
                .start = stmt.start,
                .end = stmt.end,
                .file = stmt.file,
                .kind = .{ .TypeError = TypeError.ExpectedStatement },
                .message = "expected a statement",
            }),
        }
    }

    fn checkExpr(self: *Checker, node: *Node) !Type {
        return switch (node.tag) {
            .identifier => blk: {
                const ident_str = self.file_table.spanStr(node.file, node.start, node.end);
                if (self.scope_map.lookup(ident_str)) |sym| {
                    break :blk switch (sym.kind) {
                        .vari => self.types.items[sym.data.vari].ty,
                        .func => self.types.items[sym.data.func.returns].ty, // not sure about this... TODO(perhaps): construct a function type for the fn
                        .param => self.types.items[sym.data.param].ty,
                        .strct => unreachable, // TODO
                    };
                }
                try self.logger.add(self.allocator, Error{
                    .start = node.start,
                    .end = node.end,
                    .file = node.file,
                    .kind = .{ .TypeError = TypeError.UndeclaredIdentifier },
                    .message = try self.allocator.print("use of undeclared identifier '{s}'", .{ident_str}),
                });
                return error.UnknownType;
            },
            .call => blk: {
                const c = &node.data.call;
                const callee_ident = self.file_table.spanStr(c.callee.file, c.callee.start, c.callee.end);
                if (self.scope_map.lookup(callee_ident)) |sym| {
                    if (!sym.public and c.callee.file != sym.file) {
                        try self.logger.add(self.allocator, .{
                            .start = c.callee.start,
                            .end = c.callee.end,
                            .file = c.callee.file,
                            .kind = .{ .TypeError = TypeError.NotPublic },
                            .message = "attempt to call non-public function defined in another file",
                            .note = .{
                                .start = sym.start,
                                .end = sym.end,
                                .file = sym.file,
                                .message = try self.allocator.print(
                                    "defined in file '{s}'",
                                    .{self.file_table.getPath(sym.file)},
                                ),
                            },
                        });
                        return error.NotPublic;
                    }

                    if (sym.kind == .func) {
                        for (c.args, 0..) |arg, idx| {
                            const arg_ty = try self.checkExpr(arg);
                            if (idx < sym.data.func.params.len) {
                                const expected_ty = self.types.items[sym.data.func.params[idx]].ty;
                                if (!isTyEql(arg_ty, expected_ty)) {
                                    try self.logger.add(self.allocator, Error{
                                        .start = arg.start,
                                        .end = arg.end,
                                        .file = arg.file,
                                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                                        .message = try std.fmt.allocPrint(
                                            self.allocator,
                                            "expected parameter type '{s}', found type '{s}'",
                                            .{ @tagName(expected_ty), @tagName(arg_ty) },
                                        ),
                                    });
                                    return error.TypeMismatch;
                                }
                            }
                        }
                        break :blk self.types.items[sym.data.func.returns].ty;
                    }
                }
                _ = try self.checkExpr(c.callee);
                for (c.args) |arg| {
                    _ = try self.checkExpr(arg);
                }
                try self.logger.add(self.allocator, Error{
                    .start = c.callee.start,
                    .end = c.callee.end,
                    .file = c.callee.file,
                    .kind = .{ .TypeError = TypeError.NonFunctionCall },
                    .message = try std.fmt.allocPrint(self.allocator, "cannot call non-function '{s}'", .{callee_ident}),
                });
                return error.UnexpectedType;
            },
            .property_access => blk: {
                const pa = &node.data.property_access;
                const target_ty = try self.checkExpr(pa.target);

                const prop_name = self.file_table.spanStr(
                    self.tokens[pa.name].file,
                    self.tokens[pa.name].start,
                    self.tokens[pa.name].end,
                );

                switch (target_ty) {
                    .slice => |inner_id| {
                        if (std.mem.eql(u8, prop_name, "len")) {
                            break :blk .u64;
                        } else if (std.mem.eql(u8, prop_name, "ptr")) { // TODO: maybe reuse the ptr type if .ptr was already got on this
                            const ptr_type_id = self.types.items.len;
                            try self.types.append(self.allocator, TypeNode{
                                .ty = .{ .ptr = inner_id },
                                .start = node.start,
                                .end = node.end,
                            });
                            break :blk self.types.items[ptr_type_id].ty;
                        }
                        try self.logger.add(self.allocator, .{
                            .start = self.tokens[pa.name].start,
                            .end = self.tokens[pa.name].end,
                            .file = self.tokens[pa.name].file,
                            .kind = .{ .TypeError = TypeError.UnknownSliceProperty },
                            .message = "unknown slice property, expected 'len' or 'ptr'",
                        });
                        break :blk error.UnknownSliceProperty;
                    },
                    else => {},
                }

                try self.logger.add(self.allocator, Error{
                    .start = node.start,
                    .end = node.end,
                    .file = node.file,
                    .kind = .{ .TypeError = TypeError.NotAMember },
                    .message = try self.allocator.print("type '{s}' has no member '{s}'", .{ @tagName(target_ty), prop_name }),
                });
                break :blk error.NotAMember;
            },
            .array_access => blk: {
                const aa = &node.data.array_access;
                const target_ty = try self.checkExpr(aa.target);
                const idx_ty = try self.checkExpr(aa.value);

                if (!isInt(idx_ty)) {
                    try self.logger.add(self.allocator, Error{
                        .start = aa.value.start,
                        .end = aa.value.end,
                        .file = aa.value.file,
                        .kind = .{ .TypeError = TypeError.IndexByNonInt },
                        .message = "array index must be an integer",
                    });
                    return error.IndexByNonInt;
                }

                switch (target_ty) {
                    .slice => |inner_id| break :blk self.types.items[inner_id].ty,
                    .array => |arr| break :blk self.types.items[arr.ty].ty,
                    else => {
                        try self.logger.add(self.allocator, Error{
                            .start = aa.target.start,
                            .end = aa.target.end,
                            .file = aa.target.file,
                            .kind = .{ .TypeError = TypeError.CannotIndexType },
                            .message = try std.fmt.allocPrint(self.allocator, "cannot index non-indexable type '{s}'", .{@tagName(target_ty)}),
                        });
                        return error.UnexpectedType;
                    },
                }
            },
            .string => self.types.items[self.string_ty_id].ty,
            .integer => .i32,
            .builtin => blk: {
                const b = &node.data.builtin;
                const name_str = self.file_table.spanStr(
                    self.tokens[b.name].file,
                    self.tokens[b.name].start,
                    self.tokens[b.name].end,
                );
                _ = name_str;
                // STUB:TODO
                break :blk .void;
            },
            .cast => {
                const c = &node.data.cast;
                _ = try self.checkExpr(c.expr);
                return self.types.items[c.ty].ty;
            },
            .true, .false => .bool,
            .null => .null,
            .binary_op_add,
            .binary_op_div,
            .binary_op_eq,
            .binary_op_gt,
            .binary_op_gt_eq,
            .binary_op_lt,
            .binary_op_lt_eq,
            .binary_op_mul,
            .binary_op_not_eq,
            .binary_op_sub,
            => blk: {
                const lhs = try self.checkExpr(node.data.binary_op.left);
                const rhs = try self.checkExpr(node.data.binary_op.right);
                if (!((isNum(lhs) and isNum(rhs)) or (lhs == .bool and rhs == .bool))) {
                    try self.logger.add(self.allocator, Error{
                        .start = node.start,
                        .end = node.end,
                        .file = node.file,
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = "binary operations only booleans or integers",
                    });
                    return error.UnexpectedType;
                }

                try self.matchTypes(
                    lhs,
                    rhs,
                    node.start,
                    node.end,
                    node.file,
                    try self.allocator.print(
                        "incompatible types {s} and {s} in binary operation",
                        .{ @tagName(lhs), @tagName(rhs) },
                    ),
                    null,
                );
                break :blk lhs;
            },
            .unary_op_not => blk: {
                const rhs = try self.checkExpr(node.data.unary_op.right);
                if (rhs != .bool) {
                    try self.logger.add(self.allocator, Error{
                        .start = node.start,
                        .end = node.end,
                        .file = node.file,
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = try std.fmt.allocPrint(self.allocator, "unexpected type {s}", .{@tagName(rhs)}),
                        .note = .{
                            .start = node.start,
                            .end = node.start + 1,
                            .file = node.file,
                            .message = "unary operator NOT only accepts bools",
                        },
                    });
                    return error.UnexpectedType;
                }
                break :blk rhs;
            },
            .unary_op_neg,
            .unary_op_decr,
            .unary_op_incr,
            => blk: {
                const rhs = try self.checkExpr(node.data.unary_op.right);
                if (!isNum(rhs)) {
                    try self.logger.add(self.allocator, Error{
                        .start = node.start,
                        .end = node.end,
                        .file = node.file,
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = try self.allocator.print("unexpected type {s}", .{@tagName(rhs)}),
                        .note = Note{
                            .start = node.start,
                            .end = node.start +
                                if (node.tag == .unary_op_decr or node.tag == .unary_op_incr)
                                    @as(usize, 2)
                                else
                                    @as(usize, 1),
                            .file = node.file,
                            .message = "this unary operator only accepts floats, unsigned integers or integers",
                        },
                    });
                    return error.UnexpectedType;
                }
                break :blk rhs;
            },
            else => .void,
        };
    }

    fn matchTypes(self: *Checker, lhs: Type, rhs: Type, start: usize, end: usize, file: FileHandle, message: []const u8, note: ?Note) !void {
        if (isTyEql(lhs, rhs))
            return;
        try self.logger.add(self.allocator, Error{
            .start = start,
            .end = end,
            .file = file,
            .kind = .{ .TypeError = TypeError.IncompatibleTypes },
            .message = message,
            .note = note,
        });
        return error.IncompatibleTypes;
    }

    fn isTyEql(i_1: Type, i_2: Type) bool {
        const tag = comptime std.meta.Tag(Type);
        const t1 = @as(tag, i_1);
        const t2 = @as(tag, i_2);
        return t1 == t2 or (i_1 == .null or i_2 == .null);
    }

    fn isInt(ty: Type) bool {
        return switch (ty) {
            .i8,
            .i16,
            .i32,
            .i64,
            .u8,
            .u16,
            .u32,
            .u64,
            => true,
            else => false,
        };
    }

    fn isFloat(ty: Type) bool {
        return switch (ty) {
            .f32,
            .f64,
            => true,
            else => false,
        };
    }

    fn isNum(ty: Type) bool {
        return isInt(ty) or isFloat(ty);
    }
};
