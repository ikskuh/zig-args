const std = @import("std");
const argsParser = @import("args.zig");

pub fn main() !void {
    var args = std.process.args();

    var argsAllocator = std.heap.direct_allocator;

    const exeName = try (args.next(argsAllocator) orelse {
        try std.io.getStdErr().outStream().stream.write("Failed to get executable name from the argument list!\n");
        return;
    });
    defer argsAllocator.free(exeName);

    const options = try argsParser.parse(struct {
        // This declares long options for double hyphen
        output: ?[]const u8 = null,
        @"with-offset": bool = false,
        @"with-hexdump": bool = false,
        @"intermix-source": bool = false,
        numberOfBytes: ?i32 = null,

        // This declares short-hand options for single hyphen
        pub const shorthands = .{
            .S = "intermix-source",
            .b = "with-hexdump",
            .O = "with-offset",
            .o = "output",
        };
    }, &args, argsAllocator);
    defer options.deinit();

    std.debug.warn("parsed result:\n{}\npositionals:\n", .{options.options});
    for (options.args) |arg| {
        std.debug.warn("\t{}\n", .{arg});
    }
}
