//! Parse CLI arguments for subcommands specified as Zig `struct` or `union(enum)`:
//!
//! It is pretty much taken from the tigerbeetle project.
//! https://github.com/tigerbeetle/tigerbeetle/blob/16d62f0ce7d4ef3db58714c9b7a0c46480c19bc3/src/flags.zig
//!
//! I modified to fit my needs and my coding style and, subjectively, made it better for me.
//! eg.
//! * I removed a lot of comptime asserts and made them @compileError's instead as I prefer the more human readable error messages
//! * I added help flags to commands in addition to the help flag for the program
//! * I prefer the zig style nameing convention for function names as i like to do things like `const default_value = defaultValue(xyz);`
//! * Added floating point numbers
//!
//! - `union` is treated as commands
//! - `struct` is treated as options
//! - all fields without a default value are required to be provided
//! - parsing errors are fatal and will exit the program with a non zero exit code and print the error message to stderr
//! - In a `struct` the `positional` field is treated specially, it designates positional arguments and must have the field name `positional` and must be a struct.
//! - `positional` fields should not have an underscore in the name
//! - The parser supports by default the following types:
//!      * `bool`
//!      * integers (`u8` - `u128`, `i8` - `i128`)
//!      * floats
//!      * `enum`
//!      * `[]const u8` and `[:0]const u8`
//!      * `optional` of the above types
//! - boolean fields must have a `false` default value. The flag appearing will set it to `true`
//! - Optional fields are required to have a default value and the default value must be null
//! - Positional arguments that have no default values cannot follow fields with defaults. Just like in python functions.
//! - `enum` fields must have atleast 2 possible enum values and must be exhaustive
//! - If `pub const help` declaration is present, it is used to implement `-h/--help` argument.
//!
//! If the flag has a custom type that is not supported with the default parsing options. It is possible to
//! assign the field a type which has a function named `parseFlagValue` and contains the data you need.
//! The function must have the following signature:
//! ```
//! /// gpa: Allocator to be used by the parseFlagValue function. The user is responsible for managing the lifetime of the memory allocated by the parseFlagValue function.
//! /// flag_value: The parsed value of command line argument
//! /// error_out: A pointer to a string describing the error. If the function returns an error this parameter must be set to a string describing the error.
//! /// FlagType: The type of the flag it is parsing usually @This()
//! struct {
//!     pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {}
//! }
//! ```
//!
//! @IMPORTANT Requrements for this function:
//! 1. It must return an error if the value is determined to be invalid.
//! 2. If it returns an error it must set the error_out parameter to a string describing the error. The flag parser
//! will not free the memory of the string so it is recommended to use a statically allocated string.
//! 3. If parsed value is returned the error_out paramater must remain null.
//! 4. If the parseFlagValue function allocates memory it is up to the user to handle the lifetime of the memory.
//!
//! Example:
//! ```zig
//! const stdx = @import("stdx");
//! const flags = stdx.flags;
//!
//! const CLIArgs = union(enum) {
//!     init: struct {
//!         bare: bool = false,
//!         integer: i32 = 0,
//!         enum_value: enum { foo, bar } = .foo,
//!         positional: struct {
//!             directory: ?[]const u8 = null,
//!         },
//!
//!         pub const help =
//!             \\Usage: program init [--bare] [--integer=<integer>] [--enum=<foo|bar>] <directory>
//!             \\
//!             \\Description
//!             \\
//!             \\Options:
//!             \\  --bare  Creates a bare project without subfolders and tracking files.
//!             \\  --integer  An integer flag
//!             \\  --enum  An enum flag
//!             \\  <directory>  The directory to initialize the project in. Defaults to the current directory.
//!             \\
//!          ;
//!     },
//!     another: struct {
//!         foo: struct {
//!             list: []const []const u8,
//!
//!             pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
//!                 if (flag_value.len == 0) {
//!                     error_out.* = "Empty list";
//!                     return error.Invalid;
//!                 }
//!                 const count: usize = std.mem.countScalar(u8, flag_value, ',');
//!                 var items = std.mem.splitScalar(u8, flag_value, ',');
//!                 const list = gpa.alloc([]const u8, count + 1) catch {
//!                     error_out.* = "Failed to allocate list";
//!                     return error.Invalid;
//!                 };
//!                 errdefer gpa.free(tag_list);
//!
//!                 for (0..count + 1) |index| {
//!                     const item = items.next().?;
//!                     if (item.len == 0) {
//!                         error_out.* = "Empty item in list";
//!                         return error.Invalid;
//!                     }
//!                     list[index] = item;
//!                 }
//!                 return .{ .list = list };
//!             }
//!         }
//!
//!         pub const help =
//!             \\Usage: program another --foo="<item1>,<item2>,..."
//!             \\
//!             \\Description
//!             \\
//!             \\Options:
//!             \\  --foo  A foo flag with a list of items
//!             \\
//!         ;
//!     },
//!
//!
//!     pub const help =
//!         \\Usage:
//!         \\
//!         \\    program [-h | --help]
//!         \\
//!         \\    program init [-h | --help] [--bare] [--integer=<integer>] [--enum=<foo|bar>] <directory>
//!         \\
//!         \\    program another [-h | --help] --foo="<item1>,<item2>,..."
//!         \\
//!         \\Commands:
//!         \\    init     Some init command
//!         \\    another  Another command
//!         \\
//!         \\Options:
//!         \\    -h, --help
//!         \\        Prints this help message.
//!         \\
//!      ;
//! }
//!
//! pub fn main() !void {
//!     const args = try std.process.argsAlloc(std.heap.page_allocator);
//!     defer std.process.argsFree(std.heap.page_allocator, args);
//!
//!
//!     const cli_args: CLIArgs = parse_commands(&args, CLIArgs);
//!     switch (cli_args) {
//!         .init => |init_args| { ... },
//!         .something => |something_args| { ... },
//!     }
//! }
//! ```
//!
//! @TODO
//!     - GILA(remove_beast_7qh) Decide if providing an argument multiple times is a good idea
//!     - GILA(tan_beast_2ag) Add tests
//!     - GILA(fatherly_axe_dtd) Consider adding true default for booleans and disabling with --no-<flag>
//!
//! @REVISION
//!     0.4 - Added inline assertion instead of using std.debug.assert
//!     0.3 - Moved to zig 0.16 Args
//!         - Changed type creations to reflect new system using @Struct instead of @Type
//!     0.2 - Added allocator to parseFlagValue function definition
//!     0.1 - Initial version

