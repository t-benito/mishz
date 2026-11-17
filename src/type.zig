const std = @import("std");
const mem = std.mem;
const Wyhash = std.hash.Wyhash;
const Tag = std.meta.Tag;

const ast = @import("ast.zig");
const Node = ast.Node;
const Token = @import("lex.zig").Token;

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
    generics: ?struct {
        start: Type.Handle,
        end: Type.Handle,
    },
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
                h.update(mem.asBytes(&f.params));

                return h.final();
            },
            .@"struct", .named => Wyhash.hash(tag, mem.asBytes(&key)),
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
        };
    }
};

pub const TypePool = std.HashMap(Type, Type.Handle, TypeContext, std.hash_map.default_max_load_percentage);
