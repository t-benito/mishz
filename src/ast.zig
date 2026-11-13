const std = @import("std");
const Token = @import("lex.zig").Token;
const ft = @import("file_table.zig");
const FileHandle = ft.FileHandle;
const FileTable = ft.FileTable;

pub const Tag = enum {
    integer,
    string,
    false,
    true,
    null,
    identifier,
    builtin,
    property_access,
    array_access,
    binary_op_add,
    binary_op_sub,
    binary_op_mul,
    binary_op_div,
    binary_op_eq,
    binary_op_not_eq,
    binary_op_gt,
    binary_op_lt,
    binary_op_lt_eq,
    binary_op_gt_eq,
    binary_op_bit_and,
    binary_op_bit_or,
    binary_op_bit_xor,
    binary_op_bit_not,
    binary_op_bit_left,
    binary_op_bit_right,
    unary_op_at,
    unary_op_neg,
    unary_op_not,
    unary_op_decr,
    unary_op_incr,
    assign,
    assign_add,
    assign_sub,
    assign_mul,
    assign_div,
    call,
    struct_init,
    field_init,
    block,
    let_stmt,
    let_mut_stmt,
    fn_stmt,
    param,
    ret_stmt,
    if_stmt,
    for_stmt,
    struct_stmt,
    struct_field,
    pub_stmt,
    cast,
};

pub const Data = union {
    token: Token.Handle,
    builtin: struct {
        name: Token.Handle,
        args: []*Node,
    },
    property_access: struct {
        target: *Node,
        name: Token.Handle,
    },
    array_access: struct {
        target: *Node,
        value: *Node,
    },
    binary_op: struct {
        left: *Node,
        right: *Node,
    },
    unary_op: struct {
        right: *Node,
    },
    assignment: struct {
        target: *Node,
        right: *Node,
    },
    call: struct {
        args: []*Node,
        callee: *Node,
    },
    struct_init: struct {
        name: ?*Node,
        fields: []*Node,
    },
    field_init: struct {
        name: Token.Handle,
        val: *Node,
    },
    block: struct {
        body: []*Node,
    },
    let_stmt: struct {
        ty: ?Type.Handle,
        name: Token.Handle,
        val: ?*Node,
    },
    fn_stmt: struct {
        name: Token.Handle,
        params: []*Node,
        gens: struct {
            start: Type.Handle,
            end: Type.Handle,
        },
        body: []*Node,
        returns: Type.Handle,
    },
    param: struct {
        name: Token.Handle,
        ty: Type.Handle,
    },
    ret_stmt: struct {
        val: ?*Node,
    },
    if_stmt: struct {
        cond: *Node,
        body: *Node,
        else_branch: ?*Node,
    },
    for_stmt: struct {
        vari: ?*Node,
        cond: ?*Node,
        incr: ?*Node,
        body: *Node,
    },
    struct_stmt: struct {
        name: Token.Handle,
        fields: []*Node,
    },
    struct_field: struct {
        name: Token.Handle,
        type: Type.Handle,
        @"pub": bool,
        mut: bool,
    },
    pub_stmt: struct {
        stmt: *Node,
    },
    cast: struct {
        expr: *Node,
        ty: Type.Handle,
    },
    import_stmt: struct {
        file: FileHandle,
        alias: Token.Handle,
    },
};

pub const Field = struct {
    name: []const u8,
    type: Type.Handle,
    mut: bool,
    @"pub": bool,
};

pub const Type = union(enum) {
    pub const Handle = usize;

    void,
    null,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    bool,
    func: struct {
        returns: Type.Handle,
        params_start: usize,
        params_end: usize,
    },
    ptr: Type.Handle,
    array: struct {
        ty: Type.Handle,
        len: *Node,
    },
    slice: Type.Handle,
    @"struct": struct {
        name: []const u8,
        fields: []Field,
    },
    named: struct {
        path: struct {
            start: Token.Handle,
            end: Token.Handle,
        },
        gens: ?struct {
            start: Type.Handle,
            end: Type.Handle,
        },
    },
};

pub const TypeNode = struct {
    ty: Type,
    start: usize,
    end: usize,
};

pub const Node = struct {
    data: Data,
    tag: Tag,
    start: usize,
    end: usize,
    file: FileHandle,
};

pub const Ast = @This();

tokens: []Token,
nodes: []*Node,
types: std.ArrayList(TypeNode),
file_table: *FileTable,