const std = @import("std");

const builtin = @import("builtin");
//https://github.com/ghostty-org/ghostty/blob/26e243a9194f8653e0b44cf00b600629fcee8f46/src/quirks.zig
pub const assert = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseFast, .ReleaseSafe, .ReleaseSmall => struct {
        inline fn assert(cond: bool) void {
            if (!cond) unreachable;
        }
    }.assert,
};

const MAX_ARGS = 128;
const flag_parse_function_name = "parseFlagValue";

const log = std.log.scoped(.args_parser);

var local_arena: std.mem.Allocator = undefined;

/// Parse CLI arguments for subcommands specified as Zig `struct` or `union(enum)`:
///
/// ```
/// const stdx = @import("stdx");
/// const flags = stdx.flags;
///
/// const CLIArgs = union(enum) {
///     init: struct {
///         bare: bool = false,
///         integer: i32 = 0,
///         enum_value: enum { foo, bar } = .foo,
///         positional: struct {
///             directory: ?[]const u8 = null,
///         },
///
///         pub const help =
///             \\Usage: program init [--bare] [--integer=<integer>] [--enum=<foo|bar>] <directory>
///             \\
///             \\Description
///             \\
///             \\Options:
///             \\  --bare  Creates a bare project without subfolders and tracking files.
///             \\  --integer  An integer flag
///             \\  --enum  An enum flag
///             \\  <directory>  The directory to initialize the project in. Defaults to the current directory.
///             \\
///          ;
///     },
///     another: struct {
///         foo: struct {
///             list: []const []const u8,
///
///             pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
///                 if (flag_value.len == 0) {
///                     error_out.* = "Empty list";
///                     return error.Invalid;
///                 }
///                 const count: usize = std.mem.countScalar(u8, flag_value, ',');
///                 var items = std.mem.splitScalar(u8, flag_value, ',');
///                 const list = gpa.alloc([]const u8, count + 1) catch {
///                     error_out.* = "Failed to allocate list";
///                     return error.Invalid;
///                 };
///                 errdefer gpa.free(tag_list);
///
///                 for (0..count + 1) |index| {
///                     const item = items.next().?;
///                     if (item.len == 0) {
///                         error_out.* = "Empty item in list";
///                         return error.Invalid;
///                     }
///                     list[index] = item;
///                 }
///                 return .{ .list = list };
///             }
///         }
///
///         pub const help =
///             \\Usage: program another --foo="<item1>,<item2>,..."
///             \\
///             \\Description
///             \\
///             \\Options:
///             \\  --foo  A foo flag with a list of items
///             \\
///         ;
///     },
///
///
///     pub const help =
///         \\Usage:
///         \\
///         \\    program [-h | --help]
///         \\
///         \\    program init [-h | --help] [--bare] [--integer=<integer>] [--enum=<foo|bar>] <directory>
///         \\
///         \\    program another [-h | --help] --foo="<item1>,<item2>,..."
///         \\
///         \\Commands:
///         \\    init     Some init command
///         \\    another  Another command
///         \\
///         \\Options:
///         \\    -h, --help
///         \\        Prints this help message.
///         \\
///      ;
/// }
///
/// pub fn main() !void {
///     const args = try std.process.argsAlloc(std.heap.page_allocator);
///     defer std.process.argsFree(std.heap.page_allocator, args);
///
///
///     const cli_args: CLIArgs = parse_commands(&args, CLIArgs);
///     switch (cli_args) {
///         .init => |init_args| { ... },
///         .something => |something_args| { ... },
///     }
/// }
/// ```
///
/// The parser supports by default the following types:
/// * `bool`
/// * integers (`u8` - `u128`, `i8` - `i128`)
/// * floats
/// * `enum`
/// * `[]const u8` and `[:0]const u8`
/// * `optional` of the above types
///
/// `positional` field is treated specially, it designates positional arguments and must have the field name `positional` and must be a struct.
///
/// If `pub const help` declaration is present, it is used to implement `-h/--help` argument.
///
/// If the flag has a custom type that is not supported with the default parsing options. It is possible to
/// assign the field a type which has a function named `parseFlagValue` and contains the data you need.
/// The function must have the following signature:
/// ```
/// /// gpa: Allocator to be used by the parseFlagValue function. The user is responsible for managing the lifetime of the memory allocated by the parseFlagValue function.
/// /// flag_value: The parsed value of command line argument
/// /// error_out: A pointer to a string describing the error. If the function returns an error this parameter must be set to a string describing the error.
/// /// FlagType: The type of the flag it is parsing usually @This()
/// struct {
///     pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {}
/// }
/// ```
///
/// @IMPORTANT Requrements for this function:
/// 1. It must return an error if the value is determined to be invalid.
/// 2. If it returns an error it must set the error_out parameter to a string describing the error. The flag parser
/// will not free the memory of the string so it is recommended to use a statically allocated string.
/// 3. If parsed value is returned the error_out paramater must remain null.
/// 4. If the parseFlagValue function allocates memory it is up to the user to handle the lifetime of the memory.
pub fn parseArgs(
    io: std.Io,
    /// Allocator used to forward to the parseFlagValue function of the custom types in case they need to allocate memory for their own needs.
    /// The user is responsible for managing the lifetime of the memory allocated by the parseFlagValue function.
    arena: std.mem.Allocator,
    args: *std.process.Args.Iterator,
    /// The type of the arguments to parse. Must be a struct or union
    comptime ArgType: type,
) ArgType {
    // @NOTE: Skip the first argument, which is the program name.
    assert(args.skip());
    // @NOTE This is the only entry point into parsing the arguments so local_gpa will always be set before
    // any calls to custom parseFlagValue functions.
    local_arena = arena;
    return parseFlags(io, args, ArgType);
}

