const std = @import("std");

/// Parses arguments for the given specification and our current process.
/// - `Spec` is the configuration of the arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
pub fn parseForCurrentProcess(comptime Spec: type, allocator: *std.mem.Allocator) !ParseArgsResult(Spec) {
    var args = std.process.args();

    const exeName = try (args.next(allocator) orelse {
        try std.io.getStdErr().outStream().stream.write("Failed to get executable name from the argument list!\n");
        return error.NoExecutableName;
    });
    errdefer allocator.free(exeName);

    var result = try parse(Spec, &args, allocator);

    result.exeName = exeName;

    return result;
}

/// Parses arguments for the given specification.
/// - `Spec` is the configuration of the arguments.
/// - `args` is an ArgIterator that will yield the command line arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
///
/// Note that `.exeName` in the result will not be set!
pub fn parse(comptime Spec: type, args: *std.process.ArgIterator, allocator: *std.mem.Allocator) !ParseArgsResult(Spec) {
    var result = ParseArgsResult(Spec){
        .arena = std.heap.ArenaAllocator.init(allocator),
        .options = Spec{},
        .positionals = undefined,
        .exeName = null,
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
                    try parseOption(Spec, &result, args, fld.field_type, fld.name, pair.value);
                    found = true;
                }
            }

            if (!found) {
                try std.io.getStdErr().outStream().stream.print("Unknown command line option: {}\n", .{pair.name});
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
                                const real_fld = std.meta.fieldInfo(Spec, @field(Spec.shorthands, fld.name));

                                // -2 because we stripped of the "-" at the beginning
                                if (requiresArg(real_fld.field_type) and index != item.len - 2) {
                                    try std.io.getStdErr().outStream().stream.write("An option with argument must be the last option for short command line options.\n");
                                    return error.EncounteredUnexpectedArgument;
                                }

                                try parseOption(Spec, &result, args, real_fld.field_type, real_fld.name, null);

                                found = true;
                            }
                        }
                        if (!found) {
                            try std.io.getStdErr().outStream().stream.print("Unknown command line option: -{c}\n", .{char});
                            return error.EncounteredUnknownArgument;
                        }
                    }
                } else {
                    try std.io.getStdErr().outStream().stream.write("Short command line options are not supported.\n");
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
        exeName: ?[]const u8,

        fn deinit(self: Self) void {
            self.arena.child_allocator.free(self.positionals);

            if (self.exeName) |n|
                self.arena.child_allocator.free(n);

            self.arena.deinit();
        }
    };
}

fn requiresArg(comptime T: type) bool {
    const H = struct {
        fn doesArgTypeRequireArg(comptime Type: type) bool {
            if (Type == []const u8)
                return true;

            return switch (@as(std.builtin.TypeId, @typeInfo(Type))) {
                .Int, .Float, .Enum => true,
                .Bool => false,
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

fn convertArgumentValue(comptime T: type, textInput: []const u8) !T {
    if (T == []const u8)
        return textInput;
    switch (@typeInfo(T)) {
        .Optional => |opt| return try convertArgumentValue(opt.child, textInput),
        .Bool => return true, // boolean options are always true
        .Int => |int| return if (int.is_signed)
            try std.fmt.parseInt(T, textInput, 10)
        else
            try std.fmt.parseUnsigned(T, textInput, 10),
        .Float => return try std.fmt.parseFloat(T, textInput),
        .Enum => return std.meta.stringToEnum(T, textInput) orelse return error.InvalidEnumeration,
        else => @compileError(@typeName(T) ++ " is not a supported argument type!"),
    }
}

fn parseOption(
    comptime Spec: type,
    _result: *ParseArgsResult(Spec),
    _args: *std.process.ArgIterator,
    comptime field_type: type,
    comptime name: []const u8,
    value: ?[]const u8,
) !void {
    @field(_result.options, name) = if (requiresArg(field_type)) blk: {
        const argval = if (value) |val|
            val
        else
            try (_args.next(&_result.arena.allocator) orelse {
                try std.io.getStdErr().outStream().stream.print(
                    "Missing argument for {}.\n",
                    .{name},
                );
                return error.MissingArgument;
            });

        break :blk convertArgumentValue(field_type, argval) catch |err| {
            try outputParseError(name, err);
            return err;
        };
    } else
        convertArgumentValue(field_type, "") catch |err| {
        try outputParseError(name, err);
        return err;
    }; // argument is "empty"
}

fn outputParseError(option: []const u8, err: var) !void {
    try std.io.getStdErr().outStream().stream.print("Failed to parse option {}: {}\n", .{
        option,
        @errorName(err),
    });
    return err;
}
