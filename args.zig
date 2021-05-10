const std = @import("std");

const ErrorReporting = enum {
    print,
    errors,
    ignore,
};

pub const Error = union(ErrorReporting) {
    print: []const u8,
    errors: u8,
    ignore: u8,
};

/// Parses arguments for the given specification and our current process.
/// - `Spec` is the configuration of the arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
pub fn parseForCurrentProcess(comptime Spec: type, allocator: *std.mem.Allocator, reporting: Error) !ParseArgsResult(Spec) {
    var args = std.process.args();

    const executable_name = try (args.next(allocator) orelse {
        try std.io.getStdErr().writer().writeAll("Failed to get executable name from the argument list!\n");
        return error.NoExecutableName;
    });
    errdefer allocator.free(executable_name);

    var result = try parse(Spec, &args, allocator, reporting);

    result.executable_name = executable_name;

    return result;
}

/// Parses arguments for the given specification.
/// - `Spec` is the configuration of the arguments.
/// - `args` is an ArgIterator that will yield the command line arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
///
/// Note that `.executable_name` in the result will not be set!
pub fn parse(comptime Spec: type, args: *std.process.ArgIterator, allocator: *std.mem.Allocator, reporting: Error) !ParseArgsResult(Spec) {
    var result = ParseArgsResult(Spec){
        .arena = std.heap.ArenaAllocator.init(allocator),
        .options = Spec{},
        .positionals = undefined,
        .executable_name = null,
    };
    errdefer result.arena.deinit();

    var arglist = std.ArrayList([]const u8).init(allocator);
    errdefer arglist.deinit();

    while (args.next(&result.arena.allocator)) |item_or_error| {
        const item = try item_or_error;

        if (std.mem.startsWith(u8, item, "--")) {
            if (std.mem.eql(u8, item, "--")) {
                // double hyphen is considered 'everything from here now is positional'
                break;
            }

            const Pair = struct {
                name: []const u8,
                value: ?[]const u8,
            };

            const pair = if (std.mem.indexOf(u8, item, "=")) |index|
                Pair{
                    .name = item[2..index],
                    .value = item[index + 1 ..],
                }
            else
                Pair{
                    .name = item[2..],
                    .value = null,
                };

            var found = false;
            inline for (std.meta.fields(Spec)) |fld| {
                if (std.mem.eql(u8, pair.name, fld.name)) {
                    try parseOption(Spec, &result, args, fld.name, pair.value);
                    found = true;
                }
            }

            if (!found) {
                if (reporting.print.len == 0) {
                    try std.io.getStdErr().writer().print("<Custom message>: {s}\n", .{pair.name});
                }
                try std.io.getStdErr().writer().print("Unknown command line option: {s}\n", .{pair.name});
                return error.EncounteredUnknownArgument;
            }
        } else if (std.mem.startsWith(u8, item, "-")) {
            if (std.mem.eql(u8, item, "-")) {
                // single hyphen is considered a positional argument
                try arglist.append(item);
            } else {
                if (@hasDecl(Spec, "shorthands")) {
                    for (item[1..]) |char, index| {
                        var found = false;
                        inline for (std.meta.fields(@TypeOf(Spec.shorthands))) |fld| {
                            if (fld.name.len != 1)
                                @compileError("All shorthand fields must be exactly one character long!");
                            if (fld.name[0] == char) {
                                const real_name = @field(Spec.shorthands, fld.name);
                                const real_fld_type = @TypeOf(@field(result.options, real_name));

                                // -2 because we stripped of the "-" at the beginning
                                if (requiresArg(real_fld_type) and index != item.len - 2) {
                                    try std.io.getStdErr().writer().writeAll("An option with argument must be the last option for short command line options.\n");
                                    return error.EncounteredUnexpectedArgument;
                                }

                                try parseOption(Spec, &result, args, real_name, null);

                                found = true;
                            }
                        }
                        if (!found) {
                            
                            if (reporting.print.len == 0) {
                                try std.io.getStdErr().writer().print("<Custom message>: -{c}\n", .{char});
                            }
                            try std.io.getStdErr().writer().print("Unknown command line option: -{c}\n", .{char});
                            return error.EncounteredUnknownArgument;
                        }
                    }
                } else {
                    try std.io.getStdErr().writer().writeAll("Short command line options are not supported.\n");
                    return error.EncounteredUnsupportedArgument;
                }
            }
        } else {
            try arglist.append(item);
        }
    }

    // This will consume the rest of the arguments as positional ones.
    // Only executes when the above loop is broken.
    while (args.next(&result.arena.allocator)) |item_or_error| {
        const item = try item_or_error;
        try arglist.append(item);
    }

    result.positionals = arglist.toOwnedSlice();
    return result;
}

/// The return type of the argument parser.
pub fn ParseArgsResult(comptime Spec: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,

        /// The options with either default or set values.
        options: Spec,

        /// The positional arguments that were passed to the process.
        positionals: [][]const u8,

        /// Name of the executable file (or: zeroth argument)
        executable_name: ?[]const u8,

        pub fn deinit(self: Self) void {
            self.arena.child_allocator.free(self.positionals);

            if (self.executable_name) |n|
                self.arena.child_allocator.free(n);

            self.arena.deinit();
        }
    };
}

