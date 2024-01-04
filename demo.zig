const std = @import("std");
const argsParser = @import("args");

pub fn main() !u8 {
    const argsAllocator = std.heap.page_allocator;

    const Options = struct {
        // This declares long options for double hyphen
        output: ?[]const u8 = null,
        @"with-offset": bool = false,
        @"with-hexdump": bool = false,
        @"intermix-source": bool = false,
        numberOfBytes: ?i32 = null,
        signed_number: ?i64 = null,
        unsigned_number: ?u64 = null,
        mode: enum { default, special, slow, fast } = .default,
        help: bool = false,

        // This declares short-hand options for single hyphen
        pub const shorthands = .{
            .S = "intermix-source",
            .b = "with-hexdump",
            .O = "with-offset",
            .o = "output",
        };

        pub const meta = .{
            .option_docs = .{
                .output = "output help",
                .@"with-offset" = "with-offset help",
                .@"with-hexdump" = "with-hexdump help",
                .@"intermix-source" = "intermix-source",
                .numberOfBytes = "numberOfBytes help",
                .signed_number = "signed_number help",
                .unsigned_number = "unsigned_number help",
                .mode = "mode help",
                .help = "help help",
            },
        };
    };

    const options = argsParser.parseForCurrentProcess(Options, argsAllocator, .print) catch return 1;
    defer options.deinit();

    std.debug.print("executable name: {?s}\n", .{options.executable_name});

    std.debug.print("parsed options:\n", .{});
    inline for (std.meta.fields(@TypeOf(options.options))) |fld| {
        std.debug.print("\t{s} = {any}\n", .{
            fld.name,
            @field(options.options, fld.name),
        });
    }

    std.debug.print("parsed positionals:\n", .{});
    for (options.positionals) |arg| {
        std.debug.print("\t'{s}'\n", .{arg});
    }

    try argsParser.printHelp(Options, options.executable_name orelse "demo", std.io.getStdOut().writer());
    return 0;
}
