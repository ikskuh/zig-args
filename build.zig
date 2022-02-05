const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const test_runner = b.addTest("args.zig");
    test_runner.setBuildMode(mode);
    test_runner.setTarget(target);

    // Standard demo

    const demo_exe = b.addExecutable("demo", "demo.zig");
    demo_exe.setBuildMode(mode);
    demo_exe.setTarget(target);

    const run_demo = demo_exe.run();
    run_demo.addArgs(&[_][]const u8{
        "--output", "demo", "--with-offset", "--signed_number=-10", "--unsigned_number", "20", "--mode", "slow", "help", "this", "is", "borked",
    });

    // Demo with verbs

    const demo_verb_exe = b.addExecutable("demo_verb", "demo_verb.zig");
    demo_verb_exe.setBuildMode(mode);
    demo_verb_exe.setTarget(target);

    const run_demo_verb_1 = demo_verb_exe.run();
    run_demo_verb_1.addArgs(&[_][]const u8{
        "compact", "--host=localhost", "-p", "4030", "--mode", "fast", "help", "this", "is", "borked",
    });
    const run_demo_verb_2 = demo_verb_exe.run();
    run_demo_verb_2.addArgs(&[_][]const u8{
        "reload", "-f",
    });

    const test_step = b.step("test", "Runs the test suite.");
    test_step.dependOn(&test_runner.step);
    test_step.dependOn(&run_demo.step);
    test_step.dependOn(&run_demo_verb_1.step);
    test_step.dependOn(&run_demo_verb_2.step);
}
