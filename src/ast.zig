const std = @import("std");

const ft = @import("file_table.zig");
const FileHandle = ft.FileHandle;
const FileTable = ft.FileTable;
const Token = @import("lex.zig").Token;
const Type = @import("type.zig").Type;

pub const SourceHandle = u32;

pub const Tag = enum {
    integer,
    string,
    false,
    true,
    /// only exists because i, benito, want to get a working version out faster
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
    import,
    import_collection, // block
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
    },
    param: struct {
        name: Token.Handle,
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
        @"pub": bool,
        mut: bool,
    },
    pub_stmt: struct {
        stmt: *Node,
    },
    cast: struct {
        expr: *Node,
    },
    import_stmt: struct {
        file: FileHandle,
        alias: Token.Handle,
    },
};

pub const Node = struct {
    data: Data,
    tag: Tag,
    start: SourceHandle,
    end: SourceHandle,
    file: FileHandle,
    ty: ?Type.Handle = null,
};

test "sizes" {
    // run at compile
    comptime {
        // heavy, but, it gets the job done
        try std.testing.expect(@sizeOf(Token) == 12);
        try std.testing.expect(@sizeOf(Node) == 80);

        try std.testing.expect(@sizeOf(Ast) == 32);
    }
}

pub const Ast = @This();

tokens: []Token,
nodes: []*Node,
