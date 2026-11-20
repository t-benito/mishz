const std = @import("std");
const Allocator = std.mem.Allocator;
const maxInt = std.math.maxInt;

const Token = @import("lex.zig").Token;
const Ast = @import("Ast.zig");
const typet = @import("Sema/Type.zig");
const Type = typet.Type;
const TypePool = typet.TypePool;

pub const FileTable = @This();
/// A handle (index) to a file, limit defined by `arr_len`
pub const Handle = u32;

// TODO: is this still even needed?
pub const arr_len = maxInt(Handle) + 1;

pub const File = struct {
    path: []const u8,
    source: []const u8,
    ast: ?Ast = null,
};

files: std.MultiArrayList(File) = .empty,

pmap: std.StringHashMapUnmanaged(Handle) = .empty,
types: std.ArrayList(Type) = .empty,
type_pool: TypePool,

len: Handle = 0,
gpa: Allocator,

pub fn init(gpa: Allocator, main_path: []const u8, main_source: []const u8) Allocator.Error!FileTable {
    var self = FileTable{
        .gpa = gpa,
        .type_pool = .init(gpa),
    };
    try self.files.append(gpa, File{
        .path = main_path,
        .source = main_source,
    });

    self.len = 1;
    return self;
}

pub fn addFile(self: *FileTable, file: File) !Handle {
    try self.pmap.put(self.gpa, file.path, self.len);
    try self.files.append(self.gpa, file);
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
    return self.types.items[@intCast(@backingInt(idx))];
}

pub fn getPath(self: *const FileTable, idx: Handle) []const u8 {
    std.debug.assert(idx < arr_len);
    return self.files.get(idx).path;
}

pub fn fromPath(self: *const FileTable, path: []const u8) ?Handle {
    return self.pmap.get(path);
}

pub fn getSource(self: *const FileTable, idx: Handle) []const u8 {
    std.debug.assert(idx < arr_len);
    return self.files.get(idx).source;
}

pub fn spanStr(self: *const FileTable, file_id: Handle, start: usize, end: usize) []const u8 {
    const source = self.getSource(file_id);
    return source[start..end];
}

pub fn tokenStr(self: *const FileTable, token: Token, file: Handle) []const u8 {
    std.debug.assert(file < arr_len);
    const source = self.getSource(file);
    return source[token.start..token.end];
}

pub fn tokenHStr(self: *const FileTable, token_handle: Token.Handle, file: Handle) []const u8 {
    std.debug.assert(file < arr_len);
    std.debug.assert(self.files.items(.ast)[file] != null);
    const tokens: []Token = self.files.items(.ast)[file].?.tokens;
    const token = tokens[token_handle];
    const source = self.getSource(file);
    return source[token.start..token.end];
}
