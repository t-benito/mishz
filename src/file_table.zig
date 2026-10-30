pub const FileTable = @This();

const std = @import("std");

paths: std.ArrayList([]const u8),
sources: std.ArrayList([]const u8),

pub fn init(allocator: std.mem.Allocator, main_path: []const u8, main_source: []const u8) !FileTable {
    var paths = try std.ArrayList([]const u8).initCapacity(allocator, 1);
    errdefer paths.deinit(allocator);
    try paths.append(allocator, main_path);

    var sources = try std.ArrayList([]const u8).initCapacity(allocator, 1);
    errdefer paths.deinit(allocator);
    try sources.append(allocator, main_source);

    return .{
        .paths = paths,
        .sources = sources,
    };
}

pub fn deinit(self: *FileTable, allocator: std.mem.Allocator) void {
    for (self.paths.items) |i| {
        allocator.free(i);
    }
    for (self.sources.items) |i| {
        allocator.free(i);
    }
    self.paths.deinit(allocator);
    self.paths.deinit(allocator);
}

pub fn addFile(self: *FileTable, allocator: std.mem.Allocator, path: []const u8, source: []const u8) !u8 {
    try self.paths.append(allocator, path);
    try self.sources.append(allocator, source);
    return @intCast(self.paths.items.len - 1);
}

pub fn getPath(self: *const FileTable, idx: usize) []const u8 {
    return self.paths.items[idx];
}

pub fn getSource(self: *const FileTable, idx: usize) []const u8 {
    return self.sources.items[idx];
}

pub fn spanStr(self: *const FileTable, file_id: u8, start: usize, end: usize) []const u8 {
    const source = self.sources.items[file_id];
    return source[start..end];
}
