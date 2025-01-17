const std = @import("std");

/// Parses arguments for the given specification and our current process.
/// - `Spec` is the configuration of the arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
/// - `error_handling` defines how parser errors will be handled.
pub fn parseForCurrentProcess(comptime Spec: type, allocator: std.mem.Allocator, comptime error_handling: ErrorHandling) !ParseArgsResult(Spec, null) {
    // Use argsWithAllocator for portability.
    // All data allocated by the ArgIterator is freed at the end of the function.
    // Data returned to the user is always duplicated using the allocator.
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const executable_name = args.next() orelse {
        try error_handling.process(error.NoExecutableName, Error{
            .option = "",
            .kind = .missing_executable_name,
        });

        // we do not assume any more arguments appear here anyways...
        return error.NoExecutableName;
    };

    var result = try parseInternal(Spec, null, &args, allocator, error_handling);

    result.executable_name = try allocator.dupeZ(u8, executable_name);

    return result;
}

/// Parses arguments for the given specification and our current process.
/// - `Spec` is the configuration of the arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
/// - `error_handling` defines how parser errors will be handled.
pub fn parseWithVerbForCurrentProcess(comptime Spec: type, comptime Verb: type, allocator: std.mem.Allocator, comptime error_handling: ErrorHandling) !ParseArgsResult(Spec, Verb) {
    // Use argsWithAllocator for portability.
    // All data allocated by the ArgIterator is freed at the end of the function.
    // Data returned to the user is always duplicated using the allocator.
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const executable_name = args.next() orelse {
        try error_handling.process(error.NoExecutableName, Error{
            .option = "",
            .kind = .missing_executable_name,
        });

        // we do not assume any more arguments appear here anyways...
        return error.NoExecutableName;
    };

    var result = try parseInternal(Spec, Verb, &args, allocator, error_handling);

    result.executable_name = try allocator.dupeZ(u8, executable_name);

    return result;
}

/// Parses arguments for the given specification.
/// - `Generic` is the configuration of the arguments.
/// - `args_iterator` is a pointer to an std.process.ArgIterator that will yield the command line arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
/// - `error_handling` defines how parser errors will be handled.
///
/// Note that `.executable_name` in the result will not be set!
pub fn parse(comptime Generic: type, args_iterator: anytype, allocator: std.mem.Allocator, comptime error_handling: ErrorHandling) !ParseArgsResult(Generic, null) {
    return parseInternal(Generic, null, args_iterator, allocator, error_handling);
}

/// Parses arguments for the given specification using a `Verb` method.
/// This means that the first positional argument is interpreted as a verb, that can
/// be considered a sub-command that provides more specific options.
/// - `Generic` is the configuration of the arguments.
/// - `Verb` is the configuration of the verbs.
/// - `args_iterator` is a pointer to an std.process.ArgIterator that will yield the command line arguments.
/// - `allocator` is the allocator that is used to allocate all required memory
/// - `error_handling` defines how parser errors will be handled.
///
/// Note that `.executable_name` in the result will not be set!
pub fn parseWithVerb(comptime Generic: type, comptime Verb: type, args_iterator: anytype, allocator: std.mem.Allocator, comptime error_handling: ErrorHandling) !ParseArgsResult(Generic, Verb) {
    return parseInternal(Generic, Verb, args_iterator, allocator, error_handling);
}

