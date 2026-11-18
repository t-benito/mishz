const std = @import("std");
const maxInt = std.math.maxInt;

const Token = @import("lex.zig").Token;
const Ast = @import("ast.zig").Ast;
const typet = @import("type.zig");
const Type = typet.Type;
const TypePool = typet.TypePool;
const Allocator = std.mem.Allocator;

pub const FileTable = @This();
/// A handle (index) to a file, limit defined by `arr_len`
pub const Handle = u8;

pub const arr_len = maxInt(Handle) + 1;

paths: [arr_len][]const u8 = undefined,
pmap: std.StringHashMapUnmanaged(Handle) = .empty,

sources: [arr_len][]const u8 = undefined,
asts: [arr_len]?Ast = @splat(null),

types: std.ArrayList(Type) = .empty,
type_pool: TypePool,

len: Handle = 0,

gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, main_path: []const u8, main_source: []const u8) Allocator.Error!FileTable {
    var self = FileTable{ .gpa = gpa, .type_pool = .init(gpa) };
    self.paths[0] = main_path;
    try self.pmap.ensureTotalCapacity(gpa, arr_len);
    try self.types.ensureTotalCapacity(gpa, Type.Handle.Count * 5);

    self.sources[0] = main_source;
    self.len = 1;
    return self;
}

// virtual only for the function
pub const File = struct {
    path: []const u8,
    source: []const u8,
    ast: ?Ast = null,
};

pub fn addFile(self: *FileTable, file: File) !Handle {
    self.paths[self.len] = file.path;
    try self.pmap.put(self.gpa, file.path, self.len);
    self.sources[self.len] = file.source;
    self.asts[self.len] = file.ast;
    self.len += 1;
    return self.len - 1;
}

pub fn getOrAddType(self: *FileTable, ty: Type) !Type.Handle {
    if (self.type_pool.get(ty)) |old| {
        return old;
    }
    const BackingInt = @typeInfo(Type.Handle).@"enum".tag_type;
    const handle: Type.Handle = @fromBackingInt(Type.Handle.Count + @as(BackingInt, @intCast(self.types.items.len)));
    try self.types.append(self.gpa, ty);
    try self.type_pool.put(ty, handle);
    return handle;
}

pub fn getType(self: *const FileTable, idx: Type.Handle) Type {
    std.debug.assert(idx < self.types.len);
    return self.types.items[idx];
}

pub fn getPath(self: *const FileTable, idx: Handle) []const u8 {
    std.debug.assert(idx < arr_len);
    return self.paths[idx];
}

pub fn fromPath(self: *const FileTable, path: []const u8) ?Handle {
    return self.pmap.get(path);
}

pub fn getSource(self: *const FileTable, idx: Handle) []const u8 {
    std.debug.assert(idx < arr_len);
    return self.sources[idx];
}

pub fn spanStr(self: *const FileTable, file_id: Handle, start: usize, end: usize) []const u8 {
    const source = self.sources[file_id];
    return source[start..end];
}

pub fn tokenStr(self: *const FileTable, token: Token) []const u8 {
    std.debug.assert(token.file < self.len);
    const source = self.sources[token.file];
    return source[token.start..token.end];
}
