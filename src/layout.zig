const qbe = @import("qbe");
const Value = qbe.Value;
const Instr = qbe.Instr;
const Block = qbe.Block;
const TypeDef = qbe.TypeDef;
const Codegen = @import("Codegen.zig");
const std = @import("std");

pub const Field = struct {
    name: []const u8,
    ty: qbe.Type,
    offset: usize,
};

pub const Struct = struct {
    name: []const u8,
    fields: []const Field,
    size: u64,
    @"align": u64,

    pub const PrimField = struct {
        name: []const u8,
        ty: qbe.Type,
    };

    pub const Def = struct {
        @"struct": Struct,
        typedef: *TypeDef,

        pub fn init(allocator: std.mem.Allocator, mod: *qbe.Module, name: []const u8, p_fields: []const PrimField) !Def {
            const items = try allocator.alloc(qbe.TypeDef.Item, p_fields.len);
            for (p_fields, 0..) |f, i| {
                items[i] = .{
                    .ty = f.ty,
                    .repeat = 1,
                };
            }
            const @"struct" = try Struct.init(allocator, name, p_fields);
            return Def{
                .@"struct" = @"struct",
                .typedef = try mod.addType(TypeDef{
                    .name = name,
                    .items = items,
                    .@"align" = @"struct".@"align",
                }),
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, p_fields: []const PrimField) !Struct {
        var fields = try allocator.alloc(Field, p_fields.len);
        var offset: u64 = 0;
        var max_align: u64 = 0;

        for (p_fields, 0..) |field, i| {
            const alignment = field.ty.size();
            max_align = @max(max_align, alignment);

            offset = std.mem.alignForward(usize, offset, alignment);
            fields[i] = Field{
                .name = field.name,
                .ty = field.ty,
                .offset = offset,
            };
        }

        return Struct{
            .name = name,
            .fields = fields,
            .size = std.mem.alignForward(usize, offset, max_align),
            .@"align" = max_align,
        };
    }

    pub fn fieldByName(self: Struct, name: []const u8) ?Field {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name))
                return f;
        }
        return null;
    }

    pub fn stackAlloc(self: Struct, cg: *Codegen, block: *Block) !Value {
        const dst = try cg.nextTemp();

        if (self.@"align" <= 16) {
            const instr: Instr = if (self.@"align" == 16)
                .{ .alloc16 = @intCast(self.size) }
            else if (self.@"align" == 8)
                .{ .alloc8 = self.size }
            else
                .{ .alloc4 = @intCast(self.size) };
            try block.assignInstr(dst, cg.pointer_width, instr);
            return dst;
        }
        const mask = self.@"align" - 1;
        const r = try cg.nextTemp();
        const b = try cg.nextTemp();

        try block.assignInstr(r, cg.pointer_width, .{
            .alloc16 = self.size + mask,
        });
        try block.assignInstr(b, cg.pointer_width, .{
            .add = .{
                .lhs = r,
                .rhs = .{ .@"const" = mask },
            },
        });
        try block.assignInstr(dst, cg.pointer_width, .{
            .@"and" = .{
                .lhs = b,
                .rhs = .{ .@"const" = ~mask },
            },
        });
        return dst;
    }

    pub fn fieldPtr(self: Struct, cg: *Codegen, block: *Block, base: Value, name: []const u8) !Value {
        const field = self.fieldByName(name) orelse return error.FieldNotFound;
        if (field.offset == 0)
            return base;
        const ptr = try cg.nextTemp();
        try block.assignInstr(ptr, cg.pointer_width, .{
            .add = .{ base, .{ .@"const" = field.offset } },
        });
        return ptr;
    }

    pub fn setField(self: Struct, cg: *Codegen, block: *Block, base: Value, val: Value, name: []const u8) !Value {
        const field = self.fieldByName(name) orelse return error.FieldNotFound;
        const ptr = try self.fieldPtr(cg, block, base, name);

        switch (field.ty) {
            .aggregate => {
                try block.addInstr(.{
                    .blit = .{ .src = val, .dest = ptr, .n = field.ty.size() },
                });
            },
            else => {
                try block.addInstr(.{
                    .store = .{ .ty = field.ty, .val = val, .dest = ptr },
                });
            },
        }
    }

    pub fn getField(self: Struct, cg: *Codegen, block: *Block, base: Value, name: []const u8) !Value {
        const field = self.fieldByName(name) orelse return error.FieldNotFound;
        const ptr = try self.fieldPtr(cg, block, base, name);

        switch (field.ty) {
            .aggregate => return ptr,
            else => {
                const out = try cg.nextTemp();
                const load: qbe.Type = switch (field.ty) {
                    .byte, .halfword => .word,
                    else => field.ty,
                };
                try block.assignInstr(out, load, .{
                    .load = .{ .ty = field.ty, .src = ptr },
                });
                return out;
            },
        }
    }

    pub fn copy(self: Struct, block: *Block, src: Value, dest: Value) !void {
        if (self.size == 0)
            return;
        try block.addInstr(.{
            .blit = .{ .src = src, .dest = dest, .n = self.size },
        });
    }
};
