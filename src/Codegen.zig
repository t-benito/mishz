const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const ProgNode = std.Progress.Node;

const qbe = @import("qbe");
const Fn = qbe.Function;
const Block = qbe.Block;
const Module = qbe.Module;
const Linkage = qbe.Linkage;
const Arg = qbe.Argument;
const Value = qbe.Value;
const Stmt = qbe.Statement;
const Instr = qbe.Instr;
const TypeDef = qbe.TypeDef;

const layoutt = @import("layout.zig");
const Field = layoutt.Field;
const Struct = layoutt.Struct;
const StructDef = layoutt.Struct.Def;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const FileTable = @import("FileTable.zig");
const FileHandle = FileTable.Handle;
const Token = @import("lex.zig").Token;
const typet = @import("Type.zig");
const Type = typet.Type;

pub const Codegen = @This();

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
mod: Module,
pub_link: Linkage,
priv_link: Linkage,
file_table: *FileTable,
file: FileHandle,
globals: ArrayList([]const u8),

prev: *ProgNode,

/// Shorthand for `self.file_table.asts[self.file]`
ast: *const Ast,

pointer_width: qbe.Type = .long,
slice_def: ?StructDef = null,

temp_counter: usize = 0,

pub fn init(
    allocator: Allocator,
    writer: *std.Io.Writer,
    root: *ProgNode,
    file_table: *FileTable,
    file: FileHandle,
) !Codegen {
    return Codegen{
        .allocator = allocator,
        .writer = writer,
        .mod = .init(allocator),
        .pub_link = .public(),
        .priv_link = .private(),
        .file_table = file_table,
        .file = file,
        .globals = ArrayList([]const u8).initCapacity(allocator, 25) catch ArrayList([]const u8).empty,
        .prev = root,
        .ast = undefined,
    };
}

pub fn run(self: *Codegen) !void {
    try self.emitPre();
    for (self.file_table.asts) |maybeast| {
        if (maybeast == null)
            continue;
        self.ast = &maybeast.?;

        for (maybeast.?.nodes) |node| {
            try self.emitTopLevel(node, false);
            self.temp_counter = 0;
        }
    }
    var format_node = self.prev.start("Qbe Format", 0);
    try self.mod.format(self.writer);
    try self.writer.flush();
    format_node.end();
}

pub fn emitPre(self: *Codegen) !void {
    self.slice_def = try .init(
        self.allocator,
        &self.mod,
        "___.slice",
        &.{
            .{ .name = "ptr", .ty = self.pointer_width },
            .{ .name = "len", .ty = self.pointer_width },
        },
    );
}

pub fn mangleFnName(self: *Codegen, node: *Node) ![]const u8 {
    const start = self.ast.tokens[node.data.fn_stmt.name].start;
    const end = self.ast.tokens[node.data.fn_stmt.name].end;
    const name = self.file_table.spanStr(
        node.file,
        start,
        end,
    );
    return if (node.file == 0)
        name
    else
        try self.allocator.print("___.f{}.{s}", .{ node.file, name });
}

pub fn emitTopLevel(self: *Codegen, node: *Node, public: bool) !void {
    switch (node.tag) {
        .fn_stmt => try self.emitFn(node, public),
        .pub_stmt => try self.emitTopLevel(node.data.pub_stmt.stmt, true), // TODO: why is there a seg fault?
        .import,
        .import_collection,
        => {}, // skip
        else => unreachable, // TODO
    }
}

pub fn emitFn(self: *Codegen, node: *Node, public: bool) !void {
    const fun = &node.data.fn_stmt;

    var args = try ArrayList(Arg).initCapacity(
        self.allocator,
        fun.params.len,
    );
    for (fun.params) |param| {
        const arg = Arg{
            .ty = self.qbeType(param.ty.?).?,
            .val = .{
                .temporary = self.file_table.spanStr(
                    param.file,
                    param.start,
                    param.end,
                ),
            },
        };
        try args.append(self.allocator, arg);
    }
    const qbe_type = self.qbeType(node.ty.?);

    const qbe_fn = try self.mod.addFunction(Fn.init(
        if (public) self.pub_link else self.priv_link,
        try self.mangleFnName(node),
        try args.toOwnedSlice(self.allocator),
        qbe_type,
        self.allocator,
    ));

    var start_block = try qbe_fn.addBlock("entry");
    for (fun.body) |stmt| {
        try self.emitStmt(stmt, qbe_fn);
    }
    if (qbe_type == null)
        try start_block.addInstr(.{ .ret = null });
}

