const std = @import("std");
const parse = @import("parse.zig");
const Node = parse.Node;

pub fn printAst(nodes: []const *Node, indent: usize) void {
    for (nodes) |node| {
        printIndent(indent);
        std.debug.print("- {s} [span {}-{}]:\n", .{ @tagName(node.tag), node.start, node.end });

        const child_indent = indent + 1;

        switch (node.tag) {
            .integer, .string, .identifier => {
                printIndent(child_indent);
                std.debug.print("token_index: {}\n", .{node.data.token});
            },
            .builtin => {
                printIndent(child_indent);
                std.debug.print("name_token_index: {}\n", .{node.data.builtin.name});
                printAst(node.data.builtin.args, child_indent);
            },
            .cast => {
                printIndent(child_indent);
                std.debug.print("type_id: {}\n", .{node.data.cast.ty});
                printAst((&node.data.cast.expr)[0..1], child_indent);
            },
            .property_access => {
                printIndent(child_indent);
                std.debug.print("name_token_index: {}\n", .{node.data.property_access.name});
                printAst((&node.data.property_access.target)[0..1], child_indent);
            },
            ._false, ._true, ._null => {},
            .array_access => {
                printAst((&node.data.array_access.target)[0..1], child_indent);
                printAst((&node.data.array_access.value)[0..1], child_indent);
            },
            .binary_op_add, .binary_op_sub, .binary_op_mul, .binary_op_div, .binary_op_eq, .binary_op_not_eq, .binary_op_gt, .binary_op_lt, .binary_op_lt_eq, .binary_op_gt_eq => {
                printAst((&node.data.binary_op.left)[0..1], child_indent);
                printAst((&node.data.binary_op.right)[0..1], child_indent);
            },
            .unary_op_at, .unary_op_neg, .unary_op_not, .unary_op_decr, .unary_op_incr => {
                printAst((&node.data.unary_op.right)[0..1], child_indent);
            },
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div => {
                printAst((&node.data.assignment.target)[0..1], child_indent);
                printAst((&node.data.assignment.right)[0..1], child_indent);
            },
            .call => {
                printAst((&node.data.call.callee)[0..1], child_indent);
                printAst(node.data.call.args, child_indent);
            },
            .block => {
                printAst(node.data.block.body, child_indent);
            },
            .var_stmt => {
                printIndent(child_indent);
                std.debug.print("name_token_index: {}, type_id: {}\n", .{ node.data.var_stmt.name, node.data.var_stmt.ty });
                if (node.data.var_stmt.val) |val| {
                    printAst((&val)[0..1], child_indent);
                }
            },
            .fn_stmt => {
                printIndent(child_indent);
                std.debug.print("name_token_index: {}, returns_type_id: {}\n", .{ node.data.fn_stmt.name, node.data.fn_stmt.returns });

                if (node.data.fn_stmt.params) |params| {
                    printAst(params, child_indent);
                }
                printAst(node.data.fn_stmt.body, child_indent);
            },
            .param => {
                printIndent(child_indent);
                std.debug.print("name_token_index: {}, type_id: {}\n", .{ node.data.param.name, node.data.param.ty });
            },
            .ret_stmt => {
                if (node.data.ret_stmt.val) |val| {
                    printAst((&val)[0..1], child_indent);
                }
            },
            .if_stmt => {
                printAst((&node.data.if_stmt.cond)[0..1], child_indent);
                printAst(node.data.if_stmt.body, child_indent);
                if (node.data.if_stmt.else_branch) |eb| {
                    printAst((&eb)[0..1], child_indent);
                }
            },
            .for_stmt => {
                if (node.data.for_stmt.vari) |v| printAst((&v)[0..1], child_indent);
                if (node.data.for_stmt.cond) |c| printAst((&c)[0..1], child_indent);
                if (node.data.for_stmt.incr) |j| printAst((&j)[0..1], child_indent);
                printAst((&node.data.for_stmt.body)[0..1], child_indent);
            },
            .pub_stmt => {
                printAst((&node.data.pub_stmt.stmt)[0..1], child_indent);
            },
            // .class_stmt => {
            //     printIndent(child_indent);
            //     std.debug.print("name_token_index: {}\n", .{node.data.class_stmt.name});
            //     printAst(node.data.class_stmt.fields, child_indent);
            // },
            .struct_stmt => {
                printIndent(child_indent);
                std.debug.print("name_token_index: {}\n", .{node.data.struct_stmt.name});
                printAst(node.data.struct_stmt.fields, child_indent);
            },
            .struct_init => {
                if (node.data.struct_init.name) |n|
                    printAst((&n)[0..1], child_indent);
                printAst(node.data.struct_init.fields, child_indent);
            },
            .field_init => {
                printIndent(child_indent);
                std.debug.print("name_token_index: {}\n", .{node.data.field_init.name});
                printAst((&node.data.field_init.val)[0..1], child_indent);
            }
        }
    }
}

fn printIndent(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        std.debug.print("  ", .{});
    }
}
