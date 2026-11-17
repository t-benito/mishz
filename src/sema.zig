const std = @import("std");

const Ast = @import("ast.zig");
const Node = Ast.Node;
const Data = Ast.Data;
const Tag = Ast.Tag;
const err = @import("error.zig");
const ErrorLogger = err.ErrorLogger;
const Error = err.Error;
const Note = err.Note;
const FileTable = @import("file_table.zig");
const FileHandle = FileTable.FileHandle;
const lex = @import("lex.zig");
const Token = lex.Token;
const typet = @import("type.zig");
const Type = typet.Type;

pub const SemaError = enum(u8) {
    MismatchedTypes = 0,
};

pub const Checker = @This();
