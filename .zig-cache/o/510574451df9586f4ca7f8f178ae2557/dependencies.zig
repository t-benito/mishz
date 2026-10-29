pub const packages = struct {
    pub const @"clap-0.12.0-oBajB4XpAQCF1WRKnD5KOKPsnwwT_NNdAJ7Ww3irYJac" = struct {
        pub const build_root = "zig-pkg/clap-0.12.0-oBajB4XpAQCF1WRKnD5KOKPsnwwT_NNdAJ7Ww3irYJac";
        pub const build_zig = @import("clap-0.12.0-oBajB4XpAQCF1WRKnD5KOKPsnwwT_NNdAJ7Ww3irYJac");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "clap", "clap-0.12.0-oBajB4XpAQCF1WRKnD5KOKPsnwwT_NNdAJ7Ww3irYJac" },
};
