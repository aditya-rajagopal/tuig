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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_terminal_tests.step);
    test_step.dependOn(&run_renderer_tests.step);
    test_step.dependOn(&run_unicode_tests.step);

    const check_exe = b.addExecutable(.{ .name = "check", .root_module = example_mod });
    const check_step = b.step("check", "Run ast check");
    check_step.dependOn(&check_exe.step);

    // Print benchmark
    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "renderer", .module = renderer },
            .{ .name = "unicode", .module = unicode },
            .{ .name = "stdx", .module = stdx },
        },
    });

    const benchmark = b.addExecutable(.{
        .name = "print_benchmark",
        .root_module = benchmark_mod,
    });

    b.installArtifact(benchmark);
    const bench_step = b.step("bench-print", "Run print benchmark");
    const bench_cmd = b.addRunArtifact(benchmark);
    bench_step.dependOn(&bench_cmd.step);
    bench_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    // Renderer benchmark
    const renderer_benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/renderer_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "renderer", .module = renderer },
            .{ .name = "unicode", .module = unicode },
            .{ .name = "stdx", .module = stdx },
        },
    });

    const renderer_benchmark = b.addExecutable(.{
        .name = "renderer_benchmark",
        .root_module = renderer_benchmark_mod,
    });

    b.installArtifact(renderer_benchmark);
    const bench_renderer_step = b.step("bench-renderer", "Run renderer benchmark");
    const bench_renderer_cmd = b.addRunArtifact(renderer_benchmark);
    bench_renderer_step.dependOn(&bench_renderer_cmd.step);
    bench_renderer_cmd.step.dependOn(b.getInstallStep());
    check_step.dependOn(&bench_renderer_cmd.step);

    if (b.args) |args| {
        bench_renderer_cmd.addArgs(args);
    }
}
