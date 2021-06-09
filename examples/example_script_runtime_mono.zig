const std = @import("std");
const zang = @import("zang");
const zangscript = @import("zangscript");
const common = @import("common.zig");
const c = @import("common/c.zig");
const modules = @import("modules.zig");

pub const AUDIO_FORMAT: zang.AudioFormat = .signed16_lsb;
pub const AUDIO_SAMPLE_RATE = 44100;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    \\example_script_runtime_mono
    \\
    \\Play a scripted sound module with the keyboard.
    \\
    \\Press Enter to reload the script.
;

const a4 = 440.0;
const polyphony = 8;

const custom_builtin_package = zangscript.BuiltinPackage{
    .zig_package_name = "_custom0",
    .zig_import_path = "examples/modules.zig",
    .builtins = &[_]zangscript.BuiltinModule{
        zangscript.getBuiltinModule(modules.FilteredSawtoothInstrument),
    },
    .enums = &[_]zangscript.BuiltinEnum{},
};

const builtin_packages = [_]zangscript.BuiltinPackage{
    zangscript.zang_builtin_package,
    zangscript.modules_builtin_package,
    custom_builtin_package,
};

var error_buffer: [8000]u8 = undefined;

pub const MainModule = struct {
    // FIXME (must be at least as many outputs/temps are used in the script)
    // to fix this i would have to change the interface of all example MainModules to be something more dynamic
    pub const num_outputs = 1;
    pub const num_temps = 20;

    pub const output_audio = common.AudioOut{ .mono = 0 };
    pub const output_visualize = 0;

    const module_name = "DemoPlayer";
    const Params = struct {
        sample_rate: f32,
        freq: zang.ConstantOrBuffer,
        note_on: bool,
    };

    allocator: *std.mem.Allocator,
    contents: []const u8,
    script: *zangscript.CompiledScript,

    key: ?i32,
    module: *zangscript.ModuleBase,
    idgen: zang.IdGenerator,
    trigger: zang.Trigger(Params),
    iq: zang.Notes(Params).ImpulseQueue,

    pub fn init(filename: []const u8, out_script_error: *?[]const u8) !MainModule {
        var allocator = std.heap.page_allocator;

        const contents = std.fs.cwd().readFileAlloc(allocator, filename, 16 * 1024 * 1024) catch |err| {
            out_script_error.* = "couldn't open file";
            return err;
        };
        errdefer allocator.free(contents);

        var errors_stream: std.io.StreamSource = .{ .buffer = std.io.fixedBufferStream(&error_buffer) };
        var script = zangscript.compile(allocator, .{
            .builtin_packages = &builtin_packages,
            .source = .{ .filename = filename, .contents = contents },
            .errors_out = errors_stream.writer(),
            .errors_color = false,
        }) catch |err| {
            // StreamSource api flaw, see https://github.com/ziglang/zig/issues/5338
            const fbs = switch (errors_stream) {
                .buffer => |*f| f,
                else => unreachable,
            };
            out_script_error.* = fbs.getWritten();
            return err;
        };
        errdefer script.deinit();

        var script_ptr = allocator.create(zangscript.CompiledScript) catch |err| {
            out_script_error.* = "out of memory";
            return err;
        };
        errdefer allocator.destroy(script_ptr);
        script_ptr.* = script;

        const module_index = for (script.exported_modules) |em| {
            if (std.mem.eql(u8, em.name, module_name)) break em.module_index;
        } else {
            out_script_error.* = "module \"" ++ module_name ++ "\" not found";
            return error.ModuleNotFound;
        };

        var module = try zangscript.initModule(script_ptr, module_index, &builtin_packages, allocator);
        errdefer module.deinit();

        return MainModule{
            .allocator = allocator,
            .contents = contents,
            .script = script_ptr,
            .key = null,
            .module = module,
            .idgen = zang.IdGenerator.init(),
            .trigger = zang.Trigger(Params).init(),
            .iq = zang.Notes(Params).ImpulseQueue.init(),
        };
    }

    pub fn deinit(self: *MainModule) void {
        self.module.deinit();
        self.script.deinit();
        self.allocator.destroy(self.script);
        self.allocator.free(self.contents);
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        var ctr = self.trigger.counter(span, self.iq.consume());
        while (self.trigger.next(&ctr)) |result| {
            const params = self.module.makeParams(Params, result.params) orelse return;
            // script modules zero out their output before writing, so i need a temp to accumulate the outputs
            zang.zero(result.span, temps[0]);
            self.module.paint(
                result.span,
                temps[0..1],
                temps[1 .. self.module.num_temps + 1],
                result.note_id_changed,
                &params,
            );
            zang.addInto(result.span, outputs[0], temps[0]);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) bool {
        if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key) |nh| nh == key else false)) {
                self.key = if (down) key else null;
                self.iq.push(impulse_frame, self.idgen.nextId(), .{
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = zang.constant(a4 * rel_freq),
                    .note_on = down,
                });
            }
        }
        return true;
    }
};