fn parseFlags(io: std.Io, args: *std.process.Args.Iterator, comptime Flags: type) Flags {
    @setEvalBranchQuota(5_000);
    if (Flags == void) {
        if (args.next()) |arg| {
            logFatal("Unexpected argument '{s}'", .{arg});
        }
        return {};
    }

    if (@typeInfo(Flags) == .@"union") {
        return parseCommand(io, args, Flags);
    }

    if (@typeInfo(Flags) != .@"struct") {
        @compileError("Expected struct type, found '" ++ @typeName(Flags) ++ "' when parsing flags");
    }

    comptime var parsed_fields = parseStructFields(Flags);

    // @NOTE We can have flags with the same prefix like --foo-bar and --foo. So to make sure we parse them correctly
    // We need to sort the fields by longest name first so that we can check if the given argument is a prefix of a flag.
    // This way we ensure that when we check against --foo we have already checked against --foo-bar.
    comptime std.mem.sort(Type.StructField, parsed_fields.fields[0..parsed_fields.field_count], {}, struct {
        fn lessThan(context: void, l: Type.StructField, r: Type.StructField) bool {
            _ = context;
            const lhs = comptime std.mem.span(l.name.ptr);
            const rhs = comptime std.mem.span(r.name.ptr);

            if (lhs.len > rhs.len) {
                return true;
            } else if (lhs.len < rhs.len) {
                return false;
            }
            const n = @min(lhs.len, rhs.len);
            for (lhs[0..n], rhs[0..n]) |lhs_elem, rhs_elem| {
                switch (std.math.order(lhs_elem, rhs_elem)) {
                    .eq => continue,
                    .lt => return false,
                    .gt => return true,
                }
            }
            return std.math.order(lhs.len, rhs.len) == .gt;
        }
    }.lessThan);

    // @NOTE We need to store if, while parsing the fields, we encountered a particular flag or not. We can set the fields
    // that did not recieve an argument to their default values and also catch multiple entries for the same flag.
    var counts = comptime blk: {
        var count_fields = std.meta.fields(Flags)[0..std.meta.fields(Flags).len].*;
        var names: [count_fields.len][]const u8 = undefined;
        var types: [count_fields.len]type = undefined;
        var attributes: [count_fields.len]Type.StructField.Attributes = undefined;
        for (&count_fields, 0..) |*field, i| {
            names[i] = field.name;
            types[i] = u32;
            attributes[i] = .{
                .@"align" = @alignOf(u32),
                .default_value_ptr = @ptrCast(&@as(u32, 0)),
            };
        }
        break :blk @Struct(.auto, null, names[0..], &types, &attributes){};
    };

    const flag_names = comptime blk: {
        var names: [parsed_fields.field_count][]const u8 = undefined;
        for (parsed_fields.fields[0..parsed_fields.field_count], 0..) |field, i| {
            var name: []const u8 = "--";
            var index: usize = 0;
            while (std.mem.findScalar(u8, field.name[index..], '_')) |pos| {
                name = name ++ field.name[index..][0..pos] ++ "-";
                index += pos + 1;
            }
            name = name ++ field.name[index..];
            names[i] = name;
        }
        break :blk names;
    };

    var parsed_positional: bool = false;
    var result: Flags = undefined;

    var parsed_args: usize = 0;

    parsing_next_arg: for (0..MAX_ARGS) |_| {
        const arg = args.next() orelse break :parsing_next_arg;
        if (@hasDecl(Flags, "help") and parsed_args == 0) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                var stdout = std.Io.File.stdout().writer(io, &.{});
                const interface = &stdout.interface;
                interface.writeAll(Flags.help) catch std.process.exit(1);
                interface.writeAll("\n") catch std.process.exit(1);
                std.process.exit(0);
            }
        }
        comptime var field_length_previous: usize = std.math.maxInt(usize);
        inline for (parsed_fields.fields[0..parsed_fields.field_count], 0..) |field, index| {
            comptime assert(field_length_previous >= field.name.len);
            field_length_previous = field.name.len;

            if (std.mem.startsWith(u8, arg, flag_names[index])) {
                if (parsed_positional) {
                    logFatal("Unexpected argument '{s}' after positional arguments", .{arg});
                }
                @field(counts, field.name) += 1;
                const value = parseFlag(field.type, flag_names[index], arg);
                @field(result, field.name) = value;
                parsed_args += 1;
                continue :parsing_next_arg;
            }
        }
        if (@hasField(Flags, "positional")) {
            counts.positional += 1;
            switch (counts.positional - 1) {
                inline 0...parsed_fields.positional_fields.len - 1 => |index| {
                    const positional_field = parsed_fields.positional_fields[index];
                    if (comptime std.mem.findScalar(u8, positional_field.name, '_') != null) {
                        @compileError("Positional field '" ++ positional_field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have no underscores.");
                    }
                    if (arg.len == 0) {
                        logFatal("Positional argument <{s}> is missing", .{positional_field.name});
                    }
                    if (arg[0] == '-') {
                        logFatal("Unexpected argument '{s}'", .{arg});
                    }
                    parsed_positional = true;
                    @field(result.positional, positional_field.name) = parseFlagValue(positional_field.type, "positional." ++ positional_field.name, arg, true);

                    continue :parsing_next_arg;
                },
                else => {
                    // @NOTE This will cause excess posistional arguments to fall through to the error as it is essentially an unexpected argument
                },
            }
        }
        logFatal("Unexpected argument '{s}'", .{arg});
    } else {
        logFatal("Struct '{s}' has too many fields. Current maximum is {d}. If you really need more(why) just increase MAX_ARGS in flags.zig", .{
            @typeName(Flags),
            MAX_ARGS,
        });
    }

    // @NOTE We now go through all the fields and check if any have not been set and set them to their default values.
    inline for (parsed_fields.fields[0..parsed_fields.field_count], 0..) |field, i| {
        const flag_name = flag_names[i];
        switch (@field(counts, field.name)) {
            0 => {
                if (defaultValue(field)) |v| {
                    @field(result, field.name) = v;
                } else {
                    logFatal("Flag '{s}' is required", .{flag_name});
                }
            },
            1 => {},
            else => {
                // @TODO Should this be allowed and the last value be used?
                logFatal("Flag '{s}' is specified multiple times", .{flag_name});
            },
        }
    }

    if (@hasField(Flags, "positional")) {
        assert(counts.positional <= parsed_fields.positional_fields.len);
        inline for (parsed_fields.positional_fields, 0..) |positional_field, index| {
            if (index >= counts.positional) {
                if (defaultValue(positional_field)) |v| {
                    @field(result.positional, positional_field.name) = v;
                } else {
                    logFatal("Positional argument <{s}> is required", .{positional_field.name});
                }
            }
        }
    }

    return result;
}

