const std = @import("std");
const Context = @import("context.zig").Context;
const Source = @import("context.zig").Source;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const Curve = @import("parse.zig").Curve;
const Track = @import("parse.zig").Track;
const Module = @import("parse.zig").Module;
const parse = @import("parse.zig").parse;
const CodeGenModuleResult = @import("codegen.zig").CodeGenModuleResult;
const CodeGenTrackResult = @import("codegen.zig").CodeGenTrackResult;
const ExportedModule = @import("codegen.zig").ExportedModule;
const codegen = @import("codegen.zig").codegen;

pub const CompiledScript = struct {
    parse_arena: std.heap.ArenaAllocator,
    codegen_arena: std.heap.ArenaAllocator,
    curves: []const Curve,
    tracks: []const Track,
    modules: []const Module,
    track_results: []const CodeGenTrackResult,
    module_results: []const CodeGenModuleResult,
    exported_modules: []const ExportedModule,

    // do i ever use this?
    pub fn deinit(self: *CompiledScript) void {
        self.codegen_arena.deinit();
        self.parse_arena.deinit();
    }
};

pub const CompileOptions = struct {
    builtin_packages: []const BuiltinPackage,
    source: Source,
    errors_out: std.io.StreamSource.Writer,
    errors_color: bool,
    dump_parse_out: ?std.io.StreamSource.Writer = null,
    dump_codegen_out: ?std.io.StreamSource.Writer = null,
};

pub fn compile(allocator: *std.mem.Allocator, options: CompileOptions) !CompiledScript {
    const context: Context = .{
        .builtin_packages = options.builtin_packages,
        .source = options.source,
        .errors_out = options.errors_out,
        .errors_color = options.errors_color,
    };

    var parse_result = try parse(context, allocator, options.dump_parse_out);
    errdefer parse_result.deinit();

    var codegen_result = try codegen(context, parse_result, allocator, options.dump_codegen_out);
    errdefer codegen_result.deinit();

    return CompiledScript{
        .parse_arena = parse_result.arena,
        .codegen_arena = codegen_result.arena,
        .curves = parse_result.curves,
        .tracks = parse_result.tracks,
        .modules = parse_result.modules,
        .track_results = codegen_result.track_results,
        .module_results = codegen_result.module_results,
        .exported_modules = codegen_result.exported_modules,
    };
}
