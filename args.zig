const std = @import("std");

/// Parses arguments for the given specification and our current process.
/// - `Spec` is the configuration of the arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
/// - `error_handling` defines how parser errors will be handled.
pub fn parseForCurrentProcess(comptime Spec: type, allocator: *std.mem.Allocator, error_handling: ErrorHandling) !ParseArgsResult(Spec) {
    var args = std.process.args();

    const executable_name = try (args.next(allocator) orelse {
        try error_handling.process(error.NoExecutableName, Error{
            .option = "",
            .kind = .missing_executable_name,
        });

        // we do not assume any more arguments appear here anyways...
        return error.NoExecutableName;
    });
    errdefer allocator.free(executable_name);

    var result = try parse(Spec, &args, allocator, error_handling);

    result.executable_name = executable_name;

    return result;
}

/// Parses arguments for the given specification.
/// - `Spec` is the configuration of the arguments.
/// - `args` is an ArgIterator that will yield the command line arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
/// - `error_handling` defines how parser errors will be handled.
///
/// Note that `.executable_name` in the result will not be set!
pub fn parse(comptime Spec: type, args: *std.process.ArgIterator, allocator: *std.mem.Allocator, error_handling: ErrorHandling) !ParseArgsResult(Spec) {
    var result = ParseArgsResult(Spec){
        .arena = std.heap.ArenaAllocator.init(allocator),
        .options = Spec{},
        .positionals = undefined,
        .executable_name = null,
    };
    errdefer result.arena.deinit();

    var arglist = std.ArrayList([:0]const u8).init(allocator);
    errdefer arglist.deinit();

    var last_error: ?anyerror = null;

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
                    try parseOption(Spec, &result, args, error_handling, &last_error, fld.name, pair.value);
                    found = true;
                }
            }

            if (!found) {
                last_error = error.EncounteredUnknownArgument;
                try error_handling.process(error.EncounteredUnknownArgument, Error{
                    .option = pair.name,
                    .kind = .unknown,
                });
            }
        } else if (std.mem.startsWith(u8, item, "-")) {
            if (std.mem.eql(u8, item, "-")) {
                // single hyphen is considered a positional argument
                try arglist.append(item);
            } else {
                if (@hasDecl(Spec, "shorthands")) {
                    for (item[1..]) |char, index| {
                        var option_name = [2]u8{ '-', char };
                        var found = false;
                        inline for (std.meta.fields(@TypeOf(Spec.shorthands))) |fld| {
                            if (fld.name.len != 1)
                                @compileError("All shorthand fields must be exactly one character long!");
                            if (fld.name[0] == char) {
                                const real_name = @field(Spec.shorthands, fld.name);
                                const real_fld_type = @TypeOf(@field(result.options, real_name));

                                // -2 because we stripped of the "-" at the beginning
                                if (requiresArg(real_fld_type) and index != item.len - 2) {
                                    last_error = error.EncounteredUnexpectedArgument;
                                    try error_handling.process(error.EncounteredUnexpectedArgument, Error{
                                        .option = &option_name,
                                        .kind = .invalid_placement,
                                    });
                                } else {
                                    try parseOption(Spec, &result, args, error_handling, &last_error, real_name, null);
                                }

                                found = true;
                            }
                        }
                        if (!found) {
                            last_error = error.EncounteredUnknownArgument;
                            try error_handling.process(error.EncounteredUnknownArgument, Error{
                                .option = &option_name,
                                .kind = .unknown,
                            });
                        }
                    }
                } else {
                    try error_handling.process(error.EncounteredUnsupportedArgument, Error{
                        .option = item,
                        .kind = .unsupported,
                    });
                }
            }
        } else {
            try arglist.append(item);
        }
    }

    if (last_error != null)
        return error.InvalidArguments;

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

        /// Exports the type of options.
        pub const Options = Spec;

        arena: std.heap.ArenaAllocator,

        /// The options with either default or set values.
        options: Spec,

        /// The positional arguments that were passed to the process.
        positionals: [][:0]const u8,

        /// Name of the executable file (or: zeroth argument)
        executable_name: ?[:0]const u8,

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
        if (std.ascii.toLower(buf[buf.len - 1]) == 'i') { //ki vs k for instance
            buf.len -= 1;
            base1024 = true;
        }
        if (buf.len != 0) {
            var pow: u3 = switch (buf[buf.len - 1]) {
                'k', 'K' => 1, //kilo
                'm', 'M' => 2, //mega
                'g', 'G' => 3, //giga
                't', 'T' => 4, //tera
                'p', 'P' => 5, //peta
                else => 0,
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

    try tst.expectEqual(@as(i32, 50), try parseInt(i32, "50"));
    try tst.expectEqual(@as(i32, 6000), try parseInt(i32, "6k"));
    try tst.expectEqual(@as(u32, 2048), try parseInt(u32, "0x2KI"));
    try tst.expectEqual(@as(i8, 0), try parseInt(i8, "0"));
    try tst.expectEqual(@as(usize, 10_000_000_000), try parseInt(usize, "0xAg"));
    try tst.expectError(error.Overflow, parseInt(i2, "1m"));
    try tst.expectError(error.Overflow, parseInt(u16, "1Ti"));
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
        .Int => return try parseInt(T, textInput),
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
    error_handling: ErrorHandling,
    last_error: *?anyerror,
    /// The name of the option that is currently parsed.
    comptime name: []const u8,
    /// Optional pre-defined value for options that use `--foo=bar`
    value: ?[]const u8,
) !void {
    const field_type = @TypeOf(@field(result.options, name));

    const final_value = if (value) |val|
        val // use the literal value
    else if (requiresArg(field_type))
        // fetch from parser
        try (args.next(&result.arena.allocator) orelse {
            last_error.* = error.MissingArgument;
            try error_handling.process(error.MissingArgument, Error{
                .option = "--" ++ name,
                .kind = .missing_argument,
            });
            return;
        })
    else
        // argument is "empty"
        "";

    @field(result.options, name) = convertArgumentValue(field_type, final_value) catch |err| {
        last_error.* = err;
        try error_handling.process(err, Error{
            .option = "--" ++ name,
            .kind = .{ .invalid_value = final_value },
        });
        // we couldn't parse the value, so we return a undefined value as we have signalled an
        // error and won't return this anyways.
        return undefined;
    };
}

/// A collection of errors that were encountered while parsing arguments.
pub const ErrorCollection = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Error),

    pub fn init(allocator: *std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .list = std.ArrayList(Error).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.list.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returns the current enumeration of errors.
    pub fn errors(self: Self) []const Error {
        return self.list.items;
    }

    /// Appends an error to the collection
    fn insert(self: *Self, err: Error) !void {
        var dupe = Error{
            .option = try self.arena.allocator.dupe(u8, err.option),
            .kind = switch (err.kind) {
                .invalid_value => |v| Error.Kind{
                    .invalid_value = try self.arena.allocator.dupe(u8, v),
                },
                // flat copy
                .unknown, .out_of_memory, .unsupported, .invalid_placement, .missing_argument, .missing_executable_name => err.kind,
            },
        };
        try self.list.append(dupe);
    }
};

