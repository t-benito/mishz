const std = @import("std");

extern "c" fn qbe_main(argc: c_int, argv: [*:null]const ?[*:0]const u8) c_int;

pub fn compileSsa(in: [:0]const u8, out: [:0]const u8) !void {
    const argv = [_:null]?[*:0]const u8{
        "qbe",
        "-o",
        out.ptr,
        in.ptr,
    };
    const res = qbe_main(4, &argv);
    if (res != 0)
        return error.Failed;
}
