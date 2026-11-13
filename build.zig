const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("mishz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.0.2yb");

    const exe = b.addExecutable(.{
        .name = "mishz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mishz", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    exe.root_module.addOptions("build_options", options);

    const qbe = b.dependency("qbe", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("qbe", qbe.module("qbe"));

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}
