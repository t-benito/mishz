const std = @import("std");

pub const QbeType = enum {
    i32,
    i64,
    f32,
    f64,
    void,
    pub fn asString(self: *QbeType) u8 {
        return switch (self) {
            .i32 => "w",
            .i64 => "l",
            .f32 => "s",
            .f64 => "d",
            .void => "v",
        };
    }
};

pub const Value = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        temp,
        global,
        constant,
    };

    pub const Data = union {
        temp: u32,
        global: []const u8,
        constant: u64,
    };
};

pub const Op = enum {
    add,
    sub,
    mul,
    div,
    call,
    alloc4,
    alloc8,
    loadw,
    loadl,
    storew,
    storel,
    gt,
    lt,
    eq,
    ret,
    jmp,
    jnz,
    pub fn asString(self: *Op) []const u8 {
        return switch (self) {
            .gt => "csgtw",
            .lt => "csltw",
            .eq => "cseqw",
            else => @tagName(self),
        };
    }
};

pub const Inst = struct {
    op: Op,
};

pub const Block = struct {
    label: []const u8,
    insts: std.ArrayList(Inst),
};

pub const Function = struct {
    name: []const u8,
    ret_type: QbeType,
    params: []const struct {
        name: []const u8,
        ty: QbeType,
    },
    blocks: std.ArrayList(Block),
    next_temp: u32 = 0,

    pub fn newTemp(self: *Function) Value {
        const id = self.next_temp;
        self.next_temp += 1;
        return .{
            .temp = id,
        };
    }
};
