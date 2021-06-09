const std = @import("std");
const zangscript = @import("zangscript");
const ParsedBuiltins = @import("zangc/parse_builtins.zig").ParsedBuiltins;
const parseBuiltins = @import("zangc/parse_builtins.zig").parseBuiltins;
const dumpBuiltins = @import("zangc/dump_builtins.zig").dumpBuiltins;

// TODO add an option called `--check` or something, to skip final zig codegen.
// TODO allow --add-builtins and --dump-builtins to be used with no input script at all

fn usage(out: *std.fs.File.Writer, program_name: []const u8) !void {
    try out.print("Usage: {s} [options...] -o <dest> <file>\n\n", .{program_name});
    try out.writeAll(
        \\Compile the zangscript source at <file> into Zig code.
        \\
        \\      --add-builtins <file>   Import native modules from the given Zig source
        \\                                file. Can be used more than once
        \\      --dump-parse <file>     Dump result of parse stage to file
        \\      --dump-codegen <file>   Dump result of codegen stage to file
        \\      --dump-builtins <file>  Dump information on all default and custom
        \\                                builtins to file
        \\      --help                  Print this help text
        \\  -o, --output <file>         Write Zig code to this file
        \\      --color <when>          Colorize compile errors; 'when' can be 'auto'
        \\                                (default if omitted), 'always', or 'never'
        \\
    );
}

const Options = struct {
    const Color = enum { auto, always, never };

    arena: std.heap.ArenaAllocator,
    script_filename: []const u8,
    output_filename: []const u8,
    builtin_filenames: []const []const u8,
    dump_parse_filename: ?[]const u8,
    dump_codegen_filename: ?[]const u8,
    dump_builtins_filename: ?[]const u8,
    color: Color,

    fn deinit(self: Options) void {
        self.arena.deinit();
    }
};

const OptionsParser = struct {
    arena_allocator: *std.mem.Allocator,
    stderr: *std.fs.File.Writer,
    args: std.process.ArgIterator,
    program: []const u8,

    fn init(arena_allocator: *std.mem.Allocator, stderr: *std.fs.File.Writer) !OptionsParser {
        var args = std.process.args();
        const program = try args.next(arena_allocator) orelse "zangc";
        return OptionsParser{
            .arena_allocator = arena_allocator,
            .stderr = stderr,
            .args = args,
            .program = program,
        };
    }

    fn next(self: *OptionsParser) !?[]const u8 {
        return try self.args.next(self.arena_allocator) orelse return null;
    }

    fn argWithValue(self: *OptionsParser, arg: []const u8, comptime variants: []const []const u8) !?[]const u8 {
        for (variants) |variant| {
            if (std.mem.eql(u8, arg, variant)) break;
        } else return null;
        const value = try self.args.next(self.arena_allocator) orelse return self.argError("missing value for '{s}'\n", .{arg});
        return value;
    }

    fn argError(self: OptionsParser, comptime fmt: []const u8, args: anytype) error{ArgError} {
        self.stderr.print("{s}: ", .{self.program}) catch {};
        self.stderr.print(fmt, args) catch {};
        self.stderr.print("Try '{s} --help' for more information.\n", .{self.program}) catch {};
        return error.ArgError;
    }
};

fn parseOptions(stderr: *std.fs.File.Writer, allocator: *std.mem.Allocator) !?Options {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var help = false;
    var script_filename: ?[]const u8 = null;
    var output_filename: ?[]const u8 = null;
    var builtin_filenames = std.ArrayList([]const u8).init(&arena.allocator);
    var dump_parse_filename: ?[]const u8 = null;
    var dump_codegen_filename: ?[]const u8 = null;
    var dump_builtins_filename: ?[]const u8 = null;
    var color: Options.Color = .auto;

    var parser = try OptionsParser.init(&arena.allocator, stderr);
    while (try parser.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            help = true;
        } else if (try parser.argWithValue(arg, &[_][]const u8{ "--output", "-o" })) |value| {
            output_filename = value;
        } else if (try parser.argWithValue(arg, &[_][]const u8{"--add-builtins"})) |value| {
            try builtin_filenames.append(value);
        } else if (try parser.argWithValue(arg, &[_][]const u8{"--dump-parse"})) |value| {
            dump_parse_filename = value;
        } else if (try parser.argWithValue(arg, &[_][]const u8{"--dump-codegen"})) |value| {
            dump_codegen_filename = value;
        } else if (try parser.argWithValue(arg, &[_][]const u8{"--dump-builtins"})) |value| {
            dump_builtins_filename = value;
        } else if (try parser.argWithValue(arg, &[_][]const u8{"--color"})) |value| {
            if (std.mem.eql(u8, value, "auto")) {
                color = .auto;
            } else if (std.mem.eql(u8, value, "always")) {
                color = .always;
            } else if (std.mem.eql(u8, value, "never")) {
                color = .never;
            } else {
                return parser.argError("invalid value '{s}' for '{s}'; must be one of 'auto', 'always', 'never'\n", .{ value, arg });
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return parser.argError("unrecognized option '{s}'\n", .{arg});
        } else {
            script_filename = arg;
        }
    }

    if (help) {
        defer arena.deinit();
        var stdout = std.io.getStdOut().writer();
        try usage(&stdout, parser.program);
        return null;
    }

    return Options{
        .arena = arena,
        .script_filename = script_filename orelse return parser.argError("missing file operand\n", .{}),
        .output_filename = output_filename orelse return parser.argError("missing --output argument\n", .{}),
        .builtin_filenames = builtin_filenames.items,
        .dump_parse_filename = dump_parse_filename,
        .dump_codegen_filename = dump_codegen_filename,
        .dump_builtins_filename = dump_builtins_filename,
        .color = color,
    };
}