/// Returns true if the given type requires an argument to be parsed.
fn requiresArg(comptime T: type) bool {
    const H = struct {
        fn doesArgTypeRequireArg(comptime Type: type) bool {
            if (Type == []const u8)
                return true;

            return switch (@as(std.builtin.TypeId, @typeInfo(Type))) {
                .Int, .Float, .Enum => true,
                .Bool => false,
                .Struct, .Union => true,
                else => @compileError(@typeName(Type) ++ " is not a supported argument type!"),
            };
        }
    };

    const ti = @typeInfo(T);
    if (ti == .Optional) {
        return H.doesArgTypeRequireArg(ti.Optional.child);
    } else {
        return H.doesArgTypeRequireArg(T);
    }
}

/// Parses a boolean option.
fn parseBoolean(str: []const u8) !bool {
    return if (std.mem.eql(u8, str, "yes"))
        true
    else if (std.mem.eql(u8, str, "true"))
        true
    else if (std.mem.eql(u8, str, "y"))
        true
    else if (std.mem.eql(u8, str, "no"))
        false
    else if (std.mem.eql(u8, str, "false"))
        false
    else if (std.mem.eql(u8, str, "n"))
        false
    else
        return error.NotABooleanValue;
}

/// Parses an int option.
fn parseInt(comptime T: type, str: []const u8) !T {
    var buf = str;
    var multiplier: T = 1;

    if (buf.len != 0) {
        var base1024 = false;
        if (std.ascii.toLower(buf[buf.len - 1]) == 'i') {   //ki vs k for instance
            buf.len -= 1;
            base1024 = true;
        }
        if (buf.len != 0) {
            var pow: u3 = switch (buf[buf.len - 1]) {
                'k', 'K' => 1,  //kilo
                'm', 'M' => 2,  //mega
                'g', 'G' => 3,  //giga
                't', 'T' => 4,  //tera
                'p', 'P' => 5,  //peta
                else => 0
            };
            
            if (pow != 0) {
                buf.len -= 1;

                if (comptime std.math.maxInt(T) < 1024)
                    return error.Overflow;
                var base: T = if (base1024) 1024 else 1000;
                multiplier = try std.math.powi(T, base, @intCast(T, pow));
            }
        }
    }

    const ret: T = switch (@typeInfo(T).Int.signedness) {
        .signed => try std.fmt.parseInt(T, buf, 0),
        .unsigned => try std.fmt.parseUnsigned(T, buf, 0),
    };

    return try std.math.mul(T, ret, multiplier);
}

test "parseInt" {
    const tst = std.testing;

    tst.expectEqual(@as(i32, 50), try parseInt(i32, "50"));
    tst.expectEqual(@as(i32, 6000), try parseInt(i32, "6k"));
    tst.expectEqual(@as(u32, 2048), try parseInt(u32, "0x2KI"));
    tst.expectEqual(@as(i8, 0), try parseInt(i8, "0"));
    tst.expectEqual(@as(usize, 10_000_000_000), try parseInt(usize, "0xAg"));
    tst.expectError(error.Overflow, parseInt(i2, "1m"));
    tst.expectError(error.Overflow, parseInt(u16, "1Ti"));
}

/// Converts an argument value to the target type.
fn convertArgumentValue(comptime T: type, textInput: []const u8) !T {
    if (T == []const u8)
        return textInput;

    switch (@typeInfo(T)) {
        .Optional => |opt| return try convertArgumentValue(opt.child, textInput),
        .Bool => if (textInput.len > 0)
            return try parseBoolean(textInput)
        else
            return true, // boolean options are always true
        .Int => |int| return try parseInt(T, textInput),
        .Float => return try std.fmt.parseFloat(T, textInput),
        .Enum => {
            if (@hasDecl(T, "parse")) {
                return try T.parse(textInput);
            } else {
                return std.meta.stringToEnum(T, textInput) orelse return error.InvalidEnumeration;
            }
        },
        .Struct, .Union => {
            if (@hasDecl(T, "parse")) {
                return try T.parse(textInput);
            } else {
                @compileError(@typeName(T) ++ " has no public visible `fn parse([]const u8) !T`!");
            }
        },
        else => @compileError(@typeName(T) ++ " is not a supported argument type!"),
    }
}

/// Parses an option value into the correct type.
fn parseOption(
    comptime Spec: type,
    result: *ParseArgsResult(Spec),
    args: *std.process.ArgIterator,
    /// The name of the option that is currently parsed.
    comptime name: []const u8,
    /// Optional pre-defined value for options that use `--foo=bar`
    value: ?[]const u8,
) !void {
    const field_type = @TypeOf(@field(result.options, name));

    @field(result.options, name) = if (requiresArg(field_type)) blk: {
        const argval = if (value) |val|
            val
        else
            try (args.next(&result.arena.allocator) orelse {
                try std.io.getStdErr().writer().print(
                    "Missing argument for {s}.\n",
                    .{name},
                );
                return error.MissingArgument;
            });

        break :blk convertArgumentValue(field_type, argval) catch |err| {
            try outputParseError(name, err);
            return err;
        };
    } else
        convertArgumentValue(field_type, if (value) |val| val else "") catch |err| {
            try outputParseError(name, err);
            return err;
        }; // argument is "empty"
}

/// Helper function that will print an error message when a value could not be parsed, then return the same error again
fn outputParseError(option: []const u8, err: anytype) !void {
    try std.io.getStdErr().writer().print("Failed to parse option {s}: {s}\n", .{
        option,
        @errorName(err),
    });
    return err;
}
