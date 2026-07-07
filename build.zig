const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ecs = b.addModule("ecs", .{
        .root_source_file = b.path("src/ecs.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs", .module = ecs },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);
}
