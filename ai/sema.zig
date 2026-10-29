const std = @import("std");

const parse = @import("parse.zig");
const Node = parse.Node;
const Data = parse.Data;
const Tag = parse.Tag;
const Type = parse.Type;
const TypeNode = parse.TypeNode;
const TypeID = parse.TypeID;

const lex = @import("lex.zig");
const Token = lex.Token;

const err = @import("error.zig");
const Error = err.Error;
const Note = err.Note;

pub const StructDef = struct {
    name: []const u8,
    file_path: []const u8,
    symbols: std.StringHashMap(Symbol),
    types: []const TypeNode,
    source: []const u8,
    tokens: []const Token,
    type_id: TypeID,
};

pub const Symbol = struct {
    data: Symbol.Data,
    kind: Symbol.Kind,
    start: usize,
    end: usize,
    types: ?[]const TypeNode = null,

    pub const Kind = enum {
        vari,
        func,
        param,
        strc,
    };
    pub const Data = union {
        vari: TypeID,
        func: struct {
            params: []TypeID,
            returns: TypeID,
        },
        strc: *StructDef,
        param: TypeID,
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

    pub fn deinit(self: *ScopeMap) void {
        for (self.maps.items) |*m| {
            m.deinit();
        }
        self.maps.deinit(self.allocator);
    }

    /// exit the current scope
    pub fn exit(self: *ScopeMap) void {
        if (self.maps.pop()) |*popped| {
            var p = popped.*;
            p.deinit();
        }
    }

    /// enter a new scope
    pub fn enter(self: *ScopeMap) !void {
        try self.maps.append(self.allocator, std.StringHashMap(Symbol).init(self.allocator));
    }

    /// defines a symbol in current scope,
    /// enters new scope if no scope has yet been entered
    pub fn define(self: *ScopeMap, name: []const u8, symbol: Symbol) !void {
        if (self.maps.items.len == 0) {
            try self.enter();
        }

        const l = &self.maps.items[self.maps.items.len - 1];
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

    pub fn lookupCurrentScope(self: *ScopeMap, name: []const u8) ?*const Symbol {
        if (self.maps.items.len == 0)
            return null;
        return self.maps.items[self.maps.items.len - 1].getPtr(name);
    }
};

pub const TypeError = error{
    IncompatibleTypes,
    UnknownType,
    UnexpectedType,
    TypeMismatch,
    MismatchedVariableType,
    Redefinition,
    UnknownMember,
    WrongArgumentCount,
    CannotCallNonFunction,
    CannotIndexNonIndexable,
    NonAssignableTarget,
    FileNotFound,
    CircularDependency,
};

pub const Checker = struct {
    scope_map: ScopeMap,

    ast: []*Node,
    types: std.ArrayList(TypeNode),

    tokens: []Token,

    source: []const u8,
    file_name: []const u8,

    allocator: std.mem.Allocator,
    io: std.Io,
    root_node: *const std.Progress.Node,
    logger: err.ErrorLogger,

    slow: bool,

    string_ty_id: TypeID,

    imported_modules: *std.StringHashMap(Symbol),
    import_stack: *std.StringHashMap(void),
    owns_import_maps: bool,

    struct_defs: std.AutoHashMap(TypeID, *StructDef),

    const BuiltinFn = *const fn (self: *Checker, node: *Node) anyerror!Symbol;

    const builtins = std.StaticStringMap(BuiltinFn).initComptime(.{
        .{ "import", &bltnImport },
    });

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        ast: []*Node,
        tokens: []Token,
        types: std.ArrayList(TypeNode),
        source: []const u8,
        file_name: []const u8,
        root_node: *const std.Progress.Node,
        slow: bool,
    ) Checker {
        const imported_mods = allocator.create(std.StringHashMap(Symbol)) catch @panic("OOM");
        imported_mods.* = std.StringHashMap(Symbol).init(allocator);

        const imp_stack = allocator.create(std.StringHashMap(void)) catch @panic("OOM");
        imp_stack.* = std.StringHashMap(void).init(allocator);

        return .{
            .scope_map = ScopeMap.init(allocator),
            .ast = ast,
            .types = types,
            .tokens = tokens,

            .source = source,
            .file_name = file_name,

            .allocator = allocator,
            .io = io,
            .root_node = root_node,
            .logger = err.ErrorLogger.init(file_name),

            .slow = slow,
            .string_ty_id = 0,

            .imported_modules = imported_mods,
            .import_stack = imp_stack,
            .owns_import_maps = true,

            .struct_defs = std.AutoHashMap(TypeID, *StructDef).init(allocator),
        };
    }

    pub fn initSub(
        allocator: std.mem.Allocator,
        io: std.Io,
        ast: []*Node,
        tokens: []Token,
        types: std.ArrayList(TypeNode),
        source: []const u8,
        file_name: []const u8,
        root_node: *const std.Progress.Node,
        slow: bool,
        imported_modules: *std.StringHashMap(Symbol),
        import_stack: *std.StringHashMap(void),
    ) Checker {
        return .{
            .scope_map = ScopeMap.init(allocator),
            .ast = ast,
            .types = types,
            .tokens = tokens,

            .source = source,
            .file_name = file_name,

            .allocator = allocator,
            .io = io,
            .root_node = root_node,
            .logger = err.ErrorLogger.init(file_name),

            .slow = slow,
            .string_ty_id = 0,

            .imported_modules = imported_modules,
            .import_stack = import_stack,
            .owns_import_maps = false,

            .struct_defs = std.AutoHashMap(TypeID, *StructDef).init(allocator),
        };
    }

    fn sleepIfSlow(self: *Checker, milliseconds: u16) !void {
        if (self.slow) try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(milliseconds), .awake);
    }

    fn spanStr(self: *Checker, start: usize, end: usize) []const u8 {
        const s = @min(start, self.source.len);
        const e = @min(end, self.source.len);
        if (s >= e) return "";
        return self.source[s..e];
    }

    pub fn run(self: *Checker) !void {
        try self.buildCache(); // IMPORTANT

        try self.scope_map.enter();

        for (self.ast) |node| {
            try self.sleepIfSlow(50);
            try self.precheckTop(node, self.root_node);
        }

        for (self.ast) |node| {
            try self.sleepIfSlow(50);
            self.checkTop(node, self.root_node) catch {};
        }

        if (self.logger.dump(self.allocator, self.source)) {
            return error.checker;
        }
    }

    fn precheckTop(self: *Checker, node: *Node, previous: *const std.Progress.Node) !void {
        var parent_node = previous.start("Prechecking top-level statement", 1);
        defer parent_node.end();

        switch (node.tag) {
            .fn_stmt => {
                var this_node = parent_node.start("Function", 0);
                defer this_node.end();

                const fn_data = &node.data.fn_stmt;
                const name = self.spanStr(self.tokens[fn_data.name].start, self.tokens[fn_data.name].end);

                if (self.scope_map.lookupCurrentScope(name)) |_| {
                    try self.logger.add(self.allocator, Error{
                        .start = self.tokens[fn_data.name].start,
                        .end = self.tokens[fn_data.name].end,
                        .kind = .{ .TypeError = TypeError.Redefinition },
                        .message = try std.fmt.allocPrint(self.allocator, "redefinition of function '{s}'", .{name}),
                    });
                }

                var param_types: []TypeID = &.{};
                if (fn_data.params) |params| {
                    var p_types = try std.ArrayList(TypeID).initCapacity(self.allocator, params.len);
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
                        .data = .{
                            .func = .{
                                .params = param_types,
                                .returns = fn_data.returns,
                            },
                        },
                    },
                );
            },
            .var_stmt => {
                var this_node = parent_node.start("Variable", 0);
                defer this_node.end();

                const var_data = &node.data.var_stmt;
                const name = self.spanStr(self.tokens[var_data.name].start, self.tokens[var_data.name].end);

                if (self.scope_map.lookupCurrentScope(name)) |_| {
                    try self.logger.add(self.allocator, Error{
                        .start = self.tokens[var_data.name].start,
                        .end = self.tokens[var_data.name].end,
                        .kind = .{ .TypeError = TypeError.Redefinition },
                        .message = try std.fmt.allocPrint(self.allocator, "redefinition of variable '{s}'", .{name}),
                    });
                }

                var sym_to_define = Symbol{
                    .kind = .vari,
                    .start = node.start,
                    .end = node.end,
                    .data = .{ .vari = var_data.ty },
                };

                if (var_data.val) |val| {
                    if (val.tag == .builtin) {
                        const b = &val.data.builtin;
                        const bltn_name = self.spanStr(self.tokens[b.name].start, self.tokens[b.name].end);
                        if (std.mem.eql(u8, bltn_name, "import")) {
                            if (self.bltnImport(val)) |import_sym| {
                                if (import_sym.kind == .strc) {
                                    sym_to_define.kind = .strc;
                                    sym_to_define.data = .{ .strc = import_sym.data.strc };
                                }
                            } else |_| {}
                        }
                    }
                }

                try self.scope_map.define(name, sym_to_define);
            },
            .pub_stmt => {
                try self.precheckTop(node.data.pub_stmt.stmt, previous);
            },
            else => {},
        }
    }

    fn buildCache(self: *Checker) !void {
        var parent_node = self.root_node.start("Building cache", 0);
        defer parent_node.end();
        var u8_type_id: ?TypeID = null;
        for (self.types.items, 0..) |t, idx| {
            switch (t.ty) {
                .u8 => {
                    u8_type_id = idx;
                    break;
                },
                else => {},
            }
        }
        try self.sleepIfSlow(30);
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
        var parent_node = previous.start("Checking top level statement", 1);
        defer parent_node.end();

        switch (node.tag) {
            .fn_stmt => {
                const fn_data = &node.data.fn_stmt;
                var this_node = parent_node.start("Checking function", fn_data.body.len);
                defer this_node.end();

                try self.scope_map.enter();
                defer self.scope_map.exit();

                if (fn_data.params) |params| {
                    for (params) |param| {
                        const pname = self.spanStr(self.tokens[param.data.param.name].start, self.tokens[param.data.param.name].end);
                        try self.scope_map.define(
                            pname,
                            Symbol{
                                .kind = .param,
                                .start = param.start,
                                .end = param.end,
                                .data = .{
                                    .param = param.data.param.ty,
                                },
                            },
                        );
                    }
                }

                const ret_type = self.types.items[fn_data.returns].ty;
                for (fn_data.body) |stmt| {
                    try self.checkStmt(stmt, ret_type, node, &this_node);
                }
            },
            .var_stmt => try self.checkStmt(node, .void, null, &parent_node),
            .pub_stmt => try self.checkTop(node.data.pub_stmt.stmt, previous),
            else => {},
        }
    }

    fn checkStmt(self: *Checker, stmt: *Node, ret_ty: Type, fn_start: ?*Node, previous: *const std.Progress.Node) !void {
        var parent_node = previous.start("Checking statement", 1);
        defer parent_node.end();
        switch (stmt.tag) {
            .var_stmt => {
                const v = &stmt.data.var_stmt;
                const name = self.spanStr(self.tokens[v.name].start, self.tokens[v.name].end);

                if (self.scope_map.lookupCurrentScope(name)) |_| {
                    try self.logger.add(self.allocator, Error{
                        .start = self.tokens[v.name].start,
                        .end = self.tokens[v.name].end,
                        .kind = .{ .TypeError = TypeError.Redefinition },
                        .message = try std.fmt.allocPrint(self.allocator, "redefinition of identifier '{s}'", .{name}),
                    });
                }

                var sym_to_define = Symbol{
                    .start = stmt.start,
                    .end = stmt.end,
                    .kind = .vari,
                    .data = .{ .vari = v.ty },
                };

                if (v.val) |val| {
                    if (self.resolveSymbol(val)) |rhs_sym| {
                        if (rhs_sym.kind == .strc) {
                            sym_to_define.kind = .strc;
                            sym_to_define.data = .{ .strc = rhs_sym.data.strc };
                        }
                    }

                    const init_ty = try self.checkExpr(val);
                    const decl_ty = self.types.items[v.ty].ty;
                    if (!self.isTyEql(init_ty, decl_ty)) {
                        if (!(sym_to_define.kind == .strc and decl_ty == .named)) {
                            try self.logger.add(self.allocator, Error{
                                .start = val.start,
                                .end = val.end,
                                .kind = .{ .TypeError = TypeError.MismatchedVariableType },
                                .message = try std.fmt.allocPrint(
                                    self.allocator,
                                    "cannot assign type '{s}' to variable of type '{s}'",
                                    .{ @tagName(init_ty), @tagName(decl_ty) },
                                ),
                            });
                        }
                    }
                }

                try self.scope_map.define(name, sym_to_define);
            },
            .ret_stmt => {
                const v = &stmt.data.ret_stmt;
                if (v.val) |val| {
                    const returned = try self.checkExpr(val);
                    if (!self.isTyEql(ret_ty, returned)) {
                        try self.logger.add(self.allocator, Error{
                            .start = val.start,
                            .end = val.end,
                            .kind = .{ .TypeError = TypeError.TypeMismatch },
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "return type '{s}' mismatched with expected type '{s}'",
                                .{ @tagName(returned), @tagName(ret_ty) },
                            ),
                            .note = if (fn_start) |fn_stmt| Note{
                                .start = self.types.items[fn_stmt.data.fn_stmt.returns].start,
                                .end = self.types.items[fn_stmt.data.fn_stmt.returns].end,
                                .message = "return type declared here",
                            } else null,
                        });
                    }
                } else if (ret_ty != .void) {
                    try self.logger.add(self.allocator, Error{
                        .start = stmt.start,
                        .end = stmt.end,
                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                        .message = "expected non-void return value",
                        .note = if (fn_start) |fn_stmt| Note{
                            .start = self.types.items[fn_stmt.data.fn_stmt.returns].start,
                            .end = self.types.items[fn_stmt.data.fn_stmt.returns].end,
                            .message = "return type declared here",
                        } else null,
                    });
                }
            },
            .if_stmt => {
                const if_s = &stmt.data.if_stmt;
                const cond_ty = try self.checkExpr(if_s.cond);
                if (cond_ty != .bool) {
                    try self.logger.add(self.allocator, Error{
                        .start = if_s.cond.start,
                        .end = if_s.cond.end,
                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                        .message = "condition of an if statement must be a bool",
                    });
                }

                try self.scope_map.enter();
                for (if_s.body) |body_stmt| {
                    try self.checkStmt(body_stmt, ret_ty, fn_start, &parent_node);
                }
                self.scope_map.exit();

                if (if_s.else_branch) |eb| {
                    if (eb.tag == .block) {
                        try self.scope_map.enter();
                        for (eb.data.block.body) |else_stmt| {
                            try self.checkStmt(else_stmt, ret_ty, fn_start, &parent_node);
                        }
                        self.scope_map.exit();
                    } else {
                        try self.checkStmt(eb, ret_ty, fn_start, &parent_node);
                    }
                }
            },
            .for_stmt => {
                const for_s = &stmt.data.for_stmt;
                try self.scope_map.enter();
                defer self.scope_map.exit();

                if (for_s.vari) |v| {
                    try self.checkStmt(v, .void, null, &parent_node);
                }
                if (for_s.cond) |c| {
                    const cond_ty = try self.checkExpr(c);
                    if (cond_ty != .bool) {
                        try self.logger.add(self.allocator, Error{
                            .start = c.start,
                            .end = c.end,
                            .kind = .{ .TypeError = TypeError.TypeMismatch },
                            .message = "condition of a for statement must be a bool",
                        });
                    }
                }
                if (for_s.incr) |i| {
                    _ = try self.checkExpr(i);
                }
                for (for_s.body) |body_stmt| {
                    try self.checkStmt(body_stmt, ret_ty, fn_start, &parent_node);
                }
            },
            .block => {
                var this_node = parent_node.start("Checking block", stmt.data.block.body.len);
                defer this_node.end();

                try self.scope_map.enter();
                defer self.scope_map.exit();
                for (stmt.data.block.body) |stmt_i| {
                    try self.checkStmt(stmt_i, ret_ty, fn_start, &this_node);
                }
            },
            .assign => {
                const assi = &stmt.data.assignment;
                switch (assi.target.tag) {
                    .identifier, .property_access, .array_access => {},
                    else => {
                        try self.logger.add(self.allocator, Error{
                            .start = assi.target.start,
                            .end = assi.target.end,
                            .kind = .{ .TypeError = TypeError.NonAssignableTarget },
                            .message = "cannot assign to non-lvalue expression",
                        });
                    },
                }

                const lhs_ty = try self.checkExpr(assi.target);
                const rhs_ty = try self.checkExpr(assi.right);
                if (!self.isTyEql(lhs_ty, rhs_ty)) {
                    try self.logger.add(self.allocator, Error{
                        .start = stmt.start,
                        .end = stmt.end,
                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "incompatible types '{s}' and '{s}' in assignment",
                            .{ @tagName(lhs_ty), @tagName(rhs_ty) },
                        ),
                    });
                }
            },
            .assign_add,
            .assign_sub,
            .assign_mul,
            .assign_div,
            => {
                const assi = &stmt.data.assignment;
                switch (assi.target.tag) {
                    .identifier, .property_access, .array_access => {},
                    else => {
                        try self.logger.add(self.allocator, Error{
                            .start = assi.target.start,
                            .end = assi.target.end,
                            .kind = .{ .TypeError = TypeError.NonAssignableTarget },
                            .message = "cannot assign to non-lvalue expression",
                        });
                    },
                }

                const lhs_ty = try self.checkExpr(assi.target);
                const rhs_ty = try self.checkExpr(assi.right);
                if (!isNum(lhs_ty) or !isNum(rhs_ty)) {
                    try self.logger.add(self.allocator, Error{
                        .start = stmt.start,
                        .end = stmt.end,
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = "compound assignment operators only accept numeric types",
                    });
                } else if (!self.isTyEql(lhs_ty, rhs_ty)) {
                    try self.logger.add(self.allocator, Error{
                        .start = stmt.start,
                        .end = stmt.end,
                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "incompatible types '{s}' and '{s}' in compound assignment",
                            .{ @tagName(lhs_ty), @tagName(rhs_ty) },
                        ),
                    });
                }
            },
            .pub_stmt => {
                try self.checkStmt(stmt.data.pub_stmt.stmt, ret_ty, fn_start, previous);
            },
            else => _ = try self.checkExpr(stmt),
        }
    }

    fn resolveSymbol(self: *Checker, node: *Node) ?Symbol {
        switch (node.tag) {
            .identifier => {
                const name = self.spanStr(node.start, node.end);
                if (self.scope_map.lookup(name)) |sym| {
                    return sym.*;
                }
                return null;
            },
            .property_access => {
                const pa = &node.data.property_access;
                const prop_name = self.spanStr(self.tokens[pa.name].start, self.tokens[pa.name].end);
                if (self.resolveStructDef(pa.target)) |target_struct| {
                    if (target_struct.symbols.get(prop_name)) |member_sym| {
                        var res = member_sym;
                        res.types = target_struct.types;
                        return res;
                    }
                }
                return null;
            },
            .builtin => {
                const b = &node.data.builtin;
                const name_str = self.spanStr(self.tokens[b.name].start, self.tokens[b.name].end);
                if (builtins.get(name_str)) |bltn_fn| {
                    return bltn_fn(self, node) catch null;
                }
                return null;
            },
            else => return null,
        }
    }

    fn resolveStructDef(self: *Checker, node: *Node) ?*StructDef {
        if (self.resolveSymbol(node)) |sym| {
            if (sym.kind == .strc) {
                return sym.data.strc;
            }
            if (sym.kind == .vari) {
                if (self.struct_defs.get(sym.data.vari)) |s| {
                    return s;
                }
            }
        }
        return null;
    }

    fn getTypeFromSymbolContext(self: *Checker, sym: ?*const Symbol, type_id: TypeID) Type {
        if (sym) |s| {
            if (s.types) |tbl| {
                if (type_id < tbl.len) return tbl[type_id].ty;
            }
        }
        if (type_id < self.types.items.len) {
            return self.types.items[type_id].ty;
        }
        return .void;
    }

    fn checkExpr(self: *Checker, node: *Node) anyerror!Type {
        return switch (node.tag) {
            .identifier => blk: {
                const ident_str = self.spanStr(node.start, node.end);
                if (self.scope_map.lookup(ident_str)) |sym| {
                    break :blk switch (sym.kind) {
                        .vari => self.getTypeFromSymbolContext(sym, sym.data.vari),
                        .func => self.getTypeFromSymbolContext(sym, sym.data.func.returns),
                        .param => self.getTypeFromSymbolContext(sym, sym.data.param),
                        .strc => self.types.items[sym.data.strc.type_id].ty,
                    };
                }
                try self.logger.add(self.allocator, Error{
                    .start = node.start,
                    .end = node.end,
                    .kind = .{ .TypeError = TypeError.UnknownType },
                    .message = try std.fmt.allocPrint(self.allocator, "use of undeclared identifier '{s}'", .{ident_str}),
                });
                return TypeError.UnknownType;
            },
            .call => blk: {
                const c = &node.data.call;

                if (self.resolveSymbol(c.callee)) |callee_sym| {
                    if (callee_sym.kind == .func) {
                        const fn_data = &callee_sym.data.func;
                        if (c.args.len != fn_data.params.len) {
                            try self.logger.add(self.allocator, Error{
                                .start = node.start,
                                .end = node.end,
                                .kind = .{ .TypeError = TypeError.WrongArgumentCount },
                                .message = try std.fmt.allocPrint(
                                    self.allocator,
                                    "expected {} arguments, found {}",
                                    .{ fn_data.params.len, c.args.len },
                                ),
                            });
                        }

                        for (c.args, 0..) |arg, idx| {
                            const arg_ty = try self.checkExpr(arg);
                            if (idx < fn_data.params.len) {
                                const expected_ty = self.getTypeFromSymbolContext(&callee_sym, fn_data.params[idx]);
                                if (!self.isTyEql(arg_ty, expected_ty)) {
                                    try self.logger.add(self.allocator, Error{
                                        .start = arg.start,
                                        .end = arg.end,
                                        .kind = .{ .TypeError = TypeError.TypeMismatch },
                                        .message = try std.fmt.allocPrint(
                                            self.allocator,
                                            "expected parameter type '{s}', found type '{s}'",
                                            .{ @tagName(expected_ty), @tagName(arg_ty) },
                                        ),
                                    });
                                }
                            }
                        }
                        break :blk self.getTypeFromSymbolContext(&callee_sym, fn_data.returns);
                    }
                }

                const callee_ty = try self.checkExpr(c.callee);
                if (callee_ty == .func) {
                    const f = callee_ty.func;
                    const num_params = if (f.params_end >= f.params_start) (f.params_end - f.params_start + 1) else 0;
                    if (c.args.len != num_params) {
                        try self.logger.add(self.allocator, Error{
                            .start = node.start,
                            .end = node.end,
                            .kind = .{ .TypeError = TypeError.WrongArgumentCount },
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "expected {} arguments, found {}",
                                .{ num_params, c.args.len },
                            ),
                        });
                    }

                    for (c.args, 0..) |arg, idx| {
                        const arg_ty = try self.checkExpr(arg);
                        if (idx < num_params) {
                            const expected_ty = self.types.items[f.params_start + idx].ty;
                            if (!self.isTyEql(arg_ty, expected_ty)) {
                                try self.logger.add(self.allocator, Error{
                                    .start = arg.start,
                                    .end = arg.end,
                                    .kind = .{ .TypeError = TypeError.TypeMismatch },
                                    .message = try std.fmt.allocPrint(
                                        self.allocator,
                                        "expected parameter type '{s}', found type '{s}'",
                                        .{ @tagName(expected_ty), @tagName(arg_ty) },
                                    ),
                                });
                            }
                        }
                    }
                    break :blk self.types.items[f.returns].ty;
                }

                for (c.args) |arg| {
                    _ = try self.checkExpr(arg);
                }

                const callee_ident = self.spanStr(c.callee.start, c.callee.end);
                try self.logger.add(self.allocator, Error{
                    .start = c.callee.start,
                    .end = c.callee.end,
                    .kind = .{ .TypeError = TypeError.CannotCallNonFunction },
                    .message = try std.fmt.allocPrint(self.allocator, "cannot call non-function '{s}'", .{callee_ident}),
                });
                return TypeError.CannotCallNonFunction;
            },
            .property_access => blk: {
                const pa = &node.data.property_access;
                const prop_name = self.spanStr(self.tokens[pa.name].start, self.tokens[pa.name].end);

                if (self.resolveStructDef(pa.target)) |target_struct| {
                    if (target_struct.symbols.get(prop_name)) |member_sym| {
                        break :blk switch (member_sym.kind) {
                            .vari => self.getTypeFromSymbolContext(&member_sym, member_sym.data.vari),
                            .func => self.getTypeFromSymbolContext(&member_sym, member_sym.data.func.returns),
                            .param => self.getTypeFromSymbolContext(&member_sym, member_sym.data.param),
                            .strc => self.types.items[member_sym.data.strc.type_id].ty,
                        };
                    }

                    try self.logger.add(self.allocator, Error{
                        .start = node.start,
                        .end = node.end,
                        .kind = .{ .TypeError = TypeError.UnknownMember },
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "struct '{s}' has no member '{s}'",
                            .{ target_struct.name, prop_name },
                        ),
                    });
                    return TypeError.UnknownMember;
                }

                const target_ty = try self.checkExpr(pa.target);
                switch (target_ty) {
                    .slice => |inner_id| {
                        if (std.mem.eql(u8, prop_name, "len")) {
                            break :blk .u64;
                        } else if (std.mem.eql(u8, prop_name, "ptr")) {
                            const ptr_type_id = self.types.items.len;
                            try self.types.append(self.allocator, TypeNode{
                                .ty = .{ .ptr = inner_id },
                                .start = node.start,
                                .end = node.end,
                            });
                            break :blk self.types.items[ptr_type_id].ty;
                        }
                    },
                    else => {},
                }

                try self.logger.add(self.allocator, Error{
                    .start = node.start,
                    .end = node.end,
                    .kind = .{ .TypeError = TypeError.UnexpectedType },
                    .message = try std.fmt.allocPrint(self.allocator, "type '{s}' has no member '{s}'", .{ @tagName(target_ty), prop_name }),
                });
                return TypeError.UnexpectedType;
            },
            .array_access => blk: {
                const aa = &node.data.array_access;
                const target_ty = try self.checkExpr(aa.target);
                const idx_ty = try self.checkExpr(aa.value);

                if (!isInt(idx_ty)) {
                    try self.logger.add(self.allocator, Error{
                        .start = aa.value.start,
                        .end = aa.value.end,
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = "array index must be an integer",
                    });
                }

                switch (target_ty) {
                    .slice => |inner_id| break :blk self.types.items[inner_id].ty,
                    .array => |arr| break :blk self.types.items[arr.ty].ty,
                    .ptr => |inner_id| blk_ptr: {
                        if (inner_id < self.types.items.len) {
                            const elem_ty = self.types.items[inner_id].ty;
                            if (elem_ty == .void) {
                                try self.logger.add(self.allocator, Error{
                                    .start = aa.target.start,
                                    .end = aa.target.end,
                                    .kind = .{ .TypeError = TypeError.UnexpectedType },
                                    .message = "cannot index 'void *' pointer; cast to a typed pointer first",
                                });
                                return TypeError.UnexpectedType;
                            }
                            break :blk_ptr elem_ty;
                        }
                        break :blk_ptr .void;
                    },
                    else => {
                        try self.logger.add(self.allocator, Error{
                            .start = aa.target.start,
                            .end = aa.target.end,
                            .kind = .{ .TypeError = TypeError.CannotIndexNonIndexable },
                            .message = try std.fmt.allocPrint(self.allocator, "cannot index non-indexable type '{s}'", .{@tagName(target_ty)}),
                        });
                        return TypeError.CannotIndexNonIndexable;
                    },
                }
            },
            .string => self.types.items[self.string_ty_id].ty,
            .integer => .i32,
            .builtin => blk: {
                const b = &node.data.builtin;
                const name_str = self.spanStr(self.tokens[b.name].start, self.tokens[b.name].end);

                if (builtins.get(name_str)) |bltn_fn| {
                    const sym = try bltn_fn(self, node);
                    break :blk switch (sym.kind) {
                        .strc => self.types.items[sym.data.strc.type_id].ty,
                        .func => self.types.items[sym.data.func.returns].ty,
                        .vari => self.types.items[sym.data.vari].ty,
                        .param => self.types.items[sym.data.param].ty,
                    };
                }

                for (b.args) |arg| {
                    _ = try self.checkExpr(arg);
                }

                try self.logger.add(self.allocator, Error{
                    .start = node.start,
                    .end = node.end,
                    .kind = .{ .TypeError = TypeError.UnexpectedType },
                    .message = try std.fmt.allocPrint(self.allocator, "unknown builtin '@{s}'", .{name_str}),
                });
                return TypeError.UnexpectedType;
            },
            .cast => {
                const c = &node.data.cast;
                const from_ty = try self.checkExpr(c.expr);
                const to_ty = self.types.items[c.ty].ty;

                if (self.isTyEql(from_ty, to_ty)) {
                    return to_ty;
                }

                // Pointer to pointer cast (e.g. void* to T*, T* to void*, or between any pointers like in C)
                if (from_ty == .ptr and to_ty == .ptr) {
                    return to_ty;
                }

                // Numeric casts (int to int, int to float, float to int, float to float)
                if (isNum(from_ty) and isNum(to_ty)) {
                    return to_ty;
                }

                // Integer to pointer or pointer to integer (C-style)
                if ((isInt(from_ty) and to_ty == .ptr) or (from_ty == .ptr and isInt(to_ty))) {
                    return to_ty;
                }

                try self.logger.add(self.allocator, Error{
                    .start = node.start,
                    .end = node.end,
                    .kind = .{ .TypeError = TypeError.IncompatibleTypes },
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "cannot cast type '{s}' to '{s}'",
                        .{ @tagName(from_ty), @tagName(to_ty) },
                    ),
                });
                return TypeError.IncompatibleTypes;
            },
            ._true, ._false => .bool,
            ._null => .nullt,
            .binary_op_add,
            .binary_op_div,
            .binary_op_mul,
            .binary_op_sub,
            => blk: {
                const lhs = try self.checkExpr(node.data.binary_op.left);
                const rhs = try self.checkExpr(node.data.binary_op.right);

                // Pointer arithmetic: ptr + int, int + ptr, ptr - int, ptr - ptr
                if (node.tag == .binary_op_add) {
                    if (lhs == .ptr and isInt(rhs)) break :blk lhs;
                    if (isInt(lhs) and rhs == .ptr) break :blk rhs;
                } else if (node.tag == .binary_op_sub) {
                    if (lhs == .ptr and isInt(rhs)) break :blk lhs;
                    if (lhs == .ptr and rhs == .ptr) break :blk .i64;
                }

                if (!(isNum(lhs) and isNum(rhs))) {
                    try self.logger.add(self.allocator, Error{
                        .start = node.start,
                        .end = node.end,
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = "binary operations only accept numbers or pointer arithmetic",
                    });
                    return TypeError.UnexpectedType;
                }

                try self.matchTypes(
                    lhs,
                    rhs,
                    node.start,
                    node.end,
                    try std.fmt.allocPrint(
                        self.allocator,
                        "incompatible types {s} and {s} in binary operation",
                        .{ @tagName(lhs), @tagName(rhs) },
                    ),
                    null,
                );
                break :blk lhs;
            },
            .binary_op_eq,
            .binary_op_not_eq,
            => blk: {
                const lhs = try self.checkExpr(node.data.binary_op.left);
                const rhs = try self.checkExpr(node.data.binary_op.right);
                try self.matchTypes(
                    lhs,
                    rhs,
                    node.start,
                    node.end,
                    try std.fmt.allocPrint(
                        self.allocator,
                        "incompatible types {s} and {s} in comparison",
                        .{ @tagName(lhs), @tagName(rhs) },
                    ),
                    null,
                );
                break :blk .bool;
            },
            .binary_op_gt,
            .binary_op_gt_eq,
            .binary_op_lt,
            .binary_op_lt_eq,
            => blk: {
                const lhs = try self.checkExpr(node.data.binary_op.left);
                const rhs = try self.checkExpr(node.data.binary_op.right);
                if (!(isNum(lhs) and isNum(rhs))) {
                    try self.logger.add(self.allocator, Error{
                        .start = node.start,
                        .end = node.end,
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = "relational comparisons only accept numbers",
                    });
                    return TypeError.UnexpectedType;
                }

                try self.matchTypes(
                    lhs,
                    rhs,
                    node.start,
                    node.end,
                    try std.fmt.allocPrint(
                        self.allocator,
                        "incompatible types {s} and {s} in relational comparison",
                        .{ @tagName(lhs), @tagName(rhs) },
                    ),
                    null,
                );
                break :blk .bool;
            },
            .unary_op_not => blk: {
                const rhs = try self.checkExpr(node.data.unary_op.right);
                if (rhs != .bool) {
                    try self.logger.add(self.allocator, Error{
                        .start = node.start,
                        .end = node.end,
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = try std.fmt.allocPrint(self.allocator, "unexpected type {s}", .{@tagName(rhs)}),
                        .note = .{
                            .start = node.start,
                            .end = node.start + 1,
                            .message = "unary operator NOT only accepts bools",
                        },
                    });
                    return TypeError.UnexpectedType;
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
                        .kind = .{ .TypeError = TypeError.UnexpectedType },
                        .message = try std.fmt.allocPrint(self.allocator, "unexpected type {s}", .{@tagName(rhs)}),
                        .note = Note{
                            .start = node.start,
                            .end = node.start + if (node.tag == .unary_op_decr or node.tag == .unary_op_incr) @as(usize, 2) else @as(usize, 1),
                            .message = "this unary operator only accepts floats, unsigned integers or integers",
                        },
                    });
                    return TypeError.UnexpectedType;
                }
                break :blk rhs;
            },
            else => .void,
        };
    }

    fn bltnImport(self: *Checker, node: *Node) anyerror!Symbol {
        const b = &node.data.builtin;
        if (b.args.len != 1) {
            try self.logger.add(self.allocator, Error{
                .start = node.start,
                .end = node.end,
                .kind = .{ .TypeError = TypeError.WrongArgumentCount },
                .message = try std.fmt.allocPrint(self.allocator, "@import expects 1 argument (file path), found {}", .{b.args.len}),
            });
            return TypeError.WrongArgumentCount;
        }

        const path_node = b.args[0];
        if (path_node.tag != .string) {
            try self.logger.add(self.allocator, Error{
                .start = path_node.start,
                .end = path_node.end,
                .kind = .{ .TypeError = TypeError.UnexpectedType },
                .message = "@import argument must be a string literal",
            });
            return TypeError.UnexpectedType;
        }

        const tok = self.tokens[path_node.data.token];
        const rel_path = self.source[tok.start..tok.end];

        const resolved_path = blk: {
            if (std.fs.path.dirname(self.file_name)) |dir| {
                break :blk try std.fs.path.join(self.allocator, &.{ dir, rel_path });
            } else {
                break :blk try self.allocator.dupe(u8, rel_path);
            }
        };

        if (self.imported_modules.get(resolved_path)) |sym| {
            return sym;
        }

        if (self.import_stack.contains(resolved_path)) {
            try self.logger.add(self.allocator, Error{
                .start = node.start,
                .end = node.end,
                .kind = .{ .TypeError = TypeError.CircularDependency },
                .message = try std.fmt.allocPrint(self.allocator, "circular import detected: '{s}'", .{resolved_path}),
            });
            return TypeError.CircularDependency;
        }

        try self.import_stack.put(resolved_path, {});
        defer _ = self.import_stack.remove(resolved_path);

        const file = std.Io.Dir.cwd().openFile(self.io, resolved_path, .{}) catch |err_val| {
            try self.logger.add(self.allocator, Error{
                .start = path_node.start,
                .end = path_node.end,
                .kind = .{ .TypeError = TypeError.FileNotFound },
                .message = try std.fmt.allocPrint(self.allocator, "could not open imported file '{s}': {}", .{ resolved_path, err_val }),
            });
            return TypeError.FileNotFound;
        };
        defer file.close(self.io);

        var buf: [1024]u8 = undefined;
        var reader = file.reader(self.io, &buf);
        const imported_source = reader.interface.allocRemaining(self.allocator, .unlimited) catch |err_val| {
            try self.logger.add(self.allocator, Error{
                .start = path_node.start,
                .end = path_node.end,
                .kind = .{ .TypeError = TypeError.FileNotFound },
                .message = try std.fmt.allocPrint(self.allocator, "could not read imported file '{s}': {}", .{ resolved_path, err_val }),
            });
            return TypeError.FileNotFound;
        };

        var imported_progress = self.root_node.start("Importing module", 0);
        defer imported_progress.end();

        var imported_lexer = lex.Lexer.init(imported_source, resolved_path);
        const imported_tokens = imported_lexer.run(self.allocator, imported_progress, false, null) catch {
            return TypeError.UnexpectedType;
        };

        var imported_parser = parse.Parser.init(self.allocator, self.io, imported_tokens, imported_source, resolved_path, imported_progress, false);
        const imported_ast = imported_parser.run() catch {
            return TypeError.UnexpectedType;
        };

        var sub_checker = Checker.initSub(
            self.allocator,
            self.io,
            imported_ast,
            imported_tokens,
            imported_parser.types,
            imported_source,
            resolved_path,
            &imported_progress,
            false,
            self.imported_modules,
            self.import_stack,
        );

        sub_checker.run() catch |err_val| {
            try self.logger.add(self.allocator, Error{
                .start = node.start,
                .end = node.end,
                .kind = .{ .TypeError = TypeError.UnexpectedType },
                .message = try std.fmt.allocPrint(self.allocator, "imported module '{s}' failed semantic analysis", .{resolved_path}),
            });
            return err_val;
        };

        const struct_name = std.fs.path.stem(rel_path);
        const struct_type_id = self.types.items.len;
        try self.types.append(self.allocator, TypeNode{
            .ty = .{
                .named = .{
                    .path = .{ .start = node.start, .end = node.end },
                    .args = null,
                },
            },
            .start = node.start,
            .end = node.end,
        });

        const struct_def = try self.allocator.create(StructDef);
        struct_def.* = StructDef{
            .name = struct_name,
            .file_path = resolved_path,
            .symbols = std.StringHashMap(Symbol).init(self.allocator),
            .types = sub_checker.types.items,
            .source = imported_source,
            .tokens = imported_tokens,
            .type_id = struct_type_id,
        };

        if (sub_checker.scope_map.maps.items.len > 0) {
            var it = sub_checker.scope_map.maps.items[0].iterator();
            while (it.next()) |entry| {
                var sym_copy = entry.value_ptr.*;
                sym_copy.types = sub_checker.types.items;
                try struct_def.symbols.put(entry.key_ptr.*, sym_copy);
            }
        }

        try self.struct_defs.put(struct_type_id, struct_def);

        const sym = Symbol{
            .kind = .strc,
            .start = node.start,
            .end = node.end,
            .data = .{
                .strc = struct_def,
            },
            .types = sub_checker.types.items,
        };

        try self.imported_modules.put(resolved_path, sym);
        return sym;
    }

    fn matchTypes(self: *Checker, lhs: Type, rhs: Type, start: usize, end: usize, message: []const u8, note: ?Note) !void {
        if (self.isTyEql(lhs, rhs))
            return;
        try self.logger.add(self.allocator, Error{
            .start = start,
            .end = end,
            .kind = .{ .TypeError = TypeError.IncompatibleTypes },
            .message = message,
            .note = note,
        });
        return TypeError.IncompatibleTypes;
    }

    fn isTyEql(self: *Checker, i_1: Type, i_2: Type) bool {
        if (i_1 == .nullt or i_2 == .nullt) return true;
        const tag1 = std.meta.activeTag(i_1);
        const tag2 = std.meta.activeTag(i_2);
        if (tag1 != tag2) return false;

        return switch (i_1) {
            .void, .nullt, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .bool => true,
            .ptr => |p1| blk: {
                const p2 = i_2.ptr;
                if (p1 < self.types.items.len and p2 < self.types.items.len) {
                    break :blk self.isTyEql(self.types.items[p1].ty, self.types.items[p2].ty);
                }
                break :blk p1 == p2;
            },
            .slice => |s1| blk: {
                const s2 = i_2.slice;
                if (s1 < self.types.items.len and s2 < self.types.items.len) {
                    break :blk self.isTyEql(self.types.items[s1].ty, self.types.items[s2].ty);
                }
                break :blk s1 == s2;
            },
            .array => |a1| blk: {
                const a2 = i_2.array;
                if (a1.ty < self.types.items.len and a2.ty < self.types.items.len) {
                    break :blk self.isTyEql(self.types.items[a1.ty].ty, self.types.items[a2.ty].ty);
                }
                break :blk a1.ty == a2.ty;
            },
            .func => |f1| blk: {
                const f2 = i_2.func;
                const ret1 = self.types.items[f1.returns].ty;
                const ret2 = self.types.items[f2.returns].ty;
                if (!self.isTyEql(ret1, ret2)) break :blk false;
                const len1 = if (f1.params_end >= f1.params_start) (f1.params_end - f1.params_start + 1) else 0;
                const len2 = if (f2.params_end >= f2.params_start) (f2.params_end - f2.params_start + 1) else 0;
                if (len1 != len2) break :blk false;
                for (0..len1) |idx| {
                    const p1 = self.types.items[f1.params_start + idx].ty;
                    const p2 = self.types.items[f2.params_start + idx].ty;
                    if (!self.isTyEql(p1, p2)) break :blk false;
                }
                break :blk true;
            },
            .named => |n1| blk: {
                const n2 = i_2.named;
                const name1 = self.spanStr(n1.path.start, n1.path.end);
                const name2 = self.spanStr(n2.path.start, n2.path.end);
                break :blk std.mem.eql(u8, name1, name2);
            },
        };
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
