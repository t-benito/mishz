const std = @import("std");
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const FileTable = @import("FileTable.zig");

/// Writer must be flushed afterwards
pub fn printAst(file_table: *const FileTable, nodes: []const *Node, indent: usize, writer: *std.Io.Writer) !void {
    for (nodes) |node| {
        try printIndent(indent, writer);
        try writer.print(" | {s} {}-{}:\n", .{ @tagName(node.tag), node.start, node.end });

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
                try printAst(file_table, node.data.builtin.args, child_indent, writer);
            },
            .cast => {
                try printIndent(child_indent, writer);
                try writer.writeAll("type: ");
                try node.getTy().writeName(file_table, writer);
                try writer.writeByte('\n');
                try printAst(file_table, (&node.data.cast.expr)[0..1], child_indent, writer);
            },
            .property_access => {
                try printIndent(child_indent, writer);
                try writer.print("name index: {}\n", .{node.data.property_access.name});
                try printAst(file_table, (&node.data.property_access.target)[0..1], child_indent, writer);
            },
            .false, .true => {},
            .array_access => {
                try printAst(file_table, (&node.data.array_access.target)[0..1], child_indent, writer);
                try printAst(file_table, (&node.data.array_access.value)[0..1], child_indent, writer);
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
                try printAst(file_table, (&node.data.binary_op.left)[0..1], child_indent, writer);
                try printAst(file_table, (&node.data.binary_op.right)[0..1], child_indent, writer);
            },
            .unary_op_at,
            .unary_op_neg,
            .unary_op_not,
            .unary_op_decr,
            .unary_op_incr,
            => {
                try printAst(file_table, (&node.data.unary_op.right)[0..1], child_indent, writer);
            },
            .assign,
            .assign_add,
            .assign_sub,
            .assign_mul,
            .assign_div,
            => {
                try printAst(file_table, (&node.data.assignment.target)[0..1], child_indent, writer);
                try printAst(file_table, (&node.data.assignment.right)[0..1], child_indent, writer);
            },
            .call => {
                try printAst(file_table, (&node.data.call.callee)[0..1], child_indent, writer);
                try printAst(file_table, node.data.call.args, child_indent, writer);
            },
            .import => {
                try printIndent(child_indent, writer);
                try writer.print("file index: {}, alias index: {}\n", .{ node.data.import_stmt.file, node.data.import_stmt.alias });
            },
            .block, .import_collection => {
                try printAst(file_table, node.data.block.body, child_indent, writer);
            },
            .let_stmt, .let_mut_stmt => {
                try printIndent(child_indent, writer);
                try writer.print(
                    "name index: {}",
                    .{node.data.let_stmt.name},
                );
                if (node.ty) |ty| {
                    try writer.writeAll(", type: ");
                    try ty.writeName(file_table, writer);
                }
                try writer.writeAll("\n");

                try printAst(file_table, (&node.data.let_stmt.val)[0..1], child_indent, writer);
            },
            .fn_stmt => {
                try printIndent(child_indent, writer);
                try writer.print("name index: {}, returns: ", .{node.data.fn_stmt.name});
                try node.getTy().writeName(file_table, writer);
                try writer.writeByte('\n');

                // TODO: generics printing
                try printAst(file_table, node.data.fn_stmt.params, child_indent, writer);
                try printAst(file_table, node.data.fn_stmt.body, child_indent, writer);
            },
            .param => {
                try printIndent(child_indent, writer);
                try writer.print(
                    "name index: {}, type: ",
                    .{node.data.param.name},
                );
                try node.getTy().writeName(file_table, writer);
                try writer.writeByte('\n');
            },
            .ret_stmt => {
                if (node.data.ret_stmt.val) |val| {
                    try printAst(file_table, (&val)[0..1], child_indent, writer);
                }
            },
            .if_stmt => {
                try printAst(file_table, (&node.data.if_stmt.cond)[0..1], child_indent, writer);
                try printAst(file_table, (&node.data.if_stmt.body)[0..1], child_indent, writer);
                if (node.data.if_stmt.else_branch) |eb| {
                    try printAst(file_table, (&eb)[0..1], child_indent, writer);
                }
            },
            .for_stmt => {
                if (node.data.for_stmt.vari) |v| try printAst(file_table, (&v)[0..1], child_indent, writer);
                if (node.data.for_stmt.cond) |c| try printAst(file_table, (&c)[0..1], child_indent, writer);
                if (node.data.for_stmt.incr) |j| try printAst(file_table, (&j)[0..1], child_indent, writer);
                try printAst(file_table, (&node.data.for_stmt.body)[0..1], child_indent, writer);
            },
            .pub_stmt => {
                try printAst(file_table, (&node.data.pub_stmt.stmt)[0..1], child_indent, writer);
            },
            .struct_stmt => {
                try printIndent(child_indent, writer);
                try writer.print("name index: {}\n", .{node.data.struct_stmt.name});
                try printAst(file_table, node.data.struct_stmt.fields, child_indent, writer);
            },
            .struct_field => {
                try printIndent(child_indent, writer);
                try writer.print(
                    "name index: {}, type: ",
                    .{node.data.struct_field.name},
                );
                try node.getTy().writeName(file_table, writer);
                try writer.writeByte('\n');
            },
            .struct_init => {
                if (node.data.struct_init.name) |n|
                    try printAst(file_table, (&n)[0..1], child_indent, writer);
                try printAst(file_table, node.data.struct_init.fields, child_indent, writer);
            },
            .field_init => {
                try printIndent(child_indent, writer);
                try writer.print("name index: {}\n", .{node.data.field_init.name});
                try printAst(file_table, (&node.data.field_init.val)[0..1], child_indent, writer);
            },
        }
    }
}

fn printIndent(count: usize, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeAll("     ");
    }
}
