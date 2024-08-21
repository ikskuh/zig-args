# Zig Argument Parser
Simple-to-use argument parser with struct-based config

## Features
- Automatic option generation from a config struct
- Familiar *look & feel*:
    - Everything after the first `--` is assumed to be a positional argument
    - A single `-` is interpreted as a positional argument which can be used as the stdin/stdout file placeholder
    - Short options with no argument can be combined into a single argument: `-dfe`
    - Long options can use either `--option=value` or `--option value` syntax (use `--option=--` if you need `--` as a long option argument)
    - verbs (sub-commands), with verb specific options. Non-verb specific (global) options can come before or after the
      verb on the command line. Non-verb option arguments are processed *before* determining verb.  (see `demo_verb.zig`)
- Integrated support for primitive types:
    - All integer types (signed & unsigned)
    - Floating point types
    - Booleans (takes optional argument. If no argument given, the bool is set, otherwise, one of `yes`, `true`, `y`, `no`, `false`, `n` is interpreted)
    - Strings
    - Enumerations

## Use in your project

Add the dependency in your `build.zig.zon` by running the following command:
```bash
zig fetch --save=args git+https://github.com/ikskuh/zig-args#master
```

Add it to your exe in `build.zig`:
```zig
exe.root_module.addImport("args", b.dependency("args", .{ .target = target, .optimize = optimize }).module("args"));
```

Then you can import it from your code:
```zig
const argsParser = @import("args");
```

## Example

```zig
const options = argsParser.parseForCurrentProcess(struct {
    // This declares long options for double hyphen
    output: ?[]const u8 = null,
    @"with-offset": bool = false,
    @"with-hexdump": bool = false,
    @"intermix-source": bool = false,
    numberOfBytes: ?i32 = null,
    signed_number: ?i64 = null,
    unsigned_number: ?u64 = null,
    mode: enum { default, special, slow, fast } = .default,

    // This declares short-hand options for single hyphen
    pub const shorthands = .{
        .S = "intermix-source",
        .b = "with-hexdump",
        .O = "with-offset",
        .o = "output",
    };
}, argsAllocator, .print) catch return 1;
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
```
