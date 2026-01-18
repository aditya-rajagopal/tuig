const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stdx = b.dependency("stdx", .{ .target = target }).module("stdx");

    const unicode = b.addModule("unicode", .{
        .root_source_file = b.path("src/unicode/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdx", .module = stdx },
        },
    });

    const terminal = b.addModule("terminal", .{
        .root_source_file = b.path("src/terminal/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdx", .module = stdx },
        },
    });

    const renderer = b.addModule("renderer", .{
        .root_source_file = b.path("src/renderer/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unicode", .module = unicode },
            .{ .name = "stdx", .module = stdx },
            .{ .name = "terminal", .module = terminal },
        },
    });

    const mod = b.addModule("tuig", .{
        .root_source_file = b.path("src/tuig.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "unicode", .module = unicode },
            .{ .name = "renderer", .module = renderer },
            .{ .name = "stdx", .module = stdx },
            .{ .name = "terminal", .module = terminal },
        },
    });

    const example_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tuig", .module = mod },
            .{ .name = "stdx", .module = stdx },
        },
    });

    const example = b.addExecutable(.{
        .name = "testbed",
        .root_module = example_mod,
    });

    b.installArtifact(example);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(example);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const check_exe = b.addExecutable(.{ .name = "check", .root_module = example_mod });
    const check_step = b.step("check", "Run ast check");
    check_step.dependOn(&check_exe.step);
}