/// Same as parse, but with anytype argument for testability
fn parseInternal(comptime Generic: type, comptime MaybeVerb: ?type, args_iterator: anytype, allocator: std.mem.Allocator, comptime error_handling: ErrorHandling) !ParseArgsResult(Generic, MaybeVerb) {
    var result = ParseArgsResult(Generic, MaybeVerb){
        .arena = std.heap.ArenaAllocator.init(allocator),
        .options = Generic{},
        .verb = if (MaybeVerb != null) null else {}, // no verb by default
        .positionals = undefined,
        .executable_name = null,
    };
    errdefer result.arena.deinit();
    var result_arena_allocator = result.arena.allocator();

    var arglist = std.ArrayList([:0]const u8).init(allocator);
    defer arglist.deinit();

    var last_error: ?anyerror = null;

    while (args_iterator.next()) |item| {
        if (std.mem.startsWith(u8, item, "--")) {
            if (std.mem.eql(u8, item, "--")) {
                // double hyphen is considered 'everything from here now is positional'
                result.raw_start_index = arglist.items.len;
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
            inline for (std.meta.fields(Generic)) |fld| {
                if (std.mem.eql(u8, pair.name, fld.name)) {
                    try parseOption(Generic, result_arena_allocator, &result.options, args_iterator, error_handling, &last_error, fld.name, pair.value);
                    found = true;
                }
            }

            if (MaybeVerb) |Verb| {
                if (result.verb) |*verb| {
                    if (!found) {
                        const Tag = std.meta.Tag(Verb);
                        inline for (std.meta.fields(Verb)) |verb_info| {
                            if (verb.* == @field(Tag, verb_info.name)) {
                                if (comptime canHaveFieldsAndIsNotZeroSized(verb_info.type)) {
                                    inline for (std.meta.fields(verb_info.type)) |fld| {
                                        if (std.mem.eql(u8, pair.name, fld.name)) {
                                            try parseOption(
                                                verb_info.type,
                                                result_arena_allocator,
                                                &@field(verb.*, verb_info.name),
                                                args_iterator,
                                                error_handling,
                                                &last_error,
                                                fld.name,
                                                pair.value,
                                            );
                                            found = true;
                                        }
                                    }
                                }
                            }
                        }
                    }
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
                try arglist.append(try result_arena_allocator.dupeZ(u8, item));
            } else {
                var any_shorthands = false;
                for (item[1..], 0..) |char, index| {
                    var option_name = [2]u8{ '-', char };
                    var found = false;
                    if (@hasDecl(Generic, "shorthands")) {
                        any_shorthands = true;
                        inline for (std.meta.fields(@TypeOf(Generic.shorthands))) |fld| {
                            if (fld.name.len != 1)
                                @compileError("All shorthand fields must be exactly one character long!");
                            if (fld.name[0] == char) {
                                const real_name = @field(Generic.shorthands, fld.name);
                                const real_fld_type = @TypeOf(@field(result.options, real_name));

                                // -2 because we stripped of the "-" at the beginning
                                if (requiresArg(real_fld_type) and index != item.len - 2) {
                                    last_error = error.EncounteredUnexpectedArgument;
                                    try error_handling.process(error.EncounteredUnexpectedArgument, Error{
                                        .option = &option_name,
                                        .kind = .invalid_placement,
                                    });
                                } else {
                                    try parseOption(Generic, result_arena_allocator, &result.options, args_iterator, error_handling, &last_error, real_name, null);
                                }

                                found = true;
                            }
                        }
                    }

                    if (MaybeVerb) |Verb| {
                        if (result.verb) |*verb| {
                            if (!found) {
                                const Tag = std.meta.Tag(Verb);
                                inline for (std.meta.fields(Verb)) |verb_info| {
                                    const VerbType = verb_info.type;
                                    if (comptime canHaveFieldsAndIsNotZeroSized(VerbType)) {
                                        if (verb.* == @field(Tag, verb_info.name)) {
                                            const target_value = &@field(verb.*, verb_info.name);
                                            if (@hasDecl(VerbType, "shorthands")) {
                                                any_shorthands = true;
                                                inline for (std.meta.fields(@TypeOf(VerbType.shorthands))) |fld| {
                                                    if (fld.name.len != 1)
                                                        @compileError("All shorthand fields must be exactly one character long!");
                                                    if (fld.name[0] == char) {
                                                        const real_name = @field(VerbType.shorthands, fld.name);
                                                        const real_fld_type = @TypeOf(@field(target_value.*, real_name));

                                                        // -2 because we stripped of the "-" at the beginning
                                                        if (requiresArg(real_fld_type) and index != item.len - 2) {
                                                            last_error = error.EncounteredUnexpectedArgument;
                                                            try error_handling.process(error.EncounteredUnexpectedArgument, Error{
                                                                .option = &option_name,
                                                                .kind = .invalid_placement,
                                                            });
                                                        } else {
                                                            try parseOption(VerbType, result_arena_allocator, target_value, args_iterator, error_handling, &last_error, real_name, null);
                                                        }
                                                        last_error = null; // we need to reset that error here, as it was set previously
                                                        found = true;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
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
                if (!any_shorthands) {
                    try error_handling.process(error.EncounteredUnsupportedArgument, Error{
                        .option = item,
                        .kind = .unsupported,
                    });
                }
            }
        } else {
            if (MaybeVerb) |Verb| {
                if (result.verb == null) {
                    inline for (std.meta.fields(Verb)) |fld| {
                        if (std.mem.eql(u8, item, fld.name)) {
                            // found active verb, default-initialize it
                            result.verb = @unionInit(Verb, fld.name, fld.type{});
                        }
                    }

                    if (result.verb == null) {
                        try error_handling.process(error.EncounteredUnknownVerb, Error{
                            .option = item,
                            .kind = .unknown_verb,
                        });
                    }

                    continue;
                }
            }

            try arglist.append(try result_arena_allocator.dupeZ(u8, item));
        }
    }

    if (last_error != null)
        return error.InvalidArguments;
    switch (error_handling) {
        .collect => |c| if (c.errors().len > 0)
            return error.InvalidArguments,
        else => {},
    }

    // This will consume the rest of the arguments as positional ones.
    // Only executes when the above loop is broken.
    while (args_iterator.next()) |item| {
        try arglist.append(try result_arena_allocator.dupeZ(u8, item));
    }

    result.positionals = try arglist.toOwnedSlice();
    return result;
}

fn canHaveFieldsAndIsNotZeroSized(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .error_set => @sizeOf(T) != 0,
        else => false,
    };
}

/// The return type of the argument parser.
pub fn ParseArgsResult(comptime Generic: type, comptime MaybeVerb: ?type) type {
    if (@typeInfo(Generic) != .@"struct")
        @compileError("Generic argument definition must be a struct");

    if (MaybeVerb) |Verb| {
        const ti: std.builtin.Type = @typeInfo(Verb);
        if (ti != .@"union" or ti.@"union".tag_type == null)
            @compileError("Verb must be a tagged union");
    }

    return struct {
        const Self = @This();

        /// Exports the type of options.
        pub const GenericOptions = Generic;
        pub const Verbs = MaybeVerb orelse void;

        arena: std.heap.ArenaAllocator,

        /// The options with either default or set values.
        options: Generic,

        /// The verb that was parsed or `null` if no first positional was provided.
        /// Is `void` when verb parsing is disabled
        verb: if (MaybeVerb) |Verb| ?Verb else void,

        /// The positional arguments that were passed to the process.
        positionals: [][:0]const u8,

        // The index of the first "raw arg", meaning the first arg after "--"
        raw_start_index: ?usize = null,

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
                .int, .float, .@"enum" => true,
                .bool => false,
                .@"struct", .@"union" => true,
                .pointer => true,
                else => @compileError(@typeName(Type) ++ " is not a supported argument type!"),
            };
        }
    };

    const ti = @typeInfo(T);
    if (ti == .optional) {
        return H.doesArgTypeRequireArg(ti.optional.child);
    } else {
        return H.doesArgTypeRequireArg(T);
    }
}

/// Parses a boolean option.
fn parseBoolean(str: []const u8) !bool {
    return switch (str.len) {
        1 => switch (str[0]) {
            'y', 'Y', 't', 'T' => true,
            'n', 'N', 'f', 'F' => false,
            else => error.NotABooleanValue,
        },
        2 => if (std.ascii.eqlIgnoreCase("no", str)) false else error.NotABooleanValue,
        3 => if (std.ascii.eqlIgnoreCase("yes", str)) true else error.NotABooleanValue,
        4 => if (std.ascii.eqlIgnoreCase("true", str)) true else error.NotABooleanValue,
        5 => if (std.ascii.eqlIgnoreCase("false", str)) false else error.NotABooleanValue,
        else => error.NotABooleanValue,
    };
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
            const pow: u3 = switch (buf[buf.len - 1]) {
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
                const base: T = if (base1024) 1024 else 1000;
                multiplier = try std.math.powi(T, base, @as(T, @intCast(pow)));
            }
        }
    }

    const ret: T = switch (@typeInfo(T).int.signedness) {
        .signed => try std.fmt.parseInt(T, buf, 0),
        .unsigned => try std.fmt.parseUnsigned(T, buf, 0),
    };

    return try std.math.mul(T, ret, multiplier);
}

test parseInt {
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
fn convertArgumentValue(comptime T: type, allocator: std.mem.Allocator, textInput: []const u8) !T {
    switch (@typeInfo(T)) {
        .optional => |opt| return try convertArgumentValue(opt.child, allocator, textInput),
        .bool => if (textInput.len > 0)
            return try parseBoolean(textInput)
        else
            return true, // boolean options are always true
        .int => return try parseInt(T, textInput),
        .float => return try std.fmt.parseFloat(T, textInput),
        .@"enum" => {
            if (@hasDecl(T, "parse")) {
                return try T.parse(textInput);
            } else {
                return std.meta.stringToEnum(T, textInput) orelse return error.InvalidEnumeration;
            }
        },
        .@"struct", .@"union" => {
            if (@hasDecl(T, "parse")) {
                return try T.parse(textInput);
            } else {
                @compileError(@typeName(T) ++ " has no public visible `fn parse([]const u8) !T`!");
            }
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (ptr.child != u8) {
                    @compileError(@typeName(T) ++ " is not a supported pointer type, only slices of u8 are supported");
                }

                // If the type contains a sentinel dupe the text input to a new buffer.
                // This is equivalent to allocator.dupeZ but works with any sentinel.
                if (comptime std.meta.sentinel(T)) |sentinel| {
                    const data = try allocator.alloc(u8, textInput.len + 1);
                    @memcpy(data[0..textInput.len], textInput);
                    data[textInput.len] = sentinel;

                    return data[0..textInput.len :sentinel];
                }

                // Otherwise the type is []const u8 so just return the text input.
                return textInput;
            },
            else => @compileError(@typeName(T) ++ " is not a supported pointer type!"),
        },
        else => @compileError(@typeName(T) ++ " is not a supported argument type!"),
    }
}

/// Parses an option value into the correct type.
fn parseOption(
    comptime Spec: type,
    arena: std.mem.Allocator,
    target_struct: *Spec,
    args: anytype,
    comptime error_handling: ErrorHandling,
    last_error: *?anyerror,
    /// The name of the option that is currently parsed.
    comptime name: []const u8,
    /// Optional pre-defined value for options that use `--foo=bar`
    value: ?[]const u8,
) !void {
    const field_type = @TypeOf(@field(target_struct, name));

    const final_value = if (value) |val| blk: {
        // use the literal value
        const res = try arena.dupeZ(u8, val);
        break :blk res;
    } else if (requiresArg(field_type)) blk: {
        // fetch from parser
        const val = args.next();
        if (val == null or std.mem.eql(u8, val.?, "--")) {
            last_error.* = error.MissingArgument;
            try error_handling.process(error.MissingArgument, Error{
                .option = "--" ++ name,
                .kind = .missing_argument,
            });
            return;
        }

        const res = try arena.dupeZ(u8, val.?);
        break :blk res;
    } else blk: {
        // argument is "empty"
        break :blk "";
    };

    @field(target_struct, name) = convertArgumentValue(field_type, arena, final_value) catch |err| {
        last_error.* = err;
        try error_handling.process(err, Error{
            .option = "--" ++ name,
            .kind = .{ .invalid_value = final_value },
        });
        // we couldn't parse the value, so we return a undefined value as we have signalled an
        // error and won't return this anyways.
        return;
    };
}

/// A collection of errors that were encountered while parsing arguments.
pub const ErrorCollection = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Error),

    pub fn init(allocator: std.mem.Allocator) Self {
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
        const dupe = Error{
            .option = try self.arena.allocator().dupe(u8, err.option),
            .kind = switch (err.kind) {
                .invalid_value => |v| Error.Kind{
                    .invalid_value = try self.arena.allocator().dupe(u8, v),
                },
                // flat copy
                .unknown, .out_of_memory, .unsupported, .invalid_placement, .missing_argument, .missing_executable_name, .unknown_verb => err.kind,
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
            .unknown_verb => try writer.print("Unknown verb '{s}'.", .{self.option}),
        }
    }

    pub const Kind = union(enum) {
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

        /// This error has the verb as an option name and will happen when a verb is provided that is not known.
        unknown_verb,
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

    /// Forwards the parsing error to a functionm
    forward: fn (err: Error) anyerror!void,

    /// Processes an error with the given handling method.
    fn process(comptime self: Self, src_error: anytype, err: Error) !void {
        if (@typeInfo(@TypeOf(src_error)) != .error_set)
            @compileError("src_error must be a error union!");
        switch (self) {
            .silent => return src_error,
            .print => try std.io.getStdErr().writer().print("{}\n", .{err}),
            .collect => |collection| try collection.insert(err),
            .forward => |func| try func(err),
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

var ec: ErrorCollection = undefined;
test ErrorCollection {
    var option_buf = "option".*;
    var invalid_buf = "invalid".*;

    ec = ErrorCollection.init(std.testing.allocator);
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

const TestIterator = struct {
    sequence: []const [:0]const u8,
    index: usize = 0,

    pub fn init(items: []const [:0]const u8) TestIterator {
        return TestIterator{ .sequence = items };
    }

    pub fn next(self: *@This()) ?[:0]const u8 {
        if (self.index >= self.sequence.len)
            return null;
        const result = self.sequence[self.index];
        self.index += 1;
        return result;
    }
};

const TestEnum = enum { default, special, slow, fast };

const TestGenericOptions = struct {
    output: ?[]const u8 = null,
    @"with-offset": bool = false,
    @"with-hexdump": bool = false,
    @"intermix-source": bool = false,
    numberOfBytes: ?i32 = null,
    signed_number: ?i64 = null,
    unsigned_number: ?u64 = null,
    mode: TestEnum = .default,

    // This declares short-hand options for single hyphen
    pub const shorthands = .{
        .S = "intermix-source",
        .b = "with-hexdump",
        .O = "with-offset",
        .o = "output",
    };
};

const TestVerb = union(enum) {
    magic: MagicOptions,
    booze: BoozeOptions,

    const MagicOptions = struct { invoke: bool = false };
    const BoozeOptions = struct {
        cocktail: bool = false,
        longdrink: bool = false,

        pub const shorthands = .{
            .c = "cocktail",
            .l = "longdrink",
        };
    };
};

test "basic parsing (no verbs)" {
    var titerator = TestIterator.init(&[_][:0]const u8{
        "--output",
        "foobar",
        "--with-offset",
        "--numberOfBytes",
        "-250",
        "--unsigned_number",
        "0xFF00FF",
        "positional 1",
        "--mode",
        "special",
        "positional 2",
    });
    var args = try parseInternal(TestGenericOptions, null, &titerator, std.testing.allocator, .print);
    defer args.deinit();

    try std.testing.expectEqual(@as(?[:0]const u8, null), args.executable_name);
    try std.testing.expect(void == @TypeOf(args.verb));
    try std.testing.expectEqual(@as(usize, 2), args.positionals.len);
    try std.testing.expectEqualStrings("positional 1", args.positionals[0]);
    try std.testing.expectEqualStrings("positional 2", args.positionals[1]);

    try std.testing.expectEqualStrings("foobar", args.options.output.?);

    try std.testing.expectEqual(@as(?i32, -250), args.options.numberOfBytes);
    try std.testing.expectEqual(@as(?u64, 0xFF00FF), args.options.unsigned_number);
    try std.testing.expectEqual(TestEnum.special, args.options.mode);

    try std.testing.expectEqual(@as(?i64, null), args.options.signed_number);

    try std.testing.expectEqual(true, args.options.@"with-offset");
    try std.testing.expectEqual(false, args.options.@"with-hexdump");
    try std.testing.expectEqual(false, args.options.@"intermix-source");
}

test "shorthand parsing (no verbs)" {
    var titerator = TestIterator.init(&[_][:0]const u8{
        "-o",
        "foobar",
        "-O",
        "--numberOfBytes",
        "-250",
        "--unsigned_number",
        "0xFF00FF",
        "positional 1",
        "--mode",
        "special",
        "positional 2",
    });
    var args = try parseInternal(TestGenericOptions, null, &titerator, std.testing.allocator, .print);
    defer args.deinit();

    try std.testing.expectEqual(@as(?[:0]const u8, null), args.executable_name);
    try std.testing.expect(void == @TypeOf(args.verb));
    try std.testing.expectEqual(@as(usize, 2), args.positionals.len);
    try std.testing.expectEqualStrings("positional 1", args.positionals[0]);
    try std.testing.expectEqualStrings("positional 2", args.positionals[1]);

    try std.testing.expectEqualStrings("foobar", args.options.output.?);

    try std.testing.expectEqual(@as(?i32, -250), args.options.numberOfBytes);
    try std.testing.expectEqual(@as(?u64, 0xFF00FF), args.options.unsigned_number);
    try std.testing.expectEqual(TestEnum.special, args.options.mode);

    try std.testing.expectEqual(@as(?i64, null), args.options.signed_number);

    try std.testing.expectEqual(true, args.options.@"with-offset");
    try std.testing.expectEqual(false, args.options.@"with-hexdump");
    try std.testing.expectEqual(false, args.options.@"intermix-source");
}

test "basic parsing (with verbs)" {
    var titerator = TestIterator.init(&[_][:0]const u8{
        "--output", // non-verb options can come before or after verb
        "foobar",
        "booze", // verb
        "--with-offset",
        "--numberOfBytes",
        "-250",
        "--unsigned_number",
        "0xFF00FF",
        "positional 1",
        "--mode",
        "special",
        "positional 2",
        "--cocktail",
    });
    var args = try parseInternal(TestGenericOptions, TestVerb, &titerator, std.testing.allocator, .print);
    defer args.deinit();

    try std.testing.expectEqual(@as(?[:0]const u8, null), args.executable_name);
    try std.testing.expect(?TestVerb == @TypeOf(args.verb));
    try std.testing.expectEqual(@as(usize, 2), args.positionals.len);
    try std.testing.expectEqualStrings("positional 1", args.positionals[0]);
    try std.testing.expectEqualStrings("positional 2", args.positionals[1]);

    try std.testing.expectEqualStrings("foobar", args.options.output.?);

    try std.testing.expectEqual(@as(?i32, -250), args.options.numberOfBytes);
    try std.testing.expectEqual(@as(?u64, 0xFF00FF), args.options.unsigned_number);
    try std.testing.expectEqual(TestEnum.special, args.options.mode);

    try std.testing.expectEqual(@as(?i64, null), args.options.signed_number);

    try std.testing.expectEqual(true, args.options.@"with-offset");
    try std.testing.expectEqual(false, args.options.@"with-hexdump");
    try std.testing.expectEqual(false, args.options.@"intermix-source");

    try std.testing.expect(args.verb.? == .booze);

    const booze = args.verb.?.booze;

    try std.testing.expectEqual(true, booze.cocktail);
    try std.testing.expectEqual(false, booze.longdrink);
}

test "basic error handling (with verbs)" {
    {
        var titerator = TestIterator.init(&[_][:0]const u8{
            "foobar", // Invalid verb
        });
        const args = parseInternal(
            TestGenericOptions,
            TestVerb,
            &titerator,
            std.testing.allocator,
            .silent,
        );
        try std.testing.expectError(error.EncounteredUnknownVerb, args);
    }

    {
        ec = ErrorCollection.init(std.testing.allocator);
        defer ec.deinit();
        var titerator = TestIterator.init(&[_][:0]const u8{
            "foobar", // Invalid verb
        });
        const args = parseInternal(
            TestGenericOptions,
            TestVerb,
            &titerator,
            std.testing.allocator,
            .{ .collect = &ec },
        );
        try std.testing.expectEqual(1, ec.errors().len);
        try std.testing.expectEqual(
            Error.Kind.unknown_verb,
            ec.errors()[0].kind,
        );
        try std.testing.expectError(error.InvalidArguments, args);
    }
}

test "shorthand parsing (with verbs)" {
    var titerator = TestIterator.init(&[_][:0]const u8{
        "booze", // verb
        "-o",
        "foobar",
        "-O",
        "--numberOfBytes",
        "-250",
        "--unsigned_number",
        "0xFF00FF",
        "positional 1",
        "--mode",
        "special",
        "positional 2",
        "-c", // --cocktail
    });
    var args = try parseInternal(TestGenericOptions, TestVerb, &titerator, std.testing.allocator, .print);
    defer args.deinit();

    try std.testing.expectEqual(@as(?[:0]const u8, null), args.executable_name);
    try std.testing.expect(?TestVerb == @TypeOf(args.verb));
    try std.testing.expectEqual(@as(usize, 2), args.positionals.len);
    try std.testing.expectEqualStrings("positional 1", args.positionals[0]);
    try std.testing.expectEqualStrings("positional 2", args.positionals[1]);

    try std.testing.expectEqualStrings("foobar", args.options.output.?);

    try std.testing.expectEqual(@as(?i32, -250), args.options.numberOfBytes);
    try std.testing.expectEqual(@as(?u64, 0xFF00FF), args.options.unsigned_number);
    try std.testing.expectEqual(TestEnum.special, args.options.mode);

    try std.testing.expectEqual(@as(?i64, null), args.options.signed_number);

    try std.testing.expectEqual(true, args.options.@"with-offset");
    try std.testing.expectEqual(false, args.options.@"with-hexdump");
    try std.testing.expectEqual(false, args.options.@"intermix-source");

    try std.testing.expect(args.verb.? == .booze);

    const booze = args.verb.?.booze;

    try std.testing.expectEqual(true, booze.cocktail);
    try std.testing.expectEqual(false, booze.longdrink);
}

test "strings with sentinel" {
    var titerator = TestIterator.init(&[_][:0]const u8{
        "--output",
        "foobar",
    });
    var args = try parseInternal(
        struct {
            output: ?[:0]const u8 = null,
        },
        null,
        &titerator,
        std.testing.allocator,
        .print,
    );
    defer args.deinit();

    try std.testing.expectEqual(@as(?[:0]const u8, null), args.executable_name);
    try std.testing.expect(void == @TypeOf(args.verb));
    try std.testing.expectEqual(@as(usize, 0), args.positionals.len);

    try std.testing.expectEqualStrings("foobar", args.options.output.?);
}

test "option argument --" {
    var titerator = TestIterator.init(&[_][:0]const u8{
        "--output",
        "--",
    });

    try std.testing.expectError(error.MissingArgument, parseInternal(
        struct {
            output: ?[:0]const u8 = null,
        },
        null,
        &titerator,
        std.testing.allocator,
        .silent,
    ));
}

test "index of raw indicator --" {
    var titerator = TestIterator.init(&[_][:0]const u8{ "stdin", "-", "--", "not-stdin", "-", "--" });

    var args = try parseInternal(
        struct {},
        null,
        &titerator,
        std.testing.allocator,
        .print,
    );
    defer args.deinit();

    try std.testing.expectEqual(args.raw_start_index, 2);
    try std.testing.expectEqual(args.positionals.len, 5);
}

fn reserved_argument(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "shorthands") or std.mem.eql(u8, arg, "meta");
}

pub fn printHelp(comptime Generic: type, name: []const u8, writer: anytype) !void {
    if (!@hasDecl(Generic, "meta")) {
        @compileError("Missing meta declaration in Generic");
    }

    const Meta = @TypeOf(Generic.meta);

    try writer.print("Usage: {s}", .{name});

    if (@hasField(Meta, "usage_summary")) {
        try writer.print(" {s}", .{Generic.meta.usage_summary});
    }
    try writer.print("\n\n", .{});

    if (@hasField(Meta, "full_text")) {
        try writer.print("{s}\n\n", .{Generic.meta.full_text});
    }

    if (@hasField(Meta, "option_docs")) {
        const fields = std.meta.fields(Generic);

        try writer.print("Options:\n", .{});
        comptime var maxOptionLength = 0;
        inline for (fields) |field| {
            if (!reserved_argument(field.name)) {
                if (!@hasField(@TypeOf(Generic.meta.option_docs), field.name)) {
                    @compileError("option_docs not specified for field: " ++ field.name);
                }
            }

            if (field.name.len > maxOptionLength) {
                maxOptionLength = field.name.len;
            }
        }

        inline for (fields) |field| {
            if (!reserved_argument(field.name)) {
                if (@hasDecl(Generic, "shorthands")) {
                    var foundShorthand = false;
                    inline for (std.meta.fields(@TypeOf(Generic.shorthands))) |shorthand| {
                        const option = @field(Generic.shorthands, shorthand.name);
                        if (std.mem.eql(u8, option, field.name)) {
                            try writer.print("  -{s}, ", .{shorthand.name});
                            foundShorthand = true;
                        }
                    }
                    if (!foundShorthand)
                        try writer.print("      ", .{});
                }
                if (@hasDecl(Generic, "wrap_len")) {
                    var it = std.mem.splitScalar(u8, @field(Generic.meta.option_docs, field.name), ' ');
                    const threshold = Generic.wrap_len;
                    var line_len: usize = 0;
                    var newline = false;
                    var first = true;
                    while (it.next()) |word| {
                        if (first) {
                            const fmtString = std.fmt.comptimePrint("--{{s: <{}}}   {{s}}", .{maxOptionLength});
                            try writer.print(fmtString, .{ field.name, word });
                            first = false;
                        } else if (newline) {
                            const fmtString = std.fmt.comptimePrint("\n{{s: <{}}} {{s}}", .{maxOptionLength + 10});
                            try writer.print(fmtString, .{ " ", word });
                            newline = false;
                        } else {
                            try writer.print(" {s}", .{word});
                        }
                        line_len += word.len;
                        if (line_len >= threshold) {
                            newline = true;
                            line_len = 0;
                        }
                    }
                    try writer.writeByte('\n');
                } else {
                    const fmtString = std.fmt.comptimePrint("--{{s: <{}}}   {{s}}\n", .{maxOptionLength});
                    try writer.print(fmtString, .{ field.name, @field(Generic.meta.option_docs, field.name) });
                }
            }
        }
    }
}

test "full help" {
    const Options = struct {
        boolflag: bool = false,
        stringflag: []const u8 = "hello",

        pub const shorthands = .{
            .b = "boolflag",
        };

        pub const meta = .{
            .name = "test",
            .full_text = "testing tool",
            .usage_summary = "[--boolflag] [--stringflag]",
            .option_docs = .{
                .boolflag = "a boolean flag",
                .stringflag = "a string flag",
            },
        };
    };

    var test_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer test_buffer.deinit();

    try printHelp(Options, "test", test_buffer.writer());

    const expected =
        \\Usage: test [--boolflag] [--stringflag]
        \\
        \\testing tool
        \\
        \\Options:
        \\  -b, --boolflag     a boolean flag
        \\      --stringflag   a string flag
        \\
    ;

    try std.testing.expectEqualStrings(expected, test_buffer.items);
}

test "help with no usage summary" {
    const Options = struct {
        boolflag: bool = false,
        stringflag: []const u8 = "hello",

        pub const shorthands = .{
            .b = "boolflag",
        };

        pub const meta = .{
            .full_text = "testing tool",
            .option_docs = .{
                .boolflag = "a boolean flag",
                .stringflag = "a string flag",
            },
        };
    };

    var test_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer test_buffer.deinit();

    try printHelp(Options, "test", test_buffer.writer());

    const expected =
        \\Usage: test
        \\
        \\testing tool
        \\
        \\Options:
        \\  -b, --boolflag     a boolean flag
        \\      --stringflag   a string flag
        \\
    ;

    try std.testing.expectEqualStrings(expected, test_buffer.items);
}

test "help with wrapping" {
    const Options = struct {
        boolflag: bool = false,
        stringflag: []const u8 = "hello",

        pub const shorthands = .{
            .b = "boolflag",
        };

        pub const wrap_len = 10;

        pub const meta = .{
            .full_text = "testing tool",
            .option_docs = .{
                .boolflag = "a boolean flag with a pretty long description about booleans",
                .stringflag = "a string flag with another long description about strings",
            },
        };
    };

    var test_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer test_buffer.deinit();

    try printHelp(Options, "test", test_buffer.writer());

    const expected =
        \\Usage: test
        \\
        \\testing tool
        \\
        \\Options:
        \\  -b, --boolflag     a boolean flag
        \\                     with a pretty
        \\                     long description
        \\                     about booleans
        \\      --stringflag   a string flag
        \\                     with another
        \\                     long description
        \\                     about strings
        \\
    ;

    try std.testing.expectEqualStrings(expected, test_buffer.items);
}
