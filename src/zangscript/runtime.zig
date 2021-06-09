const std = @import("std");
const zang = @import("../zang.zig");
const Source = @import("tokenize.zig").Source;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const BuiltinEnumValue = @import("builtins.zig").BuiltinEnumValue;
const ParamType = @import("parse.zig").ParamType;
const ModuleParam = @import("parse.zig").ModuleParam;
const ParseResult = @import("parse.zig").ParseResult;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const BufferDest = @import("codegen.zig").BufferDest;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const InstrCopyBuffer = @import("codegen.zig").InstrCopyBuffer;
const InstrFloatToBuffer = @import("codegen.zig").InstrFloatToBuffer;
const InstrCobToBuffer = @import("codegen.zig").InstrCobToBuffer;
const InstrArithFloat = @import("codegen.zig").InstrArithFloat;
const InstrArithBuffer = @import("codegen.zig").InstrArithBuffer;
const InstrArithFloatFloat = @import("codegen.zig").InstrArithFloatFloat;
const InstrArithFloatBuffer = @import("codegen.zig").InstrArithFloatBuffer;
const InstrArithBufferFloat = @import("codegen.zig").InstrArithBufferFloat;
const InstrArithBufferBuffer = @import("codegen.zig").InstrArithBufferBuffer;
const InstrCall = @import("codegen.zig").InstrCall;
const InstrTrackCall = @import("codegen.zig").InstrTrackCall;
const InstrDelay = @import("codegen.zig").InstrDelay;
const Instruction = @import("codegen.zig").Instruction;
const CodeGenCustomModuleInner = @import("codegen.zig").CodeGenCustomModuleInner;
const CompiledScript = @import("compile.zig").CompiledScript;

