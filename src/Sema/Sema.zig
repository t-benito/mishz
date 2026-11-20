const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const ProgNode = std.Progress.Node;

const Ast = @import("../Ast.zig");
const Node = Ast.Node;
const Data = Ast.Data;
const Tag = Ast.Tag;
const err = @import("../error.zig");
const ErrorLogger = err.ErrorLogger;
const Error = err.Error;
const Note = err.Note;
const FileTable = @import("../FileTable.zig");
const FileHandle = FileTable.Handle;
const lex = @import("../lex.zig");
const Token = lex.Token;
const typet = @import("Type.zig");
const Type = typet.Type;
const Symbol = @import("Symbol.zig");
const Scope = Symbol.Scope;

pub const SemaError = enum(u8) {
    MismatchedTypes = 0,
    AlreadyDefined = 1,
    UnknownIdentifier = 2,
    NotSupportedType = 3,
};

const Err = error{SemaError} || Allocator.Error || Writer.Error;

pub const Sema = @This();

allocator: Allocator,
writer: *Io.Writer,

ast: *Ast,
logger: ErrorLogger,
file_table: *FileTable,
file: FileHandle,
prev: *const ProgNode,

scope: Scope,

pub fn init(allocator: Allocator, writer: *Io.Writer, file_table: *FileTable, file: FileHandle, root: *const ProgNode) Sema {
    return Sema{
        .allocator = allocator,
        .writer = writer,
        .ast = &file_table.files.items(.ast)[file].?,
        .logger = .init(allocator, file_table, file),
        .file_table = file_table,
        .file = file,
        .prev = root,
        .scope = .{},
    };
}

pub fn define(self: *Sema, name: []const u8, sym: Symbol, node: *const Node) !void {
    self.scope.define(name, sym, self.allocator) catch |erro| {
        switch (erro) {
            error.AlreadyDefined => try self.logger.add(.{
                .start = node.start,
                .end = node.end,
                .kind = .{ .SemaError = .AlreadyDefined },
                .message = try self.allocator.print("{s} with name '{s}' already defined", .{
                    switch (sym.kind) {
                        .function => "function",
                        .module => "module",
                        .param, .variable => "variable",
                    },
                    name,
                }),
            }),
            else => {},
        }
        return error.SemaError;
    };
}

pub fn run(self: *Sema) !void {
    for (self.ast.nodes) |node| {
        try self.precheckTop(node);
    }

    for (self.ast.nodes) |node| {
        self.checkTop(node) catch {};
    }

    if (try self.logger.dump(self.allocator, self.writer)) {
        return error.sema;
    }
}

fn precheckTop(self: *Sema, node: *Node) Err!void {
    switch (node.tag) {
        .fn_stmt => {
            const name = self.file_table.tokenStr(
                self.ast.tokens[node.data.fn_stmt.name],
                self.file,
            );
            try self.define(name, Symbol{
                .kind = .function,
                .root = node.data.fn_stmt.name,
                .ty = node.getTy(),
                .mut = false, // func never mut
            }, node);
        },
        .import => {},
        else => unreachable, // TODO
    }
}

fn checkTop(self: *Sema, node: *Node) Err!void {
    switch (node.tag) {
        .fn_stmt => {
            const prev_scope = self.scope;
            self.scope = .{
                .parent = &prev_scope,
                .kind = .{ .function = node.getTy() },
            };
            defer self.scope = prev_scope;

            for (node.data.fn_stmt.body) |stmt| {
                try self.checkStmt(stmt);
            }
        },
        .import => {}, // should aready be handled in precheck?
        else => unreachable, // TODO
    }
}

fn checkStmt(self: *Sema, node: *Node) !void {
    switch (node.tag) {
        .let_stmt,
        .let_mut_stmt,
        => try self.checkLet(node),
        else => unreachable, // TODO
    }
}

fn checkLet(self: *Sema, node: *Node) !void {
    const let = &node.data.let_stmt;
    const mut = node.tag == .let_mut_stmt;

    const ty = try self.checkExpr(let.val);
    if (node.ty != null and ty != node.getTy()) {
        try self.logger.add(.{
            .start = node.start,
            .end = node.end,
            .kind = .{ .SemaError = .MismatchedTypes },
            .message = try self.allocator.print(
                "mismatched type: expected {s}, got {s}",
                .{
                    try node.getTy().allocName(self.file_table, self.allocator),
                    try ty.allocName(self.file_table, self.allocator),
                },
            ),
        });
        return error.SemaError;
    }

    if (node.ty == null)
        node.ty = ty;

    const name = self.file_table.tokenStr(self.ast.tokens[let.name], self.file);
    try self.define(name, .{
        .root = let.name,
        .kind = .variable,
        .ty = node.getTy(),
        .mut = mut,
    }, node);
}

