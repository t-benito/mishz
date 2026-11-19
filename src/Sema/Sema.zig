const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
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

const Err = error{SemaError} || Allocator.Error;

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
        .ast = &file_table.asts[file].?,
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
}

pub fn precheckTop(self: *Sema, node: *Node) Err!void {
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
        else => unreachable, // TODO
    }
}