fn parseCommand(io: std.Io, args: *std.process.Args.Iterator, comptime Command: type) Command {
    const info = @typeInfo(Command);
    if (info != .@"union") {
        @compileError("Expected union type, found '" ++ @typeName(Command) ++ "' when parsing command");
    }
    if (info.@"union".fields.len == 0) {
        @compileError("Expected at least 1 field in union type '" ++ @typeName(Command) ++ "' when parsing command");
    }
    // @TODO Should there be enforcement that if command has only 1 field then it should have been a struct?
    //       This would be a compile error. But i personally dont think it is a good idea especially when you are developing
    //       a cli. You dont have all the commands in at the start. If only there was a compile warning for this.
    if (info.@"union".fields.len == 1) {
        log.warn("Command union '{s}' only has 1 field. This should probably be a struct", .{@typeName(Command)});
    }

    const command: []const u8 = args.next() orelse {
        if (@hasDecl(Command, "help")) {
            var stdout = std.Io.File.stdout().writer(io, &.{});
            const interface = &stdout.interface;
            interface.writeAll(Command.help) catch std.process.exit(1);
            interface.writeAll("\n") catch std.process.exit(1);
        }
        logFatal("Expected a command", .{});
    };

    // @NOTE If you want to add a help flag to your command, add the following to the command struct:
    // pub const help =
    //     \\Usage: command [--help]
    //     \\
    //     \\Description of the command.
    //     \\
    //     \\Options:
    //     \\  --help  Prints this help message.
    // ;
    //
    // It ***MUST*** be a marked pub to be visable to print.
    if (@hasDecl(Command, "help")) {
        if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
            var stdout = std.Io.File.stdout().writer(io, &.{});
            const interface = &stdout.interface;
            interface.writeAll(Command.help) catch std.process.exit(1);
            std.process.exit(0);
        }
    }

    inline for (info.@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, command)) {
            return @unionInit(
                Command,
                field.name,
                parseFlags(io, args, field.type),
            );
        }
    }
    logFatal("Unknown command '{s}'", .{command});
    unreachable;
}

