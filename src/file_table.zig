pub const FileTable = @This();
pub const FileHandle = u8;

const Ast = @import("ast.zig").Ast;
const std = @import("std");
const maxInt = std.math.maxInt;

pub const arr_len = maxInt(FileHandle) + 1;

paths: [arr_len][]const u8 = undefined,
pmap: std.StringHashMapUnmanaged(FileHandle) = .empty,

sources: [arr_len][]const u8 = undefined,
asts: [arr_len]?Ast = @splat(null),
len: FileHandle = 0,

gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, main_path: []const u8, main_source: []const u8) !FileTable {
    var self = FileTable{ .gpa = gpa };
    self.paths[0] = main_path;
    try self.pmap.ensureTotalCapacity(gpa, arr_len);

    self.sources[0] = main_source;
    self.len = 1;
    return self;
}

pub fn addFile(self: *FileTable, path: []const u8, source: []const u8) !FileHandle {
    self.paths[self.len] = path;
    try self.pmap.put(self.gpa, path, self.len);
    self.sources[self.len] = source;
    self.asts[self.len] = null;
    self.len += 1;
    return self.len - 1;
}

pub fn getPath(self: *const FileTable, idx: FileHandle) []const u8 {
    return self.paths[idx];
}

pub fn fromPath(self: *const FileTable, path: []const u8) ?FileHandle {
    return self.pmap.get(path);
}

pub fn getSource(self: *const FileTable, idx: FileHandle) []const u8 {
    return self.sources[idx];
}

pub fn spanStr(self: *const FileTable, file_id: FileHandle, start: usize, end: usize) []const u8 {
    const source = self.sources[file_id];
    return source[start..end];
}
