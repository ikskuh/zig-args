const std = @import("std");
const argsParser = @import("args");

pub fn main() !u8 {
    const argsAllocator = std.heap.page_allocator;

    const options = argsParser.parseWithVerbForCurrentProcess(
        struct {
            // this declares long option that can come before or after verb
            output: ?[]const u8 = null,

            // This declares short-hand options for single hyphen
            pub const shorthands = .{
                .o = "output",
            };
        },
        union(enum) {
            compact: struct {
                // This declares long options for double hyphen
                host: ?[]const u8 = null,
                port: u16 = 3420,
                mode: enum { default, special, slow, fast } = .default,

                // This declares short-hand options for single hyphen
                pub const shorthands = .{
                    .H = "host",
                    .p = "port",
                };
            },
            reload: struct {
                // This declares long options for double hyphen
                force: bool = false,

                // This declares short-hand options for single hyphen
                pub const shorthands = .{
                    .f = "force",
                };
            },
            forward: void,
            @"zero-sized": struct {},
        },
        argsAllocator,
        .print,
    ) catch return 1;
    defer options.deinit();

    std.debug.print("executable name: {?s}\n", .{options.executable_name});

    // non-verb/global options
    inline for (std.meta.fields(@TypeOf(options.options))) |fld| {
        std.debug.print("\t{s} = {any}\n", .{
            fld.name,
            @field(options.options, fld.name),
        });
    }
    // verb options
    if (options.verb) |verb| {
        switch (verb) {
            .compact => |opts| {
                inline for (std.meta.fields(@TypeOf(opts))) |fld| {
                    std.debug.print("\t{s} = {any}\n", .{
                        fld.name,
                        @field(opts, fld.name),
                    });
                }
            },
            .reload => |opts| {
                inline for (std.meta.fields(@TypeOf(opts))) |fld| {
                    std.debug.print("\t{s} = {any}\n", .{
                        fld.name,
                        @field(opts, fld.name),
                    });
                }
            },
            .forward => std.debug.print("\t`forward` verb with no options received\n", .{}),
            .@"zero-sized" => std.debug.print("\t`zero-sized` verb received\n", .{}),
        }
    }

    std.debug.print("parsed positionals:\n", .{});
    for (options.positionals) |arg| {
        std.debug.print("\t'{s}'\n", .{arg});
    }

    return 0;
}
