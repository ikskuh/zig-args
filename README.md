# Zig Argument Parser
Simple-to-use argument parser with struct-based config

## Features
- Automatic option generation from a config struct
- Familiar *look & feel*:
    - Everything after the first `--` is assumed to be a positional argument
    - A single `-` is interpreted as a positional argument which can be used as the stdin/stdout file placeholder
    - Short options with no argument can be combined into a single argument: `-dfe`
    - Long options can use either `--option=value` or `--option value` syntax
- Integrated support for primitive types:
    - All integer types (signed & unsigned)
    - Floating point types
    - Booleans (takes optional argument. If no argument given, the bool is set, otherwise, one of `yes`, `true`, `y`, `no`, `false`, `n` is interpreted)
    - Strings
    - Enumerations

## Example

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