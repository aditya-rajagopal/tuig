const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stdx = b.createModule(.{
        .root_source_file = b.path("src/stdx/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    const ui = b.addModule("ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "renderer", .module = renderer },
            .{ .name = "stdx", .module = stdx },
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
            .{ .name = "ui", .module = ui },
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

    const terminal_tests = b.addTest(.{
        .root_module = terminal,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_terminal_tests = b.addRunArtifact(terminal_tests);
    const renderer_tests = b.addTest(.{
        .root_module = renderer,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_renderer_tests = b.addRunArtifact(renderer_tests);
    const unicode_tests = b.addTest(.{
        .root_module = unicode,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_unicode_tests = b.addRunArtifact(unicode_tests);
    const ui_tests = b.addTest(.{
        .root_module = ui,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_ui_tests = b.addRunArtifact(ui_tests);

    const benchmark_tests_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "renderer", .module = renderer },
            .{ .name = "unicode", .module = unicode },
            .{ .name = "stdx", .module = stdx },
            .{ .name = "terminal", .module = terminal },
        },
    });
    const benchmark_tests = b.addTest(.{
        .root_module = benchmark_tests_mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_benchmark_tests = b.addRunArtifact(benchmark_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_terminal_tests.step);
    test_step.dependOn(&run_renderer_tests.step);
    test_step.dependOn(&run_unicode_tests.step);
    test_step.dependOn(&run_ui_tests.step);
    test_step.dependOn(&run_benchmark_tests.step);

    const check_exe = b.addExecutable(.{ .name = "check", .root_module = example_mod });
    const check_step = b.step("check", "Run ast check");
    check_step.dependOn(&check_exe.step);

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "renderer", .module = renderer },
            .{ .name = "unicode", .module = unicode },
            .{ .name = "stdx", .module = stdx },
            .{ .name = "terminal", .module = terminal },
        },
    });

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_mod,
    });
    check_step.dependOn(&benchmark_exe.step);

    b.installArtifact(benchmark_exe);

    // Main benchmark step (runs all benchmarks)
    const benchmark_step = b.step("benchmark", "Run all benchmarks");
    const benchmark_cmd = b.addRunArtifact(benchmark_exe);
    benchmark_step.dependOn(&benchmark_cmd.step);
    benchmark_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        benchmark_cmd.addArgs(args);
    }
}