fn checkExpr(self: *Sema, node: *Node) Err!Type.Handle {
    switch (node.tag) {
        .binary_op_add,
        .binary_op_bit_and,
        .binary_op_bit_left,
        .binary_op_bit_not,
        .binary_op_bit_or,
        .binary_op_bit_right,
        .binary_op_bit_xor,
        .binary_op_div,
        .binary_op_mul,
        .binary_op_sub,
        => return try self.checkBinaryOp(node),
        .binary_op_eq,
        .binary_op_not_eq,
        .binary_op_lt,
        .binary_op_lt_eq,
        .binary_op_gt,
        .binary_op_gt_eq,
        => return try self.checkComparison(node),
        .integer => return makeNodeTy(node, .i32),
        .false,
        .true,
        => return makeNodeTy(node, .bool),
        .identifier => return try self.checkIdentifier(node),
        else => unreachable, // TODO
    }
    return .i32;
}

/// helper to make the two liners in checkExpr two liners
fn makeNodeTy(node: *Node, ty: Type.Handle) Type.Handle {
    node.ty = ty;
    return ty;
}

fn checkBinaryOp(self: *Sema, node: *Node) !Type.Handle {
    const binary_op = &node.data.binary_op;

    const lhs_ty = try self.checkExpr(binary_op.left);
    const rhs_ty = try self.checkExpr(binary_op.right);

    if (lhs_ty != rhs_ty) {
        try self.logger.add(.{
            .start = node.start,
            .end = node.end,
            .kind = .{ .SemaError = .MismatchedTypes },
            .message = try self.allocator.print(
                "mismatched types {s} and {s} in binary expression",
                .{
                    try lhs_ty.allocName(self.file_table, self.allocator),
                    try rhs_ty.allocName(self.file_table, self.allocator),
                },
            ),
        });
    }
    if (!lhs_ty.isNum()) {
        try self.logger.add(.{
            .start = node.start,
            .end = node.end,
            .kind = .{ .SemaError = .NotSupportedType },
            .message = try self.allocator.print(
                "operator not supported for type {s}",
                .{try lhs_ty.allocName(self.file_table, self.allocator)},
            ),
        });
        return error.SemaError;
    }

    node.ty = lhs_ty;
    return lhs_ty;
}

fn checkComparison(self: *Sema, node: *Node) !Type.Handle {
    // TODO
    _ = self;
    _ = node;
    return .bool;
}

fn checkIdentifier(self: *Sema, node: *Node) !Type.Handle {
    std.debug.assert(node.tag == .identifier); // who knows?

    const name = self.file_table.tokenHStr(
        node.data.token,
        self.file,
    );
    const sym = self.scope.lookup(name) orelse {
        try self.logger.add(.{
            .start = node.start,
            .end = node.end,
            .kind = .{ .SemaError = .UnknownIdentifier },
            .message = try self.allocator.print(
                "usage of undefined identifier '{s}'",
                .{name},
            ),
            .help = if (try self.suggestIdentifier(name)) |sug|
                try self.allocator.print("did you mean '{s}'?", .{sug})
            else
                null,
        });
        return error.SemaError;
    };

    node.ty = sym.ty;
    return sym.ty;
}

pub fn identifierDist(self: *Sema, a: []const u8, b: []const u8) !usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    const cols = b.len + 1;
    const cells = (a.len + 1) * cols;

    // allocate only if size is greater than 64
    var s_buf: [4096]usize = undefined;
    const h_buf: ?[]usize = if (cells > s_buf.len)
        try self.allocator.alloc(usize, cells)
    else
        null;
    // TODO: free? or let arena catch it?
    const mat = if (h_buf) |buf| buf else s_buf[0..cells];

    for (0..a.len + 1) |i| mat[i * cols] = i;
    for (0..b.len + 1) |i| mat[i] = i;

    for (a, 0..) |ac, i| {
        const row = i + 1;
        for (b, 0..) |bc, j| {
            const col = j + 1;
            const cost: usize = @intFromBool(std.ascii.toLower(ac) != std.ascii.toLower(bc));

            var min = @min(
                mat[(row - 1) * cols + col] + 1,
                @min(
                    mat[row * cols + (col - 1)] + 1,
                    mat[(row - 1) * cols + (col - 1)],
                ),
            );
            if (i > 0 and
                j > 0 and
                std.ascii.toLower(ac) == std.ascii.toLower(b[j - 1]) and
                std.ascii.toLower(a[i - 1]) == std.ascii.toLower(bc))
            {
                min = @min(min, mat[(row - 2) * cols + (col - 2)] + cost);
            }

            mat[row * cols + col] = min;
        }
    }

    return mat[a.len * cols + b.len];
}

pub fn suggestIdentifier(self: *Sema, unknown: []const u8) !?[]const u8 {
    if (unknown.len < 3)
        return null;
    const max_dist: usize = @min(3, @max(1, unknown.len / 3));

    var best_name: ?[]const u8 = null;
    var best_dist: usize = max_dist + 1;

    var iter = self.scope.symbols.keyIterator();

    while (iter.next()) |name| {
        const len_diff = if (unknown.len > name.len)
            unknown.len - name.len
        else
            name.len - unknown.len;
        if (len_diff >= best_dist)
            continue;

        const dist = try self.identifierDist(unknown, name.*);
        if (dist < best_dist) {
            best_dist = dist;
            best_name = name.*;
            if (dist == 0)
                break;
        }
    }

    return best_name;
}
