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

pub const SemaError = enum(u8) {
    MismatchedTypes = 0,
};

pub const Sema = @This();

allocator: Allocator,
writer: *Io.Writer,

file_table: *FileTable,
file: FileHandle,
prev: *const ProgNode,

pub fn init(allocator: Allocator, writer: *Io.Writer, file_table: *FileTable, file: FileHandle, root: *const ProgNode) Sema {
    return Sema{
        .allocator = allocator,
        .writer = writer,
        .file_table = file_table,
        .file = file,
        .prev = root,
    };
}

pub fn run(self: *Sema) !void {
    _ = self;
}
