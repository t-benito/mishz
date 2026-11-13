const std = @import("std");
const astt = @import("ast.zig");
const Node = astt.Node;

/// Writer must be flushed afterwards
pub fn printAst(nodes: []const *Node, indent: usize, writer: *std.Io.Writer) !void {
    for (nodes) |node| {
        try printIndent(indent, writer);
        try writer.print("- {s} [span {}-{}]:\n", .{ @tagName(node.tag), node.start, node.end });

        const child_indent = indent + 1;

        switch (node.tag) {
            .integer,
            .string,
            .identifier,
            => {
                try printIndent(child_indent, writer);
                try writer.print("token index: {}\n", .{node.data.token});
            },
            .builtin => {
                try printIndent(child_indent, writer);
                try writer.print("name index: {}\n", .{node.data.builtin.name});
                try printAst(node.data.builtin.args, child_indent, writer);
            },
            .cast => {
                try printIndent(child_indent, writer);
                try writer.print("type id: {}\n", .{node.data.cast.ty});
                try printAst((&node.data.cast.expr)[0..1], child_indent, writer);
            },
            .property_access => {
                try printIndent(child_indent, writer);
                try writer.print("name index: {}\n", .{node.data.property_access.name});
                try printAst((&node.data.property_access.target)[0..1], child_indent, writer);
            },
            .false, .true, .null => {},
            .array_access => {
                try printAst((&node.data.array_access.target)[0..1], child_indent, writer);
                try printAst((&node.data.array_access.value)[0..1], child_indent, writer);
            },
            .binary_op_add,
            .binary_op_sub,
            .binary_op_mul,
            .binary_op_div,
            .binary_op_eq,
            .binary_op_not_eq,
            .binary_op_gt,
            .binary_op_lt,
            .binary_op_lt_eq,
            .binary_op_gt_eq,
            .binary_op_bit_and,
            .binary_op_bit_left,
            .binary_op_bit_not,
            .binary_op_bit_or,
            .binary_op_bit_right,
            .binary_op_bit_xor,
            => {
                try printAst((&node.data.binary_op.left)[0..1], child_indent, writer);
                try printAst((&node.data.binary_op.right)[0..1], child_indent, writer);
            },
            .unary_op_at,
            .unary_op_neg,
            .unary_op_not,
            .unary_op_decr,
            .unary_op_incr,
            => {
                try printAst((&node.data.unary_op.right)[0..1], child_indent, writer);
            },
            .assign,
            .assign_add,
            .assign_sub,
            .assign_mul,
            .assign_div,
            => {
                try printAst((&node.data.assignment.target)[0..1], child_indent, writer);
                try printAst((&node.data.assignment.right)[0..1], child_indent, writer);
            },
            .call => {
                try printAst((&node.data.call.callee)[0..1], child_indent, writer);
                try printAst(node.data.call.args, child_indent, writer);
            },
            .block => {
                try printAst(node.data.block.body, child_indent, writer);
            },
            .let_stmt, .let_mut_stmt => {
                try printIndent(child_indent, writer);
                try writer.print(
                    "name index: {}",
                    .{node.data.let_stmt.name},
                );
                if (node.data.let_stmt.ty) |ty| {
                    try writer.print(
                        ", type id: {}",
                        .{ty},
                    );
                }
                try writer.writeAll("\n");

                if (node.data.let_stmt.val) |val| {
                    try printAst((&val)[0..1], child_indent, writer);
                }
            },
            .fn_stmt => {
                try printIndent(child_indent, writer);
                try writer.print(
                    "name index: {}, returns id: {}\n",
                    .{ node.data.fn_stmt.name, node.data.fn_stmt.returns },
                );

                // TODO: generics printing
                try printAst(node.data.fn_stmt.params, child_indent, writer);
                try printAst(node.data.fn_stmt.body, child_indent, writer);
            },
            .param => {
                try printIndent(child_indent, writer);
                try writer.print(
                    "name index: {}, type id: {}\n",
                    .{ node.data.param.name, node.data.param.ty },
                );
            },
            .ret_stmt => {
                if (node.data.ret_stmt.val) |val| {
                    try printAst((&val)[0..1], child_indent, writer);
                }
            },
            .if_stmt => {
                try printAst((&node.data.if_stmt.cond)[0..1], child_indent, writer);
                try printAst((&node.data.if_stmt.body)[0..1], child_indent, writer);
                if (node.data.if_stmt.else_branch) |eb| {
                    try printAst((&eb)[0..1], child_indent, writer);
                }
            },
            .for_stmt => {
                if (node.data.for_stmt.vari) |v| try printAst((&v)[0..1], child_indent, writer);
                if (node.data.for_stmt.cond) |c| try printAst((&c)[0..1], child_indent, writer);
                if (node.data.for_stmt.incr) |j| try printAst((&j)[0..1], child_indent, writer);
                try printAst((&node.data.for_stmt.body)[0..1], child_indent, writer);
            },
            .pub_stmt => {
                try printAst((&node.data.pub_stmt.stmt)[0..1], child_indent, writer);
            },
            .struct_stmt => {
                try printIndent(child_indent, writer);
                try writer.print("name index: {}\n", .{node.data.struct_stmt.name});
                try printAst(node.data.struct_stmt.fields, child_indent, writer);
            },
            .struct_field => {
                try printIndent(child_indent, writer);
                try writer.print(
                    "name index: {}, type index: {}\n",
                    .{
                        node.data.struct_field.name,
                        node.data.struct_field.type,
                    },
                );
            },
            .struct_init => {
                if (node.data.struct_init.name) |n|
                    try printAst((&n)[0..1], child_indent, writer);
                try printAst(node.data.struct_init.fields, child_indent, writer);
            },
            .field_init => {
                try printIndent(child_indent, writer);
                try writer.print("name index: {}\n", .{node.data.field_init.name});
                try printAst((&node.data.field_init.val)[0..1], child_indent, writer);
            },
        }
    }
}

fn printIndent(count: usize, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeAll("    ");
    }
}