pub fn emitStmt(self: *Codegen, node: *Node, fun: *Fn) !void {
    switch (node.tag) {
        .let_stmt,
        .let_mut_stmt,
        => try self.emitLet(node, fun),
        .if_stmt,
        => try self.emitIf(node, fun),
        else => unreachable, // TODO
    }
}

pub fn emitLet(self: *Codegen, node: *Node, fun: *Fn) !void {
    const let = &node.data.let_stmt;
    const name = self.file_table.spanStr(
        self.ast.tokens[let.name].file,
        self.ast.tokens[let.name].start,
        self.ast.tokens[let.name].end,
    );
    const block = try fun.lastBlock();

    const v = Value{ .temporary = name };
    try block.assignInstr(
        v,
        self.qbeType(node.ty.?).?,
        if (let.val) |val|
            try self.emitExpr(val, block)
        else
            .{
                .copy = .{
                    .@"const" = 0,
                },
            },
    );
}

pub fn emitIf(self: *Codegen, node: *Node, fun: *Fn) !void {
    const @"if" = &node.data.if_stmt;

    const block = try fun.lastBlock();
    const temp = try self.nextTemp();

    try block.assignInstr(
        temp,
        self.qbeType(@"if".cond.ty.?).?,
        try self.emitExpr(@"if".cond, block),
    );

    const then_b = try self.nextBlock(fun);
    const else_b = try self.nextBlock(fun);

    try block.addInstr(.{
        .jnz = .{
            .cond = temp,
            .non_zero = then_b.label,
            .zero = else_b.label,
        },
    });
}

pub fn nextTemp(self: *Codegen) !Value {
    const name = try self.allocator.print("___.t{d}", .{self.temp_counter});
    self.temp_counter += 1;
    return .{ .temporary = name };
}

pub fn nextBlock(self: *Codegen, fun: *Fn) !*Block {
    const name = try self.allocator.print("b{d}", .{self.temp_counter});
    self.temp_counter += 1;
    return fun.addBlock(name);
}

pub fn qbeType(_: *Codegen, ty: Type.Handle) ?qbe.Type {
    return switch (ty) {
        .i8 => .signed_byte,
        .u8 => .unsigned_byte,
        .i16 => .signed_halfword,
        .u16 => .unsigned_halfword,
        .i32, .u32, .bool => .word,
        .i64, .u64 => .long,
        .f32 => .single,
        .f64 => .double,
        .void => null,
        else => unreachable, // TODO: aggregate types
    };
}

pub fn emitExpr(self: *Codegen, node: *Node, block: *Block) !Instr {
    switch (node.tag) {
        .identifier => {
            const name = self.file_table.spanStr(
                node.file,
                node.start,
                node.end,
            );
            return .{
                .copy = .{ .temporary = name },
            };
        },
        .integer => {
            const str_int = self.file_table.spanStr(
                node.file,
                node.start,
                node.end,
            );
            const int = try std.fmt.parseInt(i64, str_int, 0);
            return .{
                .copy = .{ .@"const" = @bitCast(int) },
            };
        },
        .string => {
            const str = try self.slice_def.?.@"struct".stackAlloc(self, block);
            return .{ .copy = str }; // TODO
        },
        .binary_op_add => {
            const bop = &node.data.binary_op;

            const lhs = try self.nextTemp();
            const ty = self.qbeType(bop.left.ty.?).?;

            try block.assignInstr(
                lhs,
                ty,
                try self.emitExpr(bop.left, block),
            );

            const rhs = try self.nextTemp();
            try block.assignInstr(
                rhs,
                ty,
                try self.emitExpr(bop.right, block),
            );

            const dst = try self.nextTemp();
            try block.assignInstr(dst, ty, .{
                .add = .{
                    .lhs = lhs,
                    .rhs = rhs,
                },
            });
            return Instr{ .copy = dst };
        },
        else => unreachable, // TODO
    }
    return .{ .copy = .{ .@"const" = 1 } };
}
