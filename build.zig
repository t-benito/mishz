const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("mishz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.0.2yc");

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

    const qbe_build = b.dependency("qbe-build", .{});
    const qbe_bmod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    qbe_bmod.addIncludePath(qbe_build.path(""));
    qbe_bmod.addCSourceFiles(.{
        .root = qbe_build.path(""),
        .files = &.{
            "main.c",       "util.c",       "parse.c",      "abi.c",        "cfg.c",
            "mem.c",        "ssa.c",        "alias.c",      "load.c",       "copy.c",
            "fold.c",       "gcm.c", "gvn.c", "ifopt.c",      "simpl.c",      "live.c",       "spill.c",
            "rega.c",       "emit.c",
            "amd64/targ.c", "amd64/sysv.c", "amd64/isel.c", "amd64/emit.c", "amd64/winabi.c",
            "arm64/targ.c", "arm64/abi.c",  "arm64/isel.c", "arm64/emit.c",
            "rv64/targ.c",  "rv64/abi.c",   "rv64/isel.c",  "rv64/emit.c",
        },
        .flags = &.{
            "-std=c99",
            "-Dmain=qbe_main",
        },
    });

    const wf = b.addWriteFiles();
    _ = wf.add("config.h", b.fmt("#define Deftgt {s}\n", .{
        switch (target.result.cpu.arch) {
            .aarch64 => if (target.result.os.tag.isDarwin()) "T_arm64_apple" else "T_arm64",
            .riscv64 => "T_rv64",
            .x86_64 => if (target.result.os.tag == .windows)
                            "T_amd64_win"
                        else if (target.result.os.tag.isDarwin())
                            "T_amd64_apple"
                        else
                            "T_amd64_sysv",
            else => @panic("wrong build target for qbe"),
    }}));
    qbe_bmod.addIncludePath(wf.getDirectory());

    const qbe_blib = b.addLibrary(.{
        .name = "qbe-build",
        .root_module = qbe_bmod,
        .linkage = .static,
    });
    exe.root_module.linkLibrary(qbe_blib);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}
