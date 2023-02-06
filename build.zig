const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const args_mod = b.createModule(.{ .source_file = .{ .path = "args.zig" } });
    b.modules.put(b.dupe("args"), args_mod) catch @panic("OOM");

    const test_runner = b.addTest(.{
        .root_source_file = .{ .path = "args.zig" },
        .optimize = optimize,
        .target = target,
    });

    // Standard demo

    const demo_exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = .{ .path = "demo.zig" },
        .optimize = optimize,
        .target = target,
    });
    demo_exe.addModule("args", args_mod);

    const run_demo = demo_exe.run();
    run_demo.addArgs(&[_][]const u8{
        "--output", "demo", "--with-offset", "--signed_number=-10", "--unsigned_number", "20", "--mode", "slow", "help", "this", "is", "borked",
    });

    // Demo with verbs

    const demo_verb_exe = b.addExecutable(.{
        .name = "demo_verb",
        .root_source_file = .{ .path = "demo_verb.zig" },
        .optimize = optimize,
        .target = target,
    });
    demo_verb_exe.addModule("args", args_mod);

    const run_demo_verb_1 = demo_verb_exe.run();
    run_demo_verb_1.addArgs(&[_][]const u8{
        "compact", "--host=localhost", "-p", "4030", "--mode", "fast", "help", "this", "is", "borked",
    });
    const run_demo_verb_2 = demo_verb_exe.run();
    run_demo_verb_2.addArgs(&[_][]const u8{
        "reload", "-f",
    });
    const run_demo_verb_3 = demo_verb_exe.run();
    run_demo_verb_3.addArgs(&[_][]const u8{
        "forward",
    });
    const run_demo_verb_4 = demo_verb_exe.run();
    run_demo_verb_4.addArgs(&[_][]const u8{
        "zero-sized",
    });

    const test_step = b.step("test", "Runs the test suite.");
    test_step.dependOn(&test_runner.step);
    test_step.dependOn(&run_demo.step);
    test_step.dependOn(&run_demo_verb_1.step);
    test_step.dependOn(&run_demo_verb_2.step);
    test_step.dependOn(&run_demo_verb_3.step);
    test_step.dependOn(&run_demo_verb_4.step);
}