fn parseFlag(comptime Flag: type, flag_name: []const u8, arg: [:0]const u8) Flag {
    assert(flag_name[0] == '-');
    assert(flag_name[1] == '-');
    assert(std.mem.startsWith(u8, arg, flag_name));

    if (Flag == bool) {
        if (std.mem.eql(u8, flag_name, arg)) {
            return true;
        } else {
            logFatal("Boolean flag '{s}' requires no argument", .{flag_name});
        }
    }

    const value: [:0]const u8 = split_value: {
        var result = arg[flag_name.len..];
        if (result.len == 0) {
            logFatal("Flag '{s}' requires an argument, but none was provided", .{flag_name});
        }
        if (result[0] == '=') {
            result = result[1..];
        } else {
            logFatal("Flag '{s}': expected '=' after argument but found '{c}' in '{s}'", .{ flag_name, result[0], arg });
        }

        if (result.len == 0) {
            logFatal("Flag '{s}': no result provided after '=' in '{s}'", .{ flag_name, arg });
        }
        break :split_value result;
    };
    return parseFlagValue(Flag, flag_name, value, false);
}

fn parseFlagValue(comptime Flag: type, flag_name: []const u8, flag_value: [:0]const u8, comptime is_positional: bool) Flag {
    assert((flag_name[0] == '-' and flag_name[1] == '-') or is_positional);
    assert(flag_value.len > 0);
    assert(Flag != bool);

    const Value = switch (@typeInfo(Flag)) {
        .optional => |info| info.child,
        else => Flag,
    };

    if (Value == []const u8 or Value == [:0]const u8) {
        return flag_value;
    }

    if (@typeInfo(Value) == .int) {
        return std.fmt.parseInt(Value, flag_value, 10) catch |err| switch (err) {
            error.Overflow => logFatal("Flag '{s}': value '{s}' exceeds bounds of type '{s}'", .{ flag_name, flag_value, @typeName(Value) }),
            error.InvalidCharacter => logFatal("Flag '{s}': value '{s}' is not a valid integer literal", .{ flag_name, flag_value }),
            else => unreachable,
        };
    }

    if (@typeInfo(Value) == .float) {
        return std.fmt.parseFloat(Value, flag_value) catch |err| switch (err) {
            error.InvalidCharacter => logFatal("Flag '{s}': value '{s}' is not a valid float literal", .{ flag_name, flag_value }),
            else => unreachable,
        };
    }

    if (@typeInfo(Value) == .@"enum") {
        comptime assert(@typeInfo(Value).@"enum".is_exhaustive);

        return std.meta.stringToEnum(Value, flag_value) orelse {
            const valid_values = comptime blk: {
                var valid_values: []const u8 = &.{};
                for (@typeInfo(Value).@"enum".fields) |field| {
                    valid_values = valid_values ++ "\n" ++ field.name ++ ",";
                }
                break :blk valid_values;
            };
            logFatal(
                "Flag '{s}': value '{s}' is not a valid enum literal of type '{s}'. Valid values are: {s}",
                .{ flag_name, flag_value, @typeName(Value), valid_values },
            );
        };
    }

    if (@hasDecl(Value, flag_parse_function_name)) {
        const ParseFn = fn (gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!Value;
        const parse_fn: ParseFn = @field(Value, flag_parse_function_name);
        var error_out: ?[]const u8 = null;
        // @IMPORTANT Requrements for parse_fn:
        //     1. It must return an error if the value is determined to be invalid.
        //     2. If it returns an error it must set the error_out parameter to a string describing the error. The flag parser
        //     will not free the memory of the string so it is recommended to use a statically allocated string.
        //     3. If parsed value is returned the error_out paramater must remain null.
        //     4. If the parseFlagValue function allocates memory it is up to the user to handle the lifetime of the memory.
        const value = parse_fn(local_arena, flag_value, &error_out) catch {
            if (error_out) |err_out| {
                logFatal("Flag '{s}': value '{s}' is not a valid value for type '{s}' to parse: {s}", .{ flag_name, flag_value, @typeName(Value), err_out });
            } else {
                logFatal("Flag '{s}': returned error.Invalid but did not set error_out. This is illegal behaviour.", .{flag_name});
            }
        };
        if (error_out) |err_out| {
            logFatal("Flag '{s}' of type '{s}' returned diagnostics for error without returning an error: {s}", .{ flag_name, @typeName(Value), err_out });
        }
        return value;
    }

    comptime unreachable;
}

const Type = std.builtin.Type;
fn parseStructFields(comptime Flags: type) struct {
    fields: [std.meta.fields(Flags).len]Type.StructField,
    field_count: usize,
    positional_fields: []const Type.StructField,
} {
    const info = @typeInfo(Flags).@"struct";
    comptime var fields: [info.fields.len]Type.StructField = undefined;
    comptime var field_count: usize = 0;
    comptime var positional_fields: []const Type.StructField = &.{};
    for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "positional")) {
            if (@typeInfo(field.type) != .@"struct") {
                @compileError("Positional field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must be a struct type.");
            }
            positional_fields = @typeInfo(field.type).@"struct".fields;
            var found_first_optional_with_no_default_value: bool = false;

            for (positional_fields) |positional_field| {
                const default_value = defaultValue(positional_field);
                if (defaultValue(positional_field)) |_| {
                    found_first_optional_with_no_default_value = true;
                } else {
                    // @NOTE Like in python functions, values with no defaults cannot follow fields with defaults.
                    if (found_first_optional_with_no_default_value) {
                        @compileError("Positional field '" ++ positional_field.name ++ "' in struct '" ++ @typeName(field.type) ++ "' has no default value but follows fields that have defaults. Like in python functions, fields with no defaults cannot follow fields with defaults.");
                    }
                }

                switch (@typeInfo(positional_field.type)) {
                    .optional => {
                        // @NOTE Optionals must have a default value and the default value must be null
                        if (default_value) |v| {
                            if (v != null) {
                                @compileError("Optional field '" ++ positional_field.name ++ "' in struct '" ++ @typeName(Flags) ++ ".positional' must have a default `null` value.");
                            }
                        } else {
                            @compileError("Optional field '" ++ positional_field.name ++ "' in struct '" ++ @typeName(Flags) ++ ".positional' must have a default `null` value.");
                        }
                    },
                    else => {},
                }

                checkField(positional_field, field.type);
            }

            continue;
        }
        fields[field_count] = field;
        field_count += 1;

        switch (@typeInfo(field.type)) {
            .bool => {
                // @NOTE Bools must have a default value and the default value must be false
                const default_value = defaultValue(field);
                if (default_value) |v| {
                    if (v != false) {
                        @compileError("Boolean field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have a default `false` value.");
                    }
                } else {
                    @compileError("Boolean field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have a default `false` value.");
                }
            },
            .optional => {
                // @NOTE Optionals must have a default value and the default value must be null
                const default_value = defaultValue(field);

                if (default_value) |v| {
                    if (v != null) {
                        @compileError("Optional field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have a default `null` value.");
                    }
                } else {
                    @compileError("Optional field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have a default `null` value.");
                }

                checkField(field, Flags);
            },
            else => {
                checkField(field, Flags);
            },
        }
    }
    return .{
        .fields = fields,
        .field_count = field_count,
        .positional_fields = positional_fields,
    };
}

