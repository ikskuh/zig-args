# zig-args
Simple-to-use argument parser with struct-based config

```zig
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
```