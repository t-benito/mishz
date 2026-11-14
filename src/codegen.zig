const qbe = @import("qbe");
const Fn = qbe.Function;
const Block = qbe.Block;
const Module = qbe.Module;
const Linkage = qbe.Linkage;
const Arg = qbe.Argument;
const Value = qbe.Value;
const Stmt = qbe.Statement;

const std = @import("std");
const ArrayList = std.ArrayList;
const ProgNode = std.Progress.Node;

const a = @import("ast.zig");
const Ast = a.Ast;
const Node = a.Node;
const Type = a.Type;
const TypeNode = a.TypeNode;
const Token = @import("lex.zig").Token;
const ft = @import("file_table.zig");
const FileTable = ft.FileTable;
const FileHandle = ft.FileHandle;

pub const Codegen = @This();

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
mod: Module,
pub_link: Linkage,
priv_link: Linkage,
ast: *Ast,

root: *ProgNode,
current: *ProgNode,

pointer_width: qbe.Type = .long,

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, root: *ProgNode, ast: *Ast) Codegen {
    return Codegen{
        .allocator = allocator,
        .writer = writer,
        .mod = .init(allocator),
        .pub_link = .public(),
        .priv_link = .private(),
        .ast = ast,
        .root = root,
        .current = root,
    };
}

pub fn run(self: *Codegen) !void {
    for (self.ast.nodes) |node| {
        try self.emitTopLevel(node, false);
    }
    var format_node = self.root.start("Qbe format", 0);
    try self.mod.format(self.writer);
    // TODO: use qbe-zig-build to compile the qbe
    format_node.end();
}

pub fn emitTopLevel(self: *Codegen, node: *Node, public: bool) !void {
    switch (node.tag) {
        .fn_stmt => try self.emitFn(node, public),
        .pub_stmt => try self.emitTopLevel(node.data.pub_stmt.stmt, true),
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
        const pdata = &param.data.param;
        const arg = Arg{
            .ty = self.qbeType(pdata.ty),
            .val = .{
                .temporary = self.ast.file_table.spanStr(
                    param.file,
                    param.start,
                    param.end,
                ),
            },
        };
        try args.append(self.allocator, arg);
    }

    const name = fun.name;
    const qbe_fn = Fn.init(
        if (public) self.pub_link else self.priv_link,
        self.ast.file_table.spanStr(
            node.file,
            self.ast.tokens[name].start,
            self.ast.tokens[name].end,
        ),
        try args.toOwnedSlice(self.allocator),
        self.qbeType(fun.returns),
        self.allocator,
    );

    var start_block = Block.init("entry", self.allocator);
    for (fun.body) |stmt| {
        try self.emitStmt(stmt, &start_block);
    }

    _ = try self.mod.addFunction(qbe_fn);
}

pub fn emitStmt(self: *Codegen, node: *Node, block: *qbe.Block) !void {
    switch (node.tag) {
        .let_stmt,
        .let_mut_stmt,
        => try self.emitLet(node, block),
        else => unreachable, // TODO
    }
}

pub fn emitLet(self: *Codegen, node: *Node, block: *qbe.Block) !void {
    const let = &node.data.let_stmt;
    const name = self.ast.file_table.spanStr(
        self.ast.tokens[let.name].file,
        self.ast.tokens[let.name].start,
        self.ast.tokens[let.name].end,
    );
    const v = Value{ .temporary = name };
    try block.assignInstr(
        v,
        self.qbeType(let.ty.?),
        //if (let.val) |val|
        //self.getExpr(val)
        //else // TODO: FOR NOW!! temporary
        .{
            .copy = .{
                .@"const" = 0,
            },
        },
    );
}

pub fn qbeType(self: *Codegen, ty: Type.Handle) qbe.Type {
    // TODO: aggregate types
    return switch (self.ast.types.items[ty].ty) {
        .i8 => .signed_byte,
        .u8 => .unsigned_byte,
        .i16 => .signed_halfword,
        .u16 => .unsigned_halfword,
        .i32, .u32, .bool => .word,
        .i64, .u64 => .long,
        .f32 => .single,
        .f64 => .double,
        .ptr => self.pointer_width,
        .void, .null => .zero,
        else => unreachable, // TODO
    };
}
