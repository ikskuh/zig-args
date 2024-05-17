const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const args_mod = b.addModule("args", .{
        .root_source_file = b.path("args.zig"),
    });

    const main_tests = b.addTest(.{
        .root_source_file = b.path("args.zig"),
        .optimize = optimize,
        .target = target,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // Standard demo

    const demo_exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("demo.zig"),
        .optimize = optimize,
        .target = target,
    });
    demo_exe.root_module.addImport("args", args_mod);

    const run_demo = b.addRunArtifact(demo_exe);
    run_demo.addArgs(&[_][]const u8{
        "--output", "demo", "--with-offset", "--signed_number=-10", "--unsigned_number", "20", "--mode", "slow", "help", "this", "is", "borked",
    });

    // Demo with verbs

    const demo_verb_exe = b.addExecutable(.{
        .name = "demo_verb",
        .root_source_file = b.path("demo_verb.zig"),
        .optimize = optimize,
        .target = target,
    });
    demo_verb_exe.root_module.addImport("args", args_mod);

    const run_demo_verb_1 = b.addRunArtifact(demo_verb_exe);
    run_demo_verb_1.addArgs(&[_][]const u8{
        "compact", "--host=localhost", "-p", "4030", "--mode", "fast", "help", "this", "is", "borked",
    });
    const run_demo_verb_2 = b.addRunArtifact(demo_verb_exe);
    run_demo_verb_2.addArgs(&[_][]const u8{
        "reload", "-f",
    });
    const run_demo_verb_3 = b.addRunArtifact(demo_verb_exe);
    run_demo_verb_3.addArgs(&[_][]const u8{
        "forward",
    });
    const run_demo_verb_4 = b.addRunArtifact(demo_verb_exe);
    run_demo_verb_4.addArgs(&[_][]const u8{
        "zero-sized",
    });

    const test_step = b.step("test", "Runs the test suite.");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_demo.step);
    test_step.dependOn(&run_demo_verb_1.step);
    test_step.dependOn(&run_demo_verb_2.step);
    test_step.dependOn(&run_demo_verb_3.step);
    test_step.dependOn(&run_demo_verb_4.step);
}