fn loadFile(stderr: *std.fs.File.Writer, allocator: *std.mem.Allocator, filename: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, filename, 16 * 1024 * 1024) catch |err| {
        stderr.print("failed to load {s}: {}\n", .{ filename, err }) catch {};
        return error.Failed;
    };
}

fn createFile(stderr: *std.fs.File.Writer, filename: []const u8) !std.fs.File {
    return std.fs.cwd().createFile(filename, .{}) catch |err| {
        stderr.print("failed to open {s} for writing: {}\n", .{ filename, err }) catch {};
        return error.Failed;
    };
}

fn mainInner(stderr: *std.fs.File.Writer) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var allocator = &gpa.allocator;

    // parse command line options
    const maybe_options = try parseOptions(stderr, allocator);
    const options = maybe_options orelse return; // we're done already if `--help` flag was passed
    defer options.deinit();

    // prepare builtin packages
    var builtin_packages = std.ArrayList(zangscript.BuiltinPackage).init(allocator);
    defer builtin_packages.deinit();

    var custom_builtins_arena = std.heap.ArenaAllocator.init(allocator);
    defer custom_builtins_arena.deinit();

    // add default builtin packages
    try builtin_packages.append(zangscript.zang_builtin_package);
    try builtin_packages.append(zangscript.modules_builtin_package);

    // add custom builtin packages, if any were passed
    for (options.builtin_filenames) |filename, i| {
        const contents = try loadFile(stderr, allocator, filename);
        defer allocator.free(contents);

        // make a unique name for the top level decl we'll assign the import to in the generated zig code.
        // start with an underscore because such identifiers are illegal in zangscript so there's no chance of collision
        var buf: [100]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        fbs.writer().print("_custom{}", .{i}) catch unreachable;
        const name = fbs.getWritten();

        // generated zig code will be importing this file, so get a path relative to the output zig file
        const dirname = std.fs.path.dirname(options.output_filename) orelse return error.NoDirName;
        const rel_path = try std.fs.path.relative(&custom_builtins_arena.allocator, dirname, filename);

        const pkg = try parseBuiltins(&custom_builtins_arena.allocator, allocator, stderr, name, rel_path, contents);
        try builtin_packages.append(pkg);
    }

    // dump info about builtins
    if (options.dump_builtins_filename) |filename| {
        var file = try createFile(stderr, filename);
        defer file.close();

        try dumpBuiltins(@as(std.io.StreamSource, .{ .file = file }).writer(), builtin_packages.items);
    }

    // read in source file
    const contents = try loadFile(stderr, allocator, options.script_filename);
    defer allocator.free(contents);

    // set up context for parse and codegen
    const errors_file = std.io.getStdErr();
    const context: zangscript.Context = .{
        .builtin_packages = builtin_packages.items,
        .source = .{ .filename = options.script_filename, .contents = contents },
        .errors_out = @as(std.io.StreamSource, .{ .file = errors_file }).writer(),
        .errors_color = switch (options.color) {
            .auto => errors_file.isTty(),
            .always => true,
            .never => false,
        },
    };

    // parse
    var parse_result = blk: {
        if (options.dump_parse_filename) |filename| {
            var file = try createFile(stderr, filename);
            defer file.close();

            break :blk try zangscript.parse(context, allocator, @as(std.io.StreamSource, .{ .file = file }).writer());
        } else {
            break :blk try zangscript.parse(context, allocator, null);
        }
    };
    defer parse_result.deinit();

    // codegen
    var codegen_result = blk: {
        if (options.dump_codegen_filename) |filename| {
            var file = try createFile(stderr, filename);
            defer file.close();

            break :blk try zangscript.codegen(context, parse_result, allocator, @as(std.io.StreamSource, .{ .file = file }).writer());
        } else {
            break :blk try zangscript.codegen(context, parse_result, allocator, null);
        }
    };
    defer codegen_result.deinit();

    // assemble CompiledScript object
    var script: zangscript.CompiledScript = .{
        .parse_arena = parse_result.arena,
        .codegen_arena = codegen_result.arena,
        .curves = parse_result.curves,
        .tracks = parse_result.tracks,
        .modules = parse_result.modules,
        .track_results = codegen_result.track_results,
        .module_results = codegen_result.module_results,
        .exported_modules = codegen_result.exported_modules,
    };
    // (don't use script.deinit() - we are already deiniting parse and codegen results individually)

    // generate zig code
    var file = try createFile(stderr, options.output_filename);
    defer file.close();

    try zangscript.generateZig(@as(std.io.StreamSource, .{ .file = file }).writer(), builtin_packages.items, script);
}

pub fn main() u8 {
    var stderr = std.io.getStdErr().writer();
    mainInner(&stderr) catch |err| {
        // Failed or ArgError means a message has already been printed
        if (err != error.Failed and err != error.ArgError) {
            stderr.print("failed: {}\n", .{err}) catch {};
        }
        return 1;
    };
    return 0;
}
