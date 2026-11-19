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
        try self.checkTop(node);
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

fn checkExpr(self: *Sema, node: *Node) !Type.Handle {
    // TODO
    _ = self;
    _ = node;
    return .i32;
}
