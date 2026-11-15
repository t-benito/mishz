pub const FileTable = @This();
pub const FileHandle = u8;

const Ast = @import("ast.zig").Ast;
const std = @import("std");
const maxInt = std.math.maxInt;

const arr_len = maxInt(FileHandle);

paths: [arr_len][]const u8 = undefined,
sources: [arr_len][]const u8 = undefined,
asts: [arr_len]?Ast = undefined,
len: FileHandle = 0,

pub fn init(main_path: []const u8, main_source: []const u8) FileTable {
    var self = FileTable{};
    self.paths[0] = main_path;
    self.sources[0] = main_source;
    self.asts[0] = null;
    self.len = 1;

    return self;
}

pub fn addFile(self: *FileTable, path: []const u8, source: []const u8) FileHandle {
    self.paths[self.len] = path;
    self.sources[self.len] = source;
    self.asts[self.len] = null;
    self.len += 1;
    return self.len - 1;
}

pub fn getPath(self: *const FileTable, idx: FileHandle) []const u8 {
    return self.paths[idx];
}

pub fn fromPath(self: *const FileTable, path: []const u8) ?FileHandle {
    const idx = std.mem.find([]const u8, self.paths, &.{path}) orelse return null;
    return @intCast(idx);
}

pub fn getSource(self: *const FileTable, idx: FileHandle) []const u8 {
    return self.sources[idx];
}

pub fn spanStr(self: *const FileTable, file_id: FileHandle, start: usize, end: usize) []const u8 {
    const source = self.sources[file_id];
    return source[start..end];
}