/// An argument parsing error.
pub const Error = struct {
    const Self = @This();

    /// The option that yielded the error
    option: []const u8,

    /// The kind of error, might include additional information
    kind: Kind,

    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self.kind) {
            .unknown => try writer.print("The option {s} does not exist", .{self.option}),
            .invalid_value => |value| try writer.print("Invalid value '{s}' for option {s}", .{ value, self.option }),
            .out_of_memory => try writer.print("Out of memory while parsing option {s}", .{self.option}),
            .unsupported => try writer.writeAll("Short command line options are not supported."),
            .invalid_placement => try writer.writeAll("An option with argument must be the last option for short command line options."),
            .missing_argument => try writer.print("Missing argument for option {s}", .{self.option}),

            .missing_executable_name => try writer.writeAll("Failed to get executable name from the argument list!"),
        }
    }

    const Kind = union(enum) {
        /// When the argument itself is unknown
        unknown,

        /// When the parsing of an argument value failed
        invalid_value: []const u8,

        /// When the parsing of an argument value triggered a out of memory error
        out_of_memory,

        /// When the argument is a short argument and no shorthands are enabled
        unsupported,

        /// Can only happen when a shorthand for an option requires an argument, but is followed by more shorthands.
        invalid_placement,

        /// An option was passed that requires an argument, but the option was passed last.
        missing_argument,

        /// This error has an empty option name and can only happen when parsing the argument list for a process.
        missing_executable_name,
    };
};

/// The error handling method that should be used.
pub const ErrorHandling = union(enum) {
    const Self = @This();

    /// Do not print or process any errors, just 
    /// return a fitting error on the first argument mismatch.
    silent,

    /// Print errors to stderr and return a `error.InvalidArguments`.
    print,

    /// Collect errors into the error collection and return
    /// `error.InvalidArguments` when any error was encountered.
    collect: *ErrorCollection,

    /// Processes an error with the given handling method.
    fn process(self: Self, src_error: anytype, err: Error) !void {
        if (@typeInfo(@TypeOf(src_error)) != .ErrorSet)
            @compileError("src_error must be a error union!");
        switch (self) {
            .silent => return src_error,
            .print => try std.io.getStdErr().writer().print("{}\n", .{err}),
            .collect => |collection| try collection.insert(err),
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "ErrorCollection" {
    var option_buf = "option".*;
    var invalid_buf = "invalid".*;

    var ec = ErrorCollection.init(std.testing.allocator);
    defer ec.deinit();

    try ec.insert(Error{
        .option = &option_buf,
        .kind = .{ .invalid_value = &invalid_buf },
    });

    option_buf = undefined;
    invalid_buf = undefined;

    try std.testing.expectEqualStrings("option", ec.errors()[0].option);
    try std.testing.expectEqualStrings("invalid", ec.errors()[0].kind.invalid_value);
}