fn checkField(comptime field: std.builtin.Type.StructField, @"struct": type) void {
    if (field.type == []const u8 or field.type == [:0]const u8 or @typeInfo(field.type) == .int or @typeInfo(field.type) == .float) {
        return;
    }

    if (@typeInfo(field.type) == .@"struct" and @hasDecl(field.type, flag_parse_function_name)) {
        return;
    }

    if (@typeInfo(field.type) == .@"enum") {
        const info = @typeInfo(field.type).@"enum";
        if (!info.is_exhaustive) {
            @compileError("Field '" ++ field.name ++ "' in struct '" ++ @typeName(@"struct") ++ "' of type '" ++ @typeName(field.type) ++ "' must have an exhaustive Enum type.");
        }
        if (info.fields.len < 2) {
            const err = std.fmt.comptimePrint("Field '" ++ field.name ++ "' in struct '" ++ @typeName(@"struct") ++ "' of type '" ++ @typeName(field.type) ++ "' must have at least 2 possible enum values. Has {}", .{info.fields.len});
            @compileError(err);
        }
        return;
    }

    if (@typeInfo(field.type) == .optional) {
        const info = @typeInfo(field.type).optional;
        const child = @typeInfo(info.child);

        if (info.child == []const u8 or info.child == [:0]const u8 or child == .int or child == .float) {
            return;
        }
        if (child == .@"enum") {
            const info_enum = @typeInfo(info.child).@"enum";
            if (!info_enum.is_exhaustive) {
                @compileError("Field '" ++ field.name ++ "' in struct '" ++ @typeName(@"struct") ++ "' of type '" ++ @typeName(field.type) ++ "' must have an exhaustive Enum type.");
            }
            if (info_enum.fields.len < 2) {
                const err = std.fmt.comptimePrint("Field '" ++ field.name ++ "' in struct '" ++ @typeName(@"struct") ++ "' of type '" ++ @typeName(field.type) ++ "' must have at least 2 possible enum values. Has {}", .{info_enum.fields.len});
                @compileError(err);
            }
            return;
        }

        if (@typeInfo(info.child) == .@"struct" and @hasDecl(info.child, flag_parse_function_name)) {
            return;
        }
    }

    @compileError("Field '" ++ field.name ++
        "' in struct '" ++ @typeName(@"struct") ++
        "' of type '" ++ @typeName(field.type) ++
        "' is unsupported. Must be an integer, []const u8, enum, or optional of one of these types." ++
        "For custom types please wrap it in a struct with a `" ++ flag_parse_function_name ++ "` function.");
}