pub const Value = union(enum) {
    constant: f32,
    buffer: []const f32,
    cob: zang.ConstantOrBuffer,
    boolean: bool,
    curve: []const zang.CurveNode,
    one_of: struct { label: []const u8, payload: ?f32 },

    // turn a Value into a zig value
    pub fn toZig(value: Value, comptime P: type) P {
        switch (P) {
            bool => switch (value) {
                .boolean => |v| return v,
                else => unreachable,
            },
            f32 => switch (value) {
                .constant => |v| return v,
                else => unreachable,
            },
            []const f32 => switch (value) {
                .buffer => |v| return v,
                else => unreachable,
            },
            zang.ConstantOrBuffer => switch (value) {
                .cob => |v| return v,
                else => unreachable,
            },
            []const zang.CurveNode => switch (value) {
                .curve => |v| return v,
                else => unreachable,
            },
            else => switch (@typeInfo(P)) {
                .Enum => |enum_info| {
                    switch (value) {
                        .one_of => |v| {
                            inline for (enum_info.fields) |enum_field, i| {
                                if (std.mem.eql(u8, v.label, enum_field.name)) {
                                    return @intToEnum(P, i);
                                }
                            }
                            unreachable;
                        },
                        else => unreachable,
                    }
                },
                .Union => |union_info| {
                    switch (value) {
                        .one_of => |v| {
                            inline for (union_info.fields) |union_field, i| {
                                if (std.mem.eql(u8, v.label, union_field.name)) {
                                    switch (union_field.field_type) {
                                        void => return @unionInit(P, union_field.name, {}),
                                        f32 => return @unionInit(P, union_field.name, v.payload.?),
                                        // the above are the only payload types allowed by the language so far
                                        else => unreachable,
                                    }
                                }
                            }
                            unreachable;
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            },
        }
    }

    // turn a zig value into a Value
    fn fromZig(param_type: ParamType, zig_value: anytype) ?Value {
        switch (param_type) {
            .boolean => if (@TypeOf(zig_value) == bool) return Value{ .boolean = zig_value },
            .buffer => if (@TypeOf(zig_value) == []const f32) return Value{ .buffer = zig_value },
            .constant => if (@TypeOf(zig_value) == f32) return Value{ .constant = zig_value },
            .constant_or_buffer => if (@TypeOf(zig_value) == zang.ConstantOrBuffer) return Value{ .cob = zig_value },
            .curve => if (@TypeOf(zig_value) == []const zang.CurveNode) return Value{ .curve = zig_value },
            .one_of => |builtin_enum| {
                switch (@typeInfo(@TypeOf(zig_value))) {
                    .Enum => |enum_info| {
                        // just check if the current value of `zig_value` fits structurally
                        const label = @tagName(zig_value);
                        for (builtin_enum.values) |bev| {
                            if (std.mem.eql(u8, bev.label, label) and bev.payload_type == .none) {
                                return Value{ .one_of = .{ .label = label, .payload = null } };
                            }
                        }
                    },
                    .Union => |union_info| {
                        // just check if the current value of `zig_value` fits structurally
                        for (builtin_enum.values) |bev| {
                            inline for (union_info.fields) |field, i| {
                                if (@enumToInt(zig_value) == i and std.mem.eql(u8, bev.label, field.name)) {
                                    return payloadFromZig(bev, @field(zig_value, field.name));
                                }
                            }
                        }
                    },
                    else => {},
                }
            },
        }
        return null;
    }

    fn payloadFromZig(bev: BuiltinEnumValue, zig_payload: anytype) ?Value {
        switch (bev.payload_type) {
            .none => {
                if (@TypeOf(zig_payload) == void) {
                    return Value{ .one_of = .{ .label = bev.label, .payload = null } };
                }
            },
            .f32 => {
                if (@TypeOf(zig_payload) == f32) {
                    return Value{ .one_of = .{ .label = bev.label, .payload = zig_payload } };
                }
            },
        }
        return null;
    }
};

pub const ModuleBase = struct {
    num_outputs: usize,
    num_temps: usize,
    params: []const ModuleParam,
    deinitFn: fn (base: *ModuleBase) void,
    paintFn: fn (base: *ModuleBase, span: zang.Span, outputs: []const []f32, temps: []const []f32, note_id_changed: bool, params: []const Value) void,

    pub fn deinit(base: *ModuleBase) void {
        base.deinitFn(base);
    }

    pub fn paint(base: *ModuleBase, span: zang.Span, outputs: []const []f32, temps: []const []f32, note_id_changed: bool, params: []const Value) void {
        base.paintFn(base, span, outputs, temps, note_id_changed, params);
    }

    // convenience function for interfacing with runtime scripts from zig code.
    // you give it an impromptu struct of params and it will validate and convert that into the array of Values that the runtime expects
    pub fn makeParams(self: *const ModuleBase, comptime T: type, params: T) ?[@typeInfo(T).Struct.fields.len]Value {
        const struct_fields = @typeInfo(T).Struct.fields;
        var values: [struct_fields.len]Value = undefined;
        for (self.params) |param, i| {
            var found = false;
            inline for (struct_fields) |field| {
                if (std.mem.eql(u8, field.name, param.name)) {
                    values[i] = Value.fromZig(param.param_type, @field(params, field.name)) orelse {
                        std.debug.warn("makeParams: type mismatch on param \"{s}\"\n", .{param.name});
                        return null;
                    };
                    found = true;
                }
            }
            if (!found) {
                std.debug.warn("makeParams: missing param \"{s}\"\n", .{param.name});
                return null;
            }
        }
        return values;
    }
};

pub fn initModule(
    script: *const CompiledScript,
    module_index: usize,
    comptime builtin_packages: []const BuiltinPackage,
    allocator: *std.mem.Allocator,
) error{OutOfMemory}!*ModuleBase {
    switch (script.module_results[module_index].inner) {
        .builtin => {
            inline for (builtin_packages) |pkg| {
                const package = if (comptime std.mem.eql(u8, pkg.zig_import_path, "zang"))
                    @import("../zang.zig")
                else if (comptime std.mem.eql(u8, pkg.zig_import_path, "modules"))
                    @import("../modules.zig")
                else
                    @import("../../" ++ pkg.zig_import_path);

                inline for (pkg.builtins) |builtin| {
                    const builtin_name = script.modules[module_index].builtin_name.?;
                    if (std.mem.eql(u8, builtin.name, builtin_name)) {
                        const T = @field(package, builtin.name);
                        return BuiltinModule(T).init(script, module_index, allocator);
                    }
                }
            }
            unreachable;
        },
        .custom => |x| {
            return ScriptModule.init(script, module_index, builtin_packages, allocator);
        },
    }
}

fn BuiltinModule(comptime T: type) type {
    return struct {
        base: ModuleBase,
        allocator: *std.mem.Allocator,
        mod: T,
        id: usize,

        fn init(script: *const CompiledScript, module_index: usize, allocator: *std.mem.Allocator) !*ModuleBase {
            var self = try allocator.create(@This());
            self.base = .{
                .num_outputs = T.num_outputs,
                .num_temps = T.num_temps,
                .params = script.modules[module_index].params,
                .deinitFn = deinitFn,
                .paintFn = paintFn,
            };
            self.allocator = allocator;
            self.mod = T.init();
            return &self.base;
        }

        fn deinitFn(base: *ModuleBase) void {
            var self = @fieldParentPtr(@This(), "base", base);

            self.allocator.destroy(self);
        }

        fn paintFn(
            base: *ModuleBase,
            span: zang.Span,
            outputs_slice: []const []f32,
            temps_slice: []const []f32,
            note_id_changed: bool,
            param_values: []const Value,
        ) void {
            var self = @fieldParentPtr(@This(), "base", base);

            const outputs = outputs_slice[0..T.num_outputs].*;
            const temps = temps_slice[0..T.num_temps].*;

            var params: T.Params = undefined;
            inline for (@typeInfo(T.Params).Struct.fields) |field| {
                const param_index = getParamIndex(self.base.params, field.name);
                @field(params, field.name) = param_values[param_index].toZig(field.field_type);
            }

            self.mod.paint(span, outputs, temps, note_id_changed, params);
        }

        fn getParamIndex(params: []const ModuleParam, name: []const u8) usize {
            for (params) |param, i| {
                if (std.mem.eql(u8, name, param.name)) {
                    return i;
                }
            }
            unreachable;
        }
    };
}

const ScriptCurve = struct { start: usize, end: usize };

const ScriptModule = struct {
    base: ModuleBase,
    allocator: *std.mem.Allocator,
    script: *const CompiledScript,
    curve_points: []zang.CurveNode, // TODO shouldn't be per module. runtime should have something around CompiledScript with additions
    curves: []ScriptCurve,
    module_index: usize,
    module_instances: []*ModuleBase,
    delay_instances: []zang.Delay(11025),
    temp_floats: []f32,
    callee_temps: [][]f32,
    callee_params: []Value,

    fn init(
        script: *const CompiledScript,
        module_index: usize,
        comptime builtin_packages: []const BuiltinPackage,
        allocator: *std.mem.Allocator,
    ) !*ModuleBase {
        const inner = switch (script.module_results[module_index].inner) {
            .builtin => unreachable,
            .custom => |x| x,
        };

        var self = try allocator.create(ScriptModule);
        errdefer allocator.destroy(self);

        self.base = .{
            .num_outputs = script.module_results[module_index].num_outputs,
            .num_temps = script.module_results[module_index].num_temps,
            .params = script.modules[module_index].params,
            .deinitFn = deinitFn,
            .paintFn = paintFn,
        };
        self.allocator = allocator;
        self.script = script;
        self.module_index = module_index;

        const num_curve_points = blk: {
            var count: usize = 0;
            for (script.curves) |curve| count += curve.points.len;
            break :blk count;
        };
        self.curve_points = try allocator.alloc(zang.CurveNode, num_curve_points);
        errdefer allocator.free(self.curve_points);
        self.curves = try allocator.alloc(ScriptCurve, script.curves.len);
        errdefer allocator.free(self.curves);
        {
            var index: usize = 0;
            for (script.curves) |curve, i| {
                self.curves[i].start = index;
                for (curve.points) |point, j| {
                    self.curve_points[index] = .{
                        .t = point.t.value,
                        .value = point.value.value,
                    };
                    index += 1;
                }
                self.curves[i].end = index;
            }
        }

        self.module_instances = try allocator.alloc(*ModuleBase, inner.fields.len);
        errdefer allocator.free(self.module_instances);

        var num_initialized_fields: usize = 0;
        errdefer for (self.module_instances[0..num_initialized_fields]) |module_instance| {
            module_instance.deinit();
        };

        for (inner.fields) |field, i| {
            self.module_instances[i] = try initModule(script, field.module_index, builtin_packages, allocator);
            num_initialized_fields += 1;
        }

        self.delay_instances = try allocator.alloc(zang.Delay(11025), inner.delays.len);
        errdefer allocator.free(self.delay_instances);
        for (inner.delays) |delay_decl, i| {
            // ignoring delay_decl.num_samples because we need a comptime value
            self.delay_instances[i] = zang.Delay(11025).init();
        }

        self.temp_floats = try allocator.alloc(f32, script.module_results[module_index].num_temp_floats);
        errdefer allocator.free(self.temp_floats);

        var most_callee_temps: usize = 0;
        var most_callee_params: usize = 0;
        for (inner.fields) |field| {
            const callee_temps = script.module_results[field.module_index].num_temps;
            if (callee_temps > most_callee_temps) {
                most_callee_temps = callee_temps;
            }
            const callee_params = script.modules[field.module_index].params;
            if (callee_params.len > most_callee_params) {
                most_callee_params = callee_params.len;
            }
        }
        self.callee_temps = try allocator.alloc([]f32, most_callee_temps);
        errdefer allocator.free(self.callee_temps);
        self.callee_params = try allocator.alloc(Value, most_callee_params);
        errdefer allocator.free(self.callee_params);

        return &self.base;
    }

    fn deinitFn(base: *ModuleBase) void {
        var self = @fieldParentPtr(ScriptModule, "base", base);

        self.allocator.free(self.callee_params);
        self.allocator.free(self.callee_temps);
        self.allocator.free(self.temp_floats);
        self.allocator.free(self.delay_instances);
        self.allocator.free(self.curve_points);
        self.allocator.free(self.curves);
        for (self.module_instances) |module_instance| {
            module_instance.deinit();
        }
        self.allocator.free(self.module_instances);

        self.allocator.destroy(self);
    }

    const PaintArgs = struct {
        inner: CodeGenCustomModuleInner,
        outputs: []const []f32,
        temps: []const []f32,
        note_id_changed: bool,
        params: []const Value,
    };

    fn paintFn(
        base: *ModuleBase,
        span: zang.Span,
        outputs: []const []f32,
        temps: []const []f32,
        note_id_changed: bool,
        params: []const Value,
    ) void {
        var self = @fieldParentPtr(ScriptModule, "base", base);

        std.debug.assert(outputs.len == self.script.module_results[self.module_index].num_outputs);
        std.debug.assert(temps.len == self.script.module_results[self.module_index].num_temps);

        const p: PaintArgs = .{
            .inner = switch (self.script.module_results[self.module_index].inner) {
                .builtin => unreachable,
                .custom => |x| x,
            },
            .outputs = outputs,
            .temps = temps,
            .note_id_changed = note_id_changed,
            .params = params,
        };

        for (p.inner.instructions) |instr| {
            self.paintInstruction(p, span, instr);
        }
    }

    // FIXME - if x.out is an output, we should be doing `+=`, not `=`! see codegen_zig which already does this

    fn paintInstruction(self: *const ScriptModule, p: PaintArgs, span: zang.Span, instr: Instruction) void {
        switch (instr) {
            .copy_buffer => |x| self.paintCopyBuffer(p, span, x),
            .float_to_buffer => |x| self.paintFloatToBuffer(p, span, x),
            .cob_to_buffer => |x| self.paintCobToBuffer(p, span, x),
            .call => |x| self.paintCall(p, span, x),
            .track_call => |x| self.paintTrackCall(p, span, x),
            .arith_float => |x| self.paintArithFloat(p, span, x),
            .arith_buffer => |x| self.paintArithBuffer(p, span, x),
            .arith_float_float => |x| self.paintArithFloatFloat(p, span, x),
            .arith_float_buffer => |x| self.paintArithFloatBuffer(p, span, x),
            .arith_buffer_float => |x| self.paintArithBufferFloat(p, span, x),
            .arith_buffer_buffer => |x| self.paintArithBufferBuffer(p, span, x),
            .delay => |x| self.paintDelay(p, span, x),
        }
    }

    fn paintCopyBuffer(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrCopyBuffer) void {
        zang.copy(span, getOut(p, x.out), self.getResultAsBuffer(p, x.in));
    }

    fn paintFloatToBuffer(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrFloatToBuffer) void {
        zang.set(span, getOut(p, x.out), self.getResultAsFloat(p, x.in));
    }

    fn paintCobToBuffer(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrCobToBuffer) void {
        var out = getOut(p, x.out);
        switch (p.params[x.in_self_param]) {
            .cob => |cob| switch (cob) {
                .constant => |v| zang.set(span, out, v),
                .buffer => |v| zang.copy(span, out, v),
            },
            else => unreachable,
        }
    }

    fn paintCall(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrCall) void {
        var out = getOut(p, x.out);

        const callee_module_index = p.inner.fields[x.field_index].module_index;
        const callee_base = self.module_instances[x.field_index];

        for (x.temps) |n, i| {
            self.callee_temps[i] = p.temps[n];
        }

        for (x.args) |arg, i| {
            const param_type = self.script.modules[callee_module_index].params[i].param_type;
            self.callee_params[i] = self.getResultValue(p, param_type, arg);
        }

        zang.zero(span, out);
        callee_base.paintFn(
            callee_base,
            span,
            &[1][]f32{out},
            self.callee_temps[0..x.temps.len],
            p.note_id_changed,
            self.callee_params[0..x.args.len],
        );
    }

    fn paintTrackCall(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrTrackCall) void {
        unreachable; // TODO
    }

    fn paintArithFloat(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrArithFloat) void {
        const a = self.getResultAsFloat(p, x.a);
        self.temp_floats[x.out.temp_float_index] = switch (x.op) {
            .abs => std.math.fabs(a),
            .cos => std.math.cos(a),
            .neg => -a,
            .sin => std.math.sin(a),
            .sqrt => std.math.sqrt(a),
        };
    }

    fn paintArithBuffer(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrArithBuffer) void {
        var out = getOut(p, x.out);
        const a = self.getResultAsBuffer(p, x.a);
        var i: usize = span.start;
        switch (x.op) {
            .abs => {
                while (i < span.end) : (i += 1) out[i] = std.math.fabs(a[i]);
            },
            .cos => {
                while (i < span.end) : (i += 1) out[i] = std.math.cos(a[i]);
            },
            .neg => {
                while (i < span.end) : (i += 1) out[i] = -a[i];
            },
            .sin => {
                while (i < span.end) : (i += 1) out[i] = std.math.sin(a[i]);
            },
            .sqrt => {
                while (i < span.end) : (i += 1) out[i] = std.math.sqrt(a[i]);
            },
        }
    }

    fn paintArithFloatFloat(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrArithFloatFloat) void {
        const a = self.getResultAsFloat(p, x.a);
        const b = self.getResultAsFloat(p, x.b);
        self.temp_floats[x.out.temp_float_index] = switch (x.op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => a / b,
            .pow => std.math.pow(f32, a, b),
            .min => std.math.min(a, b),
            .max => std.math.max(a, b),
        };
    }

    fn paintArithFloatBuffer(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrArithFloatBuffer) void {
        var out = getOut(p, x.out);
        const a = self.getResultAsFloat(p, x.a);
        const b = self.getResultAsBuffer(p, x.b);
        switch (x.op) {
            .add => {
                zang.zero(span, out);
                zang.addScalar(span, out, b, a);
            },
            .sub => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = a - b[i];
                }
            },
            .mul => {
                zang.zero(span, out);
                zang.multiplyScalar(span, out, b, a);
            },
            .div => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = a / b[i];
                }
            },
            .pow => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.pow(f32, a, b[i]);
                }
            },
            .min => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.min(a, b[i]);
                }
            },
            .max => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.max(a, b[i]);
                }
            },
        }
    }

    fn paintArithBufferFloat(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrArithBufferFloat) void {
        var out = getOut(p, x.out);
        const a = self.getResultAsBuffer(p, x.a);
        const b = self.getResultAsFloat(p, x.b);
        switch (x.op) {
            .add => {
                zang.zero(span, out);
                zang.addScalar(span, out, a, b);
            },
            .sub => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = a[i] - b;
                }
            },
            .mul => {
                zang.zero(span, out);
                zang.multiplyScalar(span, out, a, b);
            },
            .div => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = a[i] / b;
                }
            },
            .pow => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.pow(f32, a[i], b);
                }
            },
            .min => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.min(a[i], b);
                }
            },
            .max => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.max(a[i], b);
                }
            },
        }
    }

    fn paintArithBufferBuffer(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrArithBufferBuffer) void {
        var out = getOut(p, x.out);
        const a = self.getResultAsBuffer(p, x.a);
        const b = self.getResultAsBuffer(p, x.b);
        switch (x.op) {
            .add => {
                zang.zero(span, out);
                zang.add(span, out, a, b);
            },
            .sub => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = a[i] - b[i];
                }
            },
            .mul => {
                zang.zero(span, out);
                zang.multiply(span, out, a, b);
            },
            .div => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = a[i] / b[i];
                }
            },
            .pow => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.pow(f32, a[i], b[i]);
                }
            },
            .min => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.min(a[i], b[i]);
                }
            },
            .max => {
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = std.math.max(a[i], b[i]);
                }
            },
        }
    }

    fn paintDelay(self: *const ScriptModule, p: PaintArgs, span: zang.Span, x: InstrDelay) void {
        // FIXME - what is `out` here? it's not even used?
        var out = getOut(p, x.out);
        zang.zero(span, out);
        var start = span.start;
        const end = span.end;
        while (start < end) {
            zang.zero(zang.Span.init(start, end), p.temps[x.feedback_out_temp_buffer_index]);
            zang.zero(zang.Span.init(start, end), p.temps[x.feedback_temp_buffer_index]);
            const samples_read = self.delay_instances[x.delay_index].readDelayBuffer(p.temps[x.feedback_temp_buffer_index][start..end]);
            const inner_span = zang.Span.init(start, start + samples_read);
            for (x.instructions) |sub_instr| {
                self.paintInstruction(p, inner_span, sub_instr);
            }
            self.delay_instances[x.delay_index].writeDelayBuffer(p.temps[x.feedback_out_temp_buffer_index][start .. start + samples_read]);
            start += samples_read;
        }
    }

    fn getOut(p: PaintArgs, buffer_dest: BufferDest) []f32 {
        return switch (buffer_dest) {
            .temp_buffer_index => |i| p.temps[i],
            .output_index => |i| p.outputs[i],
        };
    }

    fn getResultValue(self: *const ScriptModule, p: PaintArgs, param_type: ParamType, result: ExpressionResult) Value {
        switch (param_type) {
            .boolean => return .{ .boolean = self.getResultAsBool(p, result) },
            .buffer => return .{ .buffer = self.getResultAsBuffer(p, result) },
            .constant => return .{ .constant = self.getResultAsFloat(p, result) },
            .constant_or_buffer => return .{ .cob = self.getResultAsCob(p, result) },
            .curve => return .{ .curve = self.getResultAsCurve(p, result) },
            .one_of => |builtin_enum| {
                return switch (result) {
                    .literal_enum_value => |literal| {
                        const payload = if (literal.payload) |result_payload|
                            self.getResultAsFloat(p, result_payload.*)
                        else
                            null;
                        return .{ .one_of = .{ .label = literal.label, .payload = payload } };
                    },
                    .self_param => |param_index| switch (p.params[param_index]) {
                        .one_of => |v| return .{ .one_of = v },
                        .constant, .buffer, .cob, .boolean, .curve => unreachable,
                    },
                    .track_param => |x| unreachable, // TODO
                    .nothing, .temp_float, .temp_buffer, .literal_boolean, .literal_number, .literal_curve, .literal_track, .literal_module => unreachable,
                };
            },
        }
    }

    fn getResultAsBuffer(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) []const f32 {
        return switch (result) {
            .temp_buffer => |temp_ref| p.temps[temp_ref.index],
            .self_param => |param_index| switch (p.params[param_index]) {
                .buffer => |v| v,
                .constant, .cob, .boolean, .curve, .one_of => unreachable,
            },
            .track_param => |x| unreachable, // TODO
            .nothing, .temp_float, .literal_boolean, .literal_number, .literal_enum_value, .literal_curve, .literal_track, .literal_module => unreachable,
        };
    }

    fn getResultAsFloat(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) f32 {
        return switch (result) {
            .literal_number => |literal| literal.value,
            .temp_float => |temp_ref| self.temp_floats[temp_ref.index],
            .self_param => |param_index| switch (p.params[param_index]) {
                .constant => |v| v,
                .buffer, .cob, .boolean, .curve, .one_of => unreachable,
            },
            .track_param => |x| unreachable, // TODO
            .nothing, .temp_buffer, .literal_boolean, .literal_enum_value, .literal_curve, .literal_track, .literal_module => unreachable,
        };
    }

    fn getResultAsCob(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) zang.ConstantOrBuffer {
        return switch (result) {
            .temp_buffer => |temp_ref| zang.buffer(p.temps[temp_ref.index]),
            .temp_float => |temp_ref| zang.constant(self.temp_floats[temp_ref.index]),
            .literal_number => |literal| zang.constant(literal.value),
            .self_param => |param_index| switch (p.params[param_index]) {
                .constant => |v| zang.constant(v),
                .buffer => |v| zang.buffer(v),
                .cob => |v| v,
                .boolean, .curve, .one_of => unreachable,
            },
            .track_param => |x| unreachable, // TODO
            .nothing, .literal_boolean, .literal_enum_value, .literal_curve, .literal_track, .literal_module => unreachable,
        };
    }

    fn getResultAsBool(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) bool {
        return switch (result) {
            .literal_boolean => |v| v,
            .self_param => |param_index| switch (p.params[param_index]) {
                .boolean => |v| v,
                .constant, .buffer, .cob, .curve, .one_of => unreachable,
            },
            .track_param => |x| unreachable, // TODO
            .nothing, .temp_buffer, .temp_float, .literal_number, .literal_enum_value, .literal_curve, .literal_track, .literal_module => unreachable,
        };
    }

    fn getResultAsCurve(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) []const zang.CurveNode {
        return switch (result) {
            .literal_curve => |curve_index| {
                const curve = self.curves[curve_index];
                return self.curve_points[curve.start..curve.end];
            },
            .self_param => |param_index| switch (p.params[param_index]) {
                .curve => |v| v,
                .boolean, .constant, .buffer, .cob, .one_of => unreachable,
            },
            .track_param => |x| unreachable, // TODO
            .nothing, .temp_buffer, .temp_float, .literal_boolean, .literal_number, .literal_enum_value, .literal_track, .literal_module => unreachable,
        };
    }
};
