pub const FileTable = @This();

const std = @import("std");

paths: [][]const u8,
sources: [][]const u8,
len: u8 = 1,

pub fn init(allocator: std.mem.Allocator, main_path: []const u8, main_source: []const u8) !FileTable {
    var paths = try std.ArrayList([]const u8).initCapacity(allocator, 256);
    errdefer paths.deinit(allocator);
    try paths.append(allocator, main_path);

    var sources = try std.ArrayList([]const u8).initCapacity(allocator, 256);
    errdefer paths.deinit(allocator);
    try sources.append(allocator, main_source);

    return .{
        .paths = try paths.toOwnedSlice(allocator),
        .sources = try sources.toOwnedSlice(allocator),
    };
}

/// incase its ever needed
pub fn deinit(self: *FileTable, allocator: std.mem.Allocator) void {
    for (self.paths) |i| {
        allocator.free(i);
    }
    for (self.sources) |i| {
        allocator.free(i);
    }
}

pub fn addFile(self: *FileTable, _: std.mem.Allocator, path: []const u8, source: []const u8) !u8 {
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
