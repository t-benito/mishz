const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Writer = std.Io.Writer;
const Wyhash = std.hash.Wyhash;
const Tag = std.meta.Tag;

const ast = @import("../Ast.zig");
const Node = ast.Node;
const Token = @import("../lex.zig").Token;
const FileTable = @import("../FileTable.zig");

pub const Type = union(enum) {
    pub const Handle = enum(u32) {
        pub const Count = 12;

        i8 = 0,
        i16 = 1,
        i32 = 2,
        i64 = 3,
        u8 = 4,
        u16 = 5,
        u32 = 6,
        u64 = 7,
        f32 = 8,
        f64 = 9,
        bool = 10,
        void = 11,

        _,

        pub inline fn isInt(self: Handle) bool {
            // 8 = f32, before that is only uint and int
            return @backingInt(self) <= 7;
        }

        pub inline fn isSigned(self: Handle) bool {
            // 4 = u8, before that is int
            return @backingInt(self) <= 3;
        }

        pub inline fn isUnsigned(self: Handle) bool {
            const val = @backingInt(self);
            // 3 = i64, f32 = 8
            return val >= 4 and val <= 7;
        }

        pub inline fn isFloat(self: Handle) bool {
            const val = @backingInt(self);
            // 8 = f32, 9 = f64
            return val == 8 or val == 9;
        }

        /// Returns if the handle is either a float, unsigned or signed int
        pub inline fn isNum(self: Handle) bool {
            return @backingInt(self) <= 9;
        }

        pub inline fn isCompound(self: Handle) bool {
            return @backingInt(self) >= 12;
        }

        pub fn primitiveName(self: Handle) ?[]const u8 {
            if (self.isCompound())
                return null;
            return @tagName(self);
        }

        pub fn writeName(
            self: Handle,
            file_table: *const FileTable,
            writer: *Writer,
        ) !void {
            if (self.primitiveName()) |prim| {
                try writer.writeAll(prim);
                return;
            }

            const ty = file_table.getType(self);
            switch (ty) {
                .ptr => |p| {
                    try writer.writeByte('*');
                    try p.inner.writeName(file_table, writer);
                },
                .slice => |s| {
                    try writer.writeAll("[]");
                    try s.inner.writeName(file_table, writer);
                },
                .array => |a| {
                    try writer.print("[{}]", .{a.length});
                    try a.inner.writeName(file_table, writer);
                },
                .@"struct" => |st| try writer.writeAll(st.name),
                .named, .@"fn" => unreachable, // TODO
            }
        }

        pub fn allocName(
            self: Handle,
            file_table: *const FileTable,
            allocator: Allocator,
        ) ![]const u8 {
            var list = try std.ArrayList(u8).initCapacity(allocator, 24);
            var wr = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
            defer wr.deinit();

            const writer = &wr.writer;
            try self.writeName(file_table, writer);

            list = wr.toArrayList();
            return list.toOwnedSlice(allocator);
        }
    };

    @"fn": FnType,
    ptr: PtrType,
    array: ArrayType,
    slice: SliceType,
    @"struct": StructType,
    named: NamedType,
};

pub const FnType = struct {
    return_type: Type.Handle,
    params: []const Type.Handle,
};

pub const PtrType = struct {
    inner: Type.Handle,
};

pub const ArrayType = struct {
    inner: Type.Handle,
    length: *Node,
};

pub const SliceType = struct {
    inner: Type.Handle,
};

pub const StructType = struct {
    pub const Field = struct {
        name: []const u8,
        type: Type.Handle,
        mut: bool,
        @"pub": bool,
    };

    name: []const u8,
    fields: []Field,
};

pub const NamedType = struct {
    path: struct {
        start: Token.Handle,
        end: Token.Handle,
    },
    generics: []const Type.Handle = &.{},
};

const TypeContext = struct {
    const Self = @This();

    pub fn hash(_: Self, key: Type) u64 {
        const tag = @backingInt(@as(Tag(Type), key));

        return switch (key) {
            .ptr => |p| Wyhash.hash(tag, mem.asBytes(&p.inner)),
            .slice => |s| Wyhash.hash(tag, mem.asBytes(&s.inner)),
            .array => |a| Wyhash.hash(tag, mem.asBytes(&a.inner)),
            .@"fn" => |f| {
                var h = Wyhash.init(tag);

                h.update(mem.asBytes(&f.return_type));
                h.update(mem.sliceAsBytes(f.params));

                return h.final();
            },
            .@"struct",
            .named,
            => Wyhash.hash(tag, mem.asBytes(&key)),
        };
    }

    pub fn eql(_: Self, a: Type, b: Type) bool {
        if (@as(Tag(Type), a) != @as(Tag(Type), b))
            return false;
        return switch (a) {
            .ptr => |p| p.inner == b.ptr.inner,
            .slice => |s| s.inner == b.slice.inner,
            .array => |arr| arr.inner == b.array.inner and arr.length == b.array.length,
            .@"fn" => |f| f.return_type == b.@"fn".return_type and std.mem.eql(Type.Handle, f.params, b.@"fn".params),
            .@"struct",
            .named,
            => false,
        };
    }
};

pub const TypePool = std.HashMap(Type, Type.Handle, TypeContext, std.hash_map.default_max_load_percentage);
