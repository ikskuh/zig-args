const std = @import("std");
const argsParser = @import("args.zig");

pub fn main() !void {
    var argsAllocator = std.heap.page_allocator;

    const options = try argsParser.parseForCurrentProcess(struct {
        // This declares long options for double hyphen
        output: ?[]const u8 = null,
        @"with-offset": bool = false,
        @"with-hexdump": bool = false,
        @"intermix-source": bool = false,
        numberOfBytes: ?i32 = null,
        mode: enum { default, special, slow, fast } = .default,

        // This declares short-hand options for single hyphen
        pub const shorthands = .{
            .S = "intermix-source",
            .b = "with-hexdump",
            .O = "with-offset",
            .o = "output",
        };
    }, argsAllocator);
    defer options.deinit();

    std.debug.warn("executable name: {}\n", .{options.executable_name});

    std.debug.warn("parsed options:\n", .{});
    inline for (std.meta.fields(@TypeOf(options.options))) |fld| {
        std.debug.warn("\t{} = {}\n", .{
            fld.name,
            @field(options.options, fld.name),
        });
    }

    std.debug.warn("parsed positionals:\n", .{});
    for (options.positionals) |arg| {
        std.debug.warn("\t'{}'\n", .{arg});
    }
}