fn defaultValue(comptime field: std.builtin.Type.StructField) ?field.type {
    return if (field.default_value_ptr) |default_opaque|
        @as(*const field.type, @ptrCast(@alignCast(default_opaque))).*
    else
        null;
}

fn logFatal(comptime format: []const u8, args: anytype) noreturn {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.ioBasic();
    var locked_stderr = io.lockStderr(&.{}, null) catch unreachable;
    var stderr = locked_stderr.terminal();
    defer io.unlockStderr();
    stderr.writer.print("FATAL: " ++ format ++ "\n", args) catch {};
    std.process.exit(1);
}

// This software is available under two licenses -- choose whichever you
// prefer.
//
// ----------------------------------------------------------------------
// License 1 -- MIT No Attribution (MIT-0)
//
// Copyright (c) 2025 Aditya Rajagopal
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// ----------------------------------------------------------------------
// License 2 -- Unlicense <https://unlicense.org>
//
// This is free and unencumbered software released into the public
// domain.
//
// Anyone is free to copy, modify, publish, use, compile, sell, or
// distribute this software, either in source code form or as a compiled
// binary, for any purpose, commercial or non-commercial, and by any
// means.
//
// In jurisdictions that recognize copyright laws, the author or authors
// of this software dedicate any and all copyright interest in the
// software to the public domain. We make this dedication for the benefit
// of the public at large and to the detriment of our heirs and
// successors. We intend this dedication to be an overt act of
// relinquishment in perpetuity of all present and future rights to this
// software under copyright law.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
