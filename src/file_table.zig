pub const FileTable = @This();

const std = @import("std");

paths: [256][]const u8 = undefined,
sources: [256][]const u8 = undefined,
len: u8 = 0,

pub fn init(main_path: []const u8, main_source: []const u8) FileTable {
    var self = FileTable{};
    self.paths[0] = main_path;
    self.sources[0] = main_source;
    self.len = 1;

    return self;
}

pub fn addFile(self: *FileTable, path: []const u8, source: []const u8) u8 {
    self.paths[self.len] = path;
    self.sources[self.len] = source;
    self.len += 1;
    return self.len - 1;
}

pub fn getPath(self: *const FileTable, idx: usize) []const u8 {
    return self.paths[idx];
}

pub fn getSource(self: *const FileTable, idx: usize) []const u8 {
    return self.sources[idx];
}

pub fn spanStr(self: *const FileTable, file_id: u8, start: usize, end: usize) []const u8 {
    const source = self.sources[file_id];
    return source[start..end];
}
