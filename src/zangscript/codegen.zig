const std = @import("std");
const Context = @import("context.zig").Context;
const SourceRange = @import("context.zig").SourceRange;
const fail = @import("fail.zig").fail;
const Token = @import("tokenize.zig").Token;
const NumberLiteral = @import("parse.zig").NumberLiteral;
const ParsedModuleInfo = @import("parse.zig").ParsedModuleInfo;
const ParseResult = @import("parse.zig").ParseResult;
const Global = @import("parse.zig").Global;
const Curve = @import("parse.zig").Curve;
const Track = @import("parse.zig").Track;
const Module = @import("parse.zig").Module;
const ModuleParam = @import("parse.zig").ModuleParam;
const ParamType = @import("parse.zig").ParamType;
const Call = @import("parse.zig").Call;
const CallArg = @import("parse.zig").CallArg;
const UnArithOp = @import("parse.zig").UnArithOp;
const BinArithOp = @import("parse.zig").BinArithOp;
const TrackCall = @import("parse.zig").TrackCall;
const Delay = @import("parse.zig").Delay;
const Local = @import("parse.zig").Local;
const Expression = @import("parse.zig").Expression;
const Statement = @import("parse.zig").Statement;
const BuiltinEnumValue = @import("builtins.zig").BuiltinEnumValue;
const printBytecode = @import("codegen_print.zig").printBytecode;

pub const TempRef = struct {
    index: usize, // temp index
    // is_weak should be a bool, but an outstanding compiler (or LLVM?) bug
    // causes corrupted runtime behavior in release builds. making the field
    // a u8 avoids the bug, for not entirely understood reasons. see:
    //   * https://todo.sr.ht/~dbandstra/zang/24
    //   * https://github.com/ziglang/zig/issues/7325
    is_weak: u8, // if true, someone else owns the temp, so don't release it

    fn strong(index: usize) TempRef {
        return .{ .index = index, .is_weak = 0 };
    }

    fn weak(index: usize) TempRef {
        return .{ .index = index, .is_weak = 1 };
    }
};

// expression will return how it stored its result.
// caller needs to make sure to release it (by calling releaseExpressionResult), which will release any temps that were being used.
pub const ExpressionResult = union(enum) {
    nothing, // this means the result was already written into a result location
    temp_buffer: TempRef,
    temp_float: TempRef,
    literal_boolean: bool,
    literal_number: NumberLiteral,
    literal_enum_value: struct { label: []const u8, payload: ?*const ExpressionResult },
    literal_curve: usize,
    literal_track: usize,
    literal_module: usize,
    self_param: usize,
    track_param: struct { track_index: usize, param_index: usize },
};

pub const FloatDest = struct {
    temp_float_index: usize,
};

pub const BufferDest = union(enum) {
    temp_buffer_index: usize,
    output_index: usize,
};

pub const InstrCopyBuffer = struct { out: BufferDest, in: ExpressionResult };
pub const InstrFloatToBuffer = struct { out: BufferDest, in: ExpressionResult };
pub const InstrCobToBuffer = struct { out: BufferDest, in_self_param: usize };
pub const InstrArithFloat = struct { out: FloatDest, op: UnArithOp, a: ExpressionResult };
pub const InstrArithBuffer = struct { out: BufferDest, op: UnArithOp, a: ExpressionResult };
pub const InstrArithFloatFloat = struct { out: FloatDest, op: BinArithOp, a: ExpressionResult, b: ExpressionResult };
pub const InstrArithFloatBuffer = struct { out: BufferDest, op: BinArithOp, a: ExpressionResult, b: ExpressionResult };
pub const InstrArithBufferFloat = struct { out: BufferDest, op: BinArithOp, a: ExpressionResult, b: ExpressionResult };
pub const InstrArithBufferBuffer = struct { out: BufferDest, op: BinArithOp, a: ExpressionResult, b: ExpressionResult };

pub const InstrCall = struct {
    // paint always results in a buffer.
    out: BufferDest,
    // which field of the "self" module we are calling
    field_index: usize,
    // list of temp buffers passed along for the callee's internal use
    temps: []const usize,
    // list of argument param values (in the order of the callee module's params)
    args: []const ExpressionResult,
};

pub const InstrTrackCall = struct {
    out: BufferDest,
    track_index: usize,
    speed: ExpressionResult,
    trigger_index: usize,
    note_tracker_index: usize,
    instructions: []const Instruction,
};

pub const InstrDelay = struct {
    delay_index: usize,
    out: BufferDest,
    feedback_out_temp_buffer_index: usize,
    feedback_temp_buffer_index: usize,
    instructions: []const Instruction,
};

pub const Instruction = union(enum) {
    copy_buffer: InstrCopyBuffer,
    float_to_buffer: InstrFloatToBuffer,
    cob_to_buffer: InstrCobToBuffer,
    arith_float: InstrArithFloat,
    arith_buffer: InstrArithBuffer,
    arith_float_float: InstrArithFloatFloat,
    arith_float_buffer: InstrArithFloatBuffer,
    arith_buffer_float: InstrArithBufferFloat,
    arith_buffer_buffer: InstrArithBufferBuffer,
    call: InstrCall,
    track_call: InstrTrackCall,
    delay: InstrDelay,
};

pub const Field = struct {
    module_index: usize,
};

pub const DelayDecl = struct {
    num_samples: usize,
};

pub const TriggerDecl = struct {
    track_index: usize,
};

pub const NoteTrackerDecl = struct {
    track_index: usize,
};

pub const CurrentDelay = struct {
    feedback_temp_index: usize,
    instructions: std.ArrayList(Instruction),
};

pub const CurrentTrackCall = struct {
    track_index: usize,
    instructions: std.ArrayList(Instruction),
};

pub const CodegenState = struct {
    arena_allocator: *std.mem.Allocator,
    inner_allocator: *std.mem.Allocator,
    ctx: Context,
    globals: []const Global,
    curves: []const Curve,
    tracks: []const Track,
    modules: []const Module,
    global_results: []?ExpressionResult,
    global_visited: []bool,
    track_results: []?CodeGenTrackResult,
    module_results: []?CodeGenModuleResult,
    dump_codegen_out: ?std.io.StreamSource.Writer,
};

pub const CodegenModuleState = struct {
    module_index: usize,
    locals: []const Local,
    instructions: std.ArrayList(Instruction),
    temp_buffers: TempManager,
    temp_floats: TempManager,
    local_results: []?ExpressionResult,
    fields: std.ArrayList(Field),
    delays: std.ArrayList(DelayDecl),
    triggers: std.ArrayList(TriggerDecl),
    note_trackers: std.ArrayList(NoteTrackerDecl),
    // only one of these can be set at a time, for now (i'll improve it later)
    current_delay: ?*CurrentDelay,
    current_track_call: ?*CurrentTrackCall,
};

const CodegenContext = union(enum) {
    global,
    module: *CodegenModuleState,
};

const TempManager = struct {
    reuse_slots: bool,
    slot_claimed: std.ArrayList(bool),

    fn init(allocator: *std.mem.Allocator, reuse_slots: bool) TempManager {
        return .{
            .reuse_slots = reuse_slots,
            .slot_claimed = std.ArrayList(bool).init(allocator),
        };
    }

    fn deinit(self: *TempManager) void {
        self.slot_claimed.deinit();
    }

    fn reportLeaks(self: *const TempManager) void {
        // if we're cleaning up because an error occurred, don't complain
        // about leaks. i don't care about releasing every temp in an
        // error situation.
        var num_leaked: usize = 0;
        for (self.slot_claimed.items) |in_use| {
            if (in_use) num_leaked += 1;
        }
        if (num_leaked > 0) {
            std.debug.warn("error - {} temp(s) leaked in codegen\n", .{num_leaked});
        }
    }

    fn claim(self: *TempManager) !usize {
        if (self.reuse_slots) {
            for (self.slot_claimed.items) |*in_use, index| {
                if (in_use.*) continue;
                in_use.* = true;
                return index;
            }
        }
        const index = self.slot_claimed.items.len;
        try self.slot_claimed.append(true);
        return index;
    }

    fn release(self: *TempManager, index: usize) void {
        std.debug.assert(self.slot_claimed.items[index]);
        self.slot_claimed.items[index] = false;
    }

    pub fn finalCount(self: *const TempManager) usize {
        return self.slot_claimed.items.len;
    }
};

fn releaseExpressionResult(cms: *CodegenModuleState, result: ExpressionResult) void {
    switch (result) {
        .temp_buffer => |temp_ref| {
            if (temp_ref.is_weak == 0) cms.temp_buffers.release(temp_ref.index);
        },
        .temp_float => |temp_ref| {
            if (temp_ref.is_weak == 0) cms.temp_floats.release(temp_ref.index);
        },
        .literal_enum_value => |literal| {
            if (literal.payload) |payload| {
                releaseExpressionResult(cms, payload.*);
            }
        },
        else => {},
    }
}

fn isResultBoolean(cs: *const CodegenState, cc: CodegenContext, result: ExpressionResult) bool {
    return switch (result) {
        .nothing => unreachable,
        .literal_boolean => true,
        .self_param => |param_index| switch (cc) {
            .global => unreachable,
            .module => |cms| cs.modules[cms.module_index].params[param_index].param_type == .boolean,
        },
        .track_param => |x| switch (cc) {
            .global => unreachable,
            .module => |cms| cs.tracks[x.track_index].params[x.param_index].param_type == .boolean,
        },
        .literal_number, .literal_enum_value, .literal_curve, .literal_track, .literal_module, .temp_buffer, .temp_float => false,
    };
}

fn isResultFloat(cs: *const CodegenState, cc: CodegenContext, result: ExpressionResult) bool {
    return switch (result) {
        .nothing => unreachable,
        .temp_float, .literal_number => true,
        .self_param => |param_index| switch (cc) {
            .global => unreachable,
            .module => |cms| cs.modules[cms.module_index].params[param_index].param_type == .constant,
        },
        .track_param => |x| switch (cc) {
            .global => unreachable,
            .module => |cms| cs.tracks[x.track_index].params[x.param_index].param_type == .constant,
        },
        .literal_boolean, .literal_enum_value, .literal_curve, .literal_track, .literal_module, .temp_buffer => false,
    };
}

fn isResultBuffer(cs: *const CodegenState, cc: CodegenContext, result: ExpressionResult) bool {
    return switch (result) {
        .nothing => unreachable,
        .temp_buffer => true,
        .self_param => |param_index| switch (cc) {
            .global => unreachable,
            .module => |cms| cs.modules[cms.module_index].params[param_index].param_type == .buffer,
        },
        .track_param => |x| switch (cc) {
            .global => unreachable,
            .module => |cms| cs.tracks[x.track_index].params[x.param_index].param_type == .buffer,
        },
        .temp_float, .literal_boolean, .literal_number, .literal_enum_value, .literal_curve, .literal_track, .literal_module => false,
    };
}

fn isResultCurve(cs: *const CodegenState, cc: CodegenContext, result: ExpressionResult) bool {
    return switch (result) {
        .nothing => unreachable,
        .literal_curve => true,
        .self_param => |param_index| switch (cc) {
            .global => unreachable,
            .module => |cms| cs.modules[cms.module_index].params[param_index].param_type == .curve,
        },
        .track_param => |x| switch (cc) {
            .global => unreachable,
            .module => |cms| cs.tracks[x.track_index].params[x.param_index].param_type == .curve,
        },
        .temp_buffer, .temp_float, .literal_boolean, .literal_number, .literal_enum_value, .literal_track, .literal_module => false,
    };
}

fn isResultTrack(cs: *const CodegenState, cc: CodegenContext, result: ExpressionResult) ?usize {
    return switch (result) {
        .nothing => unreachable,
        .literal_track => |track_index| track_index,
        .self_param, .track_param, .temp_buffer, .temp_float, .literal_boolean, .literal_number, .literal_enum_value, .literal_curve, .literal_module => null,
    };
}

fn isResultModule(cs: *const CodegenState, cc: CodegenContext, result: ExpressionResult) ?usize {
    return switch (result) {
        .nothing => unreachable,
        .literal_module => |module_index| module_index,
        .self_param, .track_param, .temp_buffer, .temp_float, .literal_boolean, .literal_number, .literal_enum_value, .literal_curve, .literal_track => null,
    };
}

fn enumAllowsValue(allowed_values: []const BuiltinEnumValue, label: []const u8, has_float_payload: bool) bool {
    const allowed_value = for (allowed_values) |value| {
        if (std.mem.eql(u8, label, value.label)) break value;
    } else return false;
    return switch (allowed_value.payload_type) {
        .none => !has_float_payload,
        .f32 => has_float_payload,
    };
}

fn isResultEnumValue(cs: *const CodegenState, cc: CodegenContext, result: ExpressionResult, allowed_values: []const BuiltinEnumValue) bool {
    switch (result) {
        .nothing => unreachable,
        .literal_enum_value => |v| {
            const has_float_payload = if (v.payload) |p| isResultFloat(cs, cc, p.*) else false;
            return enumAllowsValue(allowed_values, v.label, has_float_payload);
        },
        .self_param => |param_index| {
            const cms = switch (cc) {
                .global => unreachable,
                .module => |x| x,
            };
            const possible_values = switch (cs.modules[cms.module_index].params[param_index].param_type) {
                .one_of => |e| e.values,
                else => return false,
            };
            // each of the possible values must be in the allowed_values
            for (possible_values) |possible_value| {
                const has_float_payload = switch (possible_value.payload_type) {
                    .none => false,
                    .f32 => true,
                };
                if (!enumAllowsValue(allowed_values, possible_value.label, has_float_payload)) return false;
            }
            return true;
        },
        .track_param => |x| {
            const cms = switch (cc) {
                .global => unreachable,
                .module => |m| m,
            };
            const possible_values = switch (cs.tracks[x.track_index].params[x.param_index].param_type) {
                .one_of => |e| e.values,
                else => return false,
            };
            // each of the possible values must be in the allowed_values
            for (possible_values) |possible_value| {
                const has_float_payload = switch (possible_value.payload_type) {
                    .none => false,
                    .f32 => true,
                };
                if (!enumAllowsValue(allowed_values, possible_value.label, has_float_payload)) return false;
            }
            return true;
        },
        .literal_boolean, .literal_number, .literal_curve, .literal_track, .literal_module, .temp_buffer, .temp_float => return false,
    }
}

// caller wants to return a float-typed result
fn requestFloatDest(cms: *CodegenModuleState) !FloatDest {
    // float-typed result locs don't exist for now
    const temp_float_index = try cms.temp_floats.claim();
    return FloatDest{ .temp_float_index = temp_float_index };
}

fn commitFloatDest(fd: FloatDest) !ExpressionResult {
    // since result_loc can never be float-typed, just do the simple thing
    return ExpressionResult{ .temp_float = TempRef.strong(fd.temp_float_index) };
}

// caller wants to return a buffer-typed result
fn requestBufferDest(cms: *CodegenModuleState, maybe_result_loc: ?BufferDest) !BufferDest {
    if (maybe_result_loc) |result_loc| {
        return result_loc;
    }
    const temp_buffer_index = try cms.temp_buffers.claim();
    return BufferDest{ .temp_buffer_index = temp_buffer_index };
}

fn commitBufferDest(maybe_result_loc: ?BufferDest, buffer_dest: BufferDest) !ExpressionResult {
    if (maybe_result_loc != null) {
        return ExpressionResult.nothing;
    }
    const temp_buffer_index = switch (buffer_dest) {
        .temp_buffer_index => |i| i,
        .output_index => unreachable,
    };
    return ExpressionResult{ .temp_buffer = TempRef.strong(temp_buffer_index) };
}

fn addInstruction(cms: *CodegenModuleState, instruction: Instruction) !void {
    if (cms.current_track_call) |current_track_call| {
        try current_track_call.instructions.append(instruction);
    } else if (cms.current_delay) |current_delay| {
        try current_delay.instructions.append(instruction);
    } else {
        try cms.instructions.append(instruction);
    }
}

fn genLiteralEnum(cs: *CodegenState, cc: CodegenContext, label: []const u8, payload: ?*const Expression) !ExpressionResult {
    if (payload) |payload_expr| {
        const payload_result = try genExpression(cs, cc, payload_expr, null);
        // the payload_result is now owned by the enum result, and will be released with it by releaseExpressionResult
        var payload_result_ptr = try cs.arena_allocator.create(ExpressionResult);
        payload_result_ptr.* = payload_result;
        return ExpressionResult{ .literal_enum_value = .{ .label = label, .payload = payload_result_ptr } };
    } else {
        return ExpressionResult{ .literal_enum_value = .{ .label = label, .payload = null } };
    }
}

fn genUnArith(cs: *CodegenState, cms: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, op: UnArithOp, ea: *const Expression) !ExpressionResult {
    const cc: CodegenContext = .{ .module = cms };

    const ra = try genExpression(cs, cc, ea, null);
    defer releaseExpressionResult(cms, ra);

    if (isResultFloat(cs, cc, ra)) {
        // float -> float
        const float_dest = try requestFloatDest(cms);
        try addInstruction(cms, .{ .arith_float = .{ .out = float_dest, .op = op, .a = ra } });
        return commitFloatDest(float_dest);
    }
    if (isResultBuffer(cs, cc, ra)) {
        // buffer -> buffer
        const buffer_dest = try requestBufferDest(cms, maybe_result_loc);
        try addInstruction(cms, .{ .arith_buffer = .{ .out = buffer_dest, .op = op, .a = ra } });
        return commitBufferDest(maybe_result_loc, buffer_dest);
    }
    return fail(cs.ctx, sr, "arithmetic can only be performed on numeric types", .{});
}

fn genBinArith(cs: *CodegenState, cms: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, op: BinArithOp, ea: *const Expression, eb: *const Expression) !ExpressionResult {
    const cc: CodegenContext = .{ .module = cms };

    const ra = try genExpression(cs, cc, ea, null);
    defer releaseExpressionResult(cms, ra);
    const rb = try genExpression(cs, cc, eb, null);
    defer releaseExpressionResult(cms, rb);

    if (isResultFloat(cs, cc, ra)) {
        if (isResultFloat(cs, cc, rb)) {
            // float * float -> float
            const float_dest = try requestFloatDest(cms);
            try addInstruction(cms, .{ .arith_float_float = .{ .out = float_dest, .op = op, .a = ra, .b = rb } });
            return commitFloatDest(float_dest);
        }
        if (isResultBuffer(cs, cc, rb)) {
            // float * buffer -> buffer
            const buffer_dest = try requestBufferDest(cms, maybe_result_loc);
            try addInstruction(cms, .{ .arith_float_buffer = .{ .out = buffer_dest, .op = op, .a = ra, .b = rb } });
            return commitBufferDest(maybe_result_loc, buffer_dest);
        }
    }
    if (isResultBuffer(cs, cc, ra)) {
        if (isResultFloat(cs, cc, rb)) {
            // buffer * float -> buffer
            const buffer_dest = try requestBufferDest(cms, maybe_result_loc);
            try addInstruction(cms, .{ .arith_buffer_float = .{ .out = buffer_dest, .op = op, .a = ra, .b = rb } });
            return commitBufferDest(maybe_result_loc, buffer_dest);
        }
        if (isResultBuffer(cs, cc, rb)) {
            // buffer * buffer -> buffer
            const buffer_dest = try requestBufferDest(cms, maybe_result_loc);
            try addInstruction(cms, .{ .arith_buffer_buffer = .{ .out = buffer_dest, .op = op, .a = ra, .b = rb } });
            return commitBufferDest(maybe_result_loc, buffer_dest);
        }
    }
    return fail(cs.ctx, sr, "arithmetic can only be performed on numeric types", .{});
}

// typecheck (coercing if possible) and return a value that matches the callee param's type
fn commitCalleeParam(cs: *const CodegenState, cc: CodegenContext, sr: SourceRange, result: ExpressionResult, callee_param_type: ParamType) !ExpressionResult {
    switch (callee_param_type) {
        .boolean => {
            if (isResultBoolean(cs, cc, result)) return result;
            return fail(cs.ctx, sr, "expected boolean value", .{});
        },
        .buffer => {
            if (isResultBuffer(cs, cc, result)) return result;
            if (isResultFloat(cs, cc, result)) {
                switch (cc) {
                    .global => unreachable,
                    .module => |cms| {
                        const temp_buffer_index = try cms.temp_buffers.claim();
                        try addInstruction(cms, .{ .float_to_buffer = .{ .out = .{ .temp_buffer_index = temp_buffer_index }, .in = result } });
                        return ExpressionResult{ .temp_buffer = TempRef.strong(temp_buffer_index) };
                    },
                }
            }
            return fail(cs.ctx, sr, "expected buffer value", .{});
        },
        .constant_or_buffer => {
            if (isResultBuffer(cs, cc, result)) return result;
            if (isResultFloat(cs, cc, result)) return result;
            return fail(cs.ctx, sr, "expected float or buffer value", .{});
        },
        .constant => {
            if (isResultFloat(cs, cc, result)) return result;
            return fail(cs.ctx, sr, "expected float value", .{});
        },
        .curve => {
            if (isResultCurve(cs, cc, result)) return result;
            return fail(cs.ctx, sr, "expected curve value", .{});
        },
        .one_of => |e| {
            if (isResultEnumValue(cs, cc, result, e.values)) return result;
            return fail(cs.ctx, sr, "expected one of |", .{e.values});
        },
    }
}

// remember to call releaseExpressionResult on the results afterward
fn genArgs(
    cs: *CodegenState,
    cc: CodegenContext,
    sr: SourceRange,
    params: []const ModuleParam,
    args: []const CallArg,
) ![]const ExpressionResult {
    for (args) |a| {
        for (params) |param| {
            if (std.mem.eql(u8, a.param_name, param.name)) break;
        } else return fail(cs.ctx, a.param_name_token.source_range, "call target has no param called `<`", .{});
    }
    var arg_results = try cs.arena_allocator.alloc(ExpressionResult, params.len);
    for (params) |param, i| {
        // find this arg in the call node
        var maybe_arg: ?CallArg = null;
        for (args) |a| {
            if (!std.mem.eql(u8, a.param_name, param.name)) continue;
            if (maybe_arg != null) return fail(cs.ctx, a.param_name_token.source_range, "param `<` provided more than once", .{});
            maybe_arg = a;
        }
        switch (cc) {
            .global => {},
            .module => |cms| {
                if (maybe_arg == null and std.mem.eql(u8, param.name, "sample_rate")) {
                    // sample_rate is passed implicitly
                    const self_param_index = for (cs.modules[cms.module_index].params) |self_param, j| {
                        if (std.mem.eql(u8, self_param.name, "sample_rate")) break j;
                    } else unreachable;
                    arg_results[i] = .{ .self_param = self_param_index };
                    continue;
                }
            },
        }
        const arg = maybe_arg orelse return fail(cs.ctx, sr, "argument list is missing param `#`", .{param.name});
        const result = try genExpression(cs, cc, arg.value, null);
        arg_results[i] = try commitCalleeParam(cs, cc, arg.value.source_range, result, param.param_type);
    }
    return arg_results;
}

fn genCall(
    cs: *CodegenState,
    cms: *CodegenModuleState,
    sr: SourceRange,
    maybe_result_loc: ?BufferDest,
    call: Call,
) !ExpressionResult {
    // generate the expression that resolves to the module to be called
    const field_result = try genExpression(cs, .{ .module = cms }, call.field_expr, null);
    const callee_module_index = isResultModule(cs, .{ .module = cms }, field_result) orelse {
        return fail(cs.ctx, call.field_expr.source_range, "not a module", .{});
    };

    // add a "field" to the self module
    const field_index = cms.fields.items.len;
    try cms.fields.append(.{
        .module_index = callee_module_index,
    });

    // typecheck and codegen the args
    const callee_module = cs.modules[callee_module_index];
    const arg_results = try genArgs(cs, .{ .module = cms }, sr, callee_module.params, call.args);
    defer for (callee_module.params) |param, i| releaseExpressionResult(cms, arg_results[i]);

    // the callee needs temps for its own internal use
    var temps = try cs.arena_allocator.alloc(usize, cs.module_results[callee_module_index].?.num_temps);
    for (temps) |*ptr| ptr.* = try cms.temp_buffers.claim();
    defer for (temps) |temp_buffer_index| cms.temp_buffers.release(temp_buffer_index);

    const buffer_dest = try requestBufferDest(cms, maybe_result_loc);
    try addInstruction(cms, .{
        .call = .{
            .out = buffer_dest,
            .field_index = field_index,
            .temps = temps,
            .args = arg_results,
        },
    });
    return commitBufferDest(maybe_result_loc, buffer_dest);
}

fn genTrackCall(
    cs: *CodegenState,
    cms: *CodegenModuleState,
    sr: SourceRange,
    maybe_result_loc: ?BufferDest,
    track_call: TrackCall,
) !ExpressionResult {
    if (cms.current_track_call != null) {
        return fail(cs.ctx, sr, "you cannot nest track calls", .{});
    }
    if (cms.current_delay != null) {
        return fail(cs.ctx, sr, "you cannot use a track call inside a delay", .{});
    }

    const track_result = try genExpression(cs, .{ .module = cms }, track_call.track_expr, null);
    const track_index = isResultTrack(cs, .{ .module = cms }, track_result) orelse {
        return fail(cs.ctx, track_call.track_expr.source_range, "not a track", .{});
    };

    const speed_result = try genExpression(cs, .{ .module = cms }, track_call.speed, null);
    if (!isResultFloat(cs, .{ .module = cms }, speed_result)) {
        return fail(cs.ctx, track_call.speed.source_range, "speed must be a constant value", .{});
    }

    const trigger_index = cms.triggers.items.len;
    try cms.triggers.append(.{ .track_index = track_index });

    const note_tracker_index = cms.note_trackers.items.len;
    try cms.note_trackers.append(.{ .track_index = track_index });

    const buffer_dest = try requestBufferDest(cms, maybe_result_loc);

    var current_track_call: CurrentTrackCall = .{
        .track_index = track_index,
        .instructions = std.ArrayList(Instruction).init(cs.arena_allocator),
    };

    cms.current_track_call = &current_track_call;

    for (track_call.scope.statements.items) |statement| {
        switch (statement) {
            .let_assignment => |x| {
                cms.local_results[x.local_index] = try genExpression(cs, .{ .module = cms }, x.expression, null);
            },
            .output => |expr| {
                const result = try genExpression(cs, .{ .module = cms }, expr, buffer_dest);
                try commitOutput(cs, cms, expr.source_range, result, buffer_dest);
                releaseExpressionResult(cms, result); // this should do nothing (because we passed a result loc)
            },
            .feedback => |expr| {
                return fail(cs.ctx, expr.source_range, "`feedback` can only be used within a `delay` operation", .{});
            },
        }
    }

    cms.current_track_call = null;

    try addInstruction(cms, .{
        .track_call = .{
            .out = buffer_dest,
            .track_index = track_index,
            .speed = speed_result,
            .trigger_index = trigger_index,
            .note_tracker_index = note_tracker_index,
            .instructions = current_track_call.instructions.toOwnedSlice(),
        },
    });

    releaseExpressionResult(cms, speed_result);

    return commitBufferDest(maybe_result_loc, buffer_dest);
}

fn genDelay(cs: *CodegenState, cms: *CodegenModuleState, sr: SourceRange, maybe_result_loc: ?BufferDest, delay: Delay) !ExpressionResult {
    if (cms.current_delay != null) {
        return fail(cs.ctx, sr, "you cannot nest delay operations", .{}); // i might be able to support this, but why?
    }
    if (cms.current_track_call != null) {
        return fail(cs.ctx, sr, "you cannot use a delay inside a track call", .{});
    }

    const delay_index = cms.delays.items.len;
    try cms.delays.append(.{ .num_samples = delay.num_samples });

    const feedback_temp_index = try cms.temp_buffers.claim();
    defer cms.temp_buffers.release(feedback_temp_index);

    const buffer_dest = try requestBufferDest(cms, maybe_result_loc);

    const feedback_out_temp_index = try cms.temp_buffers.claim();
    defer cms.temp_buffers.release(feedback_out_temp_index);

    var current_delay: CurrentDelay = .{
        .feedback_temp_index = feedback_temp_index,
        .instructions = std.ArrayList(Instruction).init(cs.arena_allocator),
    };

    cms.current_delay = &current_delay;

    for (delay.scope.statements.items) |statement| {
        switch (statement) {
            .let_assignment => |x| {
                cms.local_results[x.local_index] = try genExpression(cs, .{ .module = cms }, x.expression, null);
            },
            .output => |expr| {
                const result = try genExpression(cs, .{ .module = cms }, expr, buffer_dest);
                try commitOutput(cs, cms, expr.source_range, result, buffer_dest);
                releaseExpressionResult(cms, result); // this should do nothing (because we passed a result loc)
            },
            .feedback => |expr| {
                const result_loc: BufferDest = .{ .temp_buffer_index = feedback_out_temp_index };
                const result = try genExpression(cs, .{ .module = cms }, expr, result_loc);
                try commitOutput(cs, cms, expr.source_range, result, result_loc);
                releaseExpressionResult(cms, result); // this should do nothing (because we passed a result loc)
            },
        }
    }

    cms.current_delay = null;

    try addInstruction(cms, .{
        .delay = .{
            .out = buffer_dest,
            .delay_index = delay_index,
            .feedback_out_temp_buffer_index = feedback_out_temp_index,
            .feedback_temp_buffer_index = feedback_temp_index, // do i need this?
            .instructions = current_delay.instructions.toOwnedSlice(),
        },
    });

    return commitBufferDest(maybe_result_loc, buffer_dest);
}

fn genTrack(cs: *CodegenState, track_index: usize) !void {
    if (cs.track_results[track_index] != null) {
        return; // already generated
    }
    const track = cs.tracks[track_index];
    var notes = try cs.arena_allocator.alloc([]const ExpressionResult, track.notes.len);
    for (track.notes) |note, note_index| {
        notes[note_index] = try genArgs(cs, .global, note.args_source_range, track.params, note.args);
    }
    // don't need to call releaseExpressionResult since we're at the global scope where
    // temporaries can't exist anyway
    cs.track_results[track_index] = .{ .note_values = notes };
}

fn genModule(cs: *CodegenState, module_index: usize) !void {
    if (cs.module_results[module_index] != null) {
        return; // already generated
    }

    const module_info = cs.modules[module_index].info.?;

    var cms: CodegenModuleState = .{
        .module_index = module_index,
        .locals = module_info.locals,
        .instructions = std.ArrayList(Instruction).init(cs.arena_allocator),
        .temp_buffers = TempManager.init(cs.inner_allocator, true),
        // pass false: don't reuse temp floats slots (they become `const` in zig)
        // TODO we could reuse them if we're targeting runtime, not codegen_zig
        .temp_floats = TempManager.init(cs.inner_allocator, false),
        .local_results = try cs.arena_allocator.alloc(?ExpressionResult, module_info.locals.len),
        .fields = std.ArrayList(Field).init(cs.arena_allocator),
        .delays = std.ArrayList(DelayDecl).init(cs.arena_allocator),
        .triggers = std.ArrayList(TriggerDecl).init(cs.arena_allocator),
        .note_trackers = std.ArrayList(NoteTrackerDecl).init(cs.arena_allocator),
        .current_delay = null,
        .current_track_call = null,
    };
    defer cms.temp_buffers.deinit();
    defer cms.temp_floats.deinit();

    std.mem.set(?ExpressionResult, cms.local_results, null);

    for (module_info.scope.statements.items) |statement| {
        try genTopLevelStatement(cs, &cms, statement);
    }

    for (cms.local_results) |maybe_result| {
        const result = maybe_result orelse continue;
        releaseExpressionResult(&cms, result);
    }

    cms.temp_buffers.reportLeaks();
    cms.temp_floats.reportLeaks();

    if (cs.dump_codegen_out) |out| {
        printBytecode(out, cs, &cms) catch |err| std.debug.warn("printBytecode failed: {}\n", .{err});
    }

    cs.module_results[module_index] = .{
        .num_outputs = 1,
        .num_temps = cms.temp_buffers.finalCount(),
        .num_temp_floats = cms.temp_floats.finalCount(),
        .inner = .{
            .custom = .{
                .fields = cms.fields.toOwnedSlice(),
                .delays = cms.delays.toOwnedSlice(),
                .note_trackers = cms.note_trackers.toOwnedSlice(),
                .triggers = cms.triggers.toOwnedSlice(),
                .instructions = cms.instructions.toOwnedSlice(),
            },
        },
    };
}

pub const GenError = error{
    Failed,
    OutOfMemory,
};

// generate bytecode instructions for an expression
fn genExpression(
    cs: *CodegenState,
    cc: CodegenContext,
    expr: *const Expression,
    maybe_result_loc: ?BufferDest,
) GenError!ExpressionResult {
    switch (expr.inner) {
        .literal_boolean => |value| return ExpressionResult{ .literal_boolean = value },
        .literal_number => |value| return ExpressionResult{ .literal_number = value },
        .literal_enum_value => |v| return genLiteralEnum(cs, cc, v.label, v.payload),
        .literal_curve => |curve_index| return ExpressionResult{ .literal_curve = curve_index },
        .literal_track => |track_index| {
            try genTrack(cs, track_index);
            return ExpressionResult{ .literal_track = track_index };
        },
        .literal_module => |module_index| {
            try genModule(cs, module_index);
            return ExpressionResult{ .literal_module = module_index };
        },
        .name => |token| {
            const name = cs.ctx.source.getString(token.source_range);
            switch (cc) {
                .global => {},
                .module => |cms| {
                    // is it a param from a track call?
                    if (cms.current_track_call) |ctc| {
                        for (cs.tracks[ctc.track_index].params) |param, param_index| {
                            if (!std.mem.eql(u8, param.name, name)) continue;
                            // note: tracks aren't allowed to use buffer or cob types. so we don't need the cob-to-buffer
                            // instruction that self_param uses
                            return ExpressionResult{ .track_param = .{ .track_index = ctc.track_index, .param_index = param_index } };
                        }
                    }
                    // is it a param of the current module?
                    for (cs.modules[cms.module_index].params) |param, param_index| {
                        if (!std.mem.eql(u8, param.name, name)) continue;
                        // immediately turn constant_or_buffer into buffer (the rest of codegen isn't able to work with constant_or_buffer)
                        if (param.param_type == .constant_or_buffer) {
                            const buffer_dest = try requestBufferDest(cms, maybe_result_loc);
                            try addInstruction(cms, .{ .cob_to_buffer = .{ .out = buffer_dest, .in_self_param = param_index } });
                            return try commitBufferDest(maybe_result_loc, buffer_dest);
                        } else {
                            return ExpressionResult{ .self_param = param_index };
                        }
                    }
                },
            }
            // is it a global?
            const global_index = for (cs.globals) |global, i| {
                if (std.mem.eql(u8, name, global.name)) break i;
            } else return fail(cs.ctx, token.source_range, "use of undeclared identifier `<`", .{});
            if (cs.global_results[global_index] == null) {
                // globals defined out of order - generate recursively
                if (cs.global_visited[global_index]) {
                    return fail(cs.ctx, token.source_range, "circular reference in global", .{});
                }
                cs.global_visited[global_index] = true;
                cs.global_results[global_index] = try genExpression(cs, .global, cs.globals[global_index].value, null);
            }
            const result = cs.global_results[global_index].?;
            switch (result) {
                .temp_buffer => |temp_ref| return ExpressionResult{ .temp_buffer = TempRef.weak(temp_ref.index) },
                .temp_float => |temp_ref| return ExpressionResult{ .temp_float = TempRef.weak(temp_ref.index) },
                else => return result,
            }
        },
        .local => |local_index| {
            switch (cc) {
                .global => unreachable,
                .module => |cms| {
                    // a local is just a saved ExpressionResult. make a weak-reference version of it
                    const result = cms.local_results[local_index].?;
                    switch (result) {
                        .temp_buffer => |temp_ref| return ExpressionResult{ .temp_buffer = TempRef.weak(temp_ref.index) },
                        .temp_float => |temp_ref| return ExpressionResult{ .temp_float = TempRef.weak(temp_ref.index) },
                        else => return result,
                    }
                },
            }
        },
        .un_arith => |m| {
            switch (cc) {
                .global => return fail(cs.ctx, expr.source_range, "constant arithmetic is not supported", .{}),
                .module => |cms| return try genUnArith(cs, cms, expr.source_range, maybe_result_loc, m.op, m.a),
            }
        },
        .bin_arith => |m| {
            switch (cc) {
                .global => return fail(cs.ctx, expr.source_range, "constant arithmetic is not supported", .{}),
                .module => |cms| return try genBinArith(cs, cms, expr.source_range, maybe_result_loc, m.op, m.a, m.b),
            }
        },
        .call => |call| {
            switch (cc) {
                .global => unreachable,
                .module => |cms| return try genCall(cs, cms, expr.source_range, maybe_result_loc, call),
            }
        },
        .track_call => |track_call| {
            switch (cc) {
                .global => unreachable,
                .module => |cms| return try genTrackCall(cs, cms, expr.source_range, maybe_result_loc, track_call),
            }
        },
        .delay => |delay| {
            switch (cc) {
                .global => unreachable,
                .module => |cms| return try genDelay(cs, cms, expr.source_range, maybe_result_loc, delay),
            }
        },
        .feedback => {
            switch (cc) {
                .global => unreachable,
                .module => |cms| {
                    const feedback_temp_index = if (cms.current_delay) |current_delay|
                        current_delay.feedback_temp_index
                    else
                        return fail(cs.ctx, expr.source_range, "`feedback` can only be used within a `delay` operation", .{});
                    return ExpressionResult{ .temp_buffer = TempRef.weak(feedback_temp_index) };
                },
            }
        },
    }
}

// typecheck and make sure that the expression result is written into buffer_dest.
fn commitOutput(cs: *const CodegenState, cms: *CodegenModuleState, sr: SourceRange, result: ExpressionResult, buffer_dest: BufferDest) !void {
    switch (result) {
        .nothing => {
            // value has already been written into the result location
        },
        .temp_buffer => {
            try addInstruction(cms, .{ .copy_buffer = .{ .out = buffer_dest, .in = result } });
        },
        .temp_float, .literal_number => {
            try addInstruction(cms, .{ .float_to_buffer = .{ .out = buffer_dest, .in = result } });
        },
        .literal_boolean => return fail(cs.ctx, sr, "expected buffer value, found boolean", .{}),
        .literal_enum_value => return fail(cs.ctx, sr, "expected buffer value, found enum value", .{}),
        .literal_curve => return fail(cs.ctx, sr, "expected buffer value, found curve", .{}),
        .literal_track => return fail(cs.ctx, sr, "expected buffer value, found track", .{}),
        .literal_module => return fail(cs.ctx, sr, "expected buffer value, found module", .{}),
        .self_param => |param_index| {
            switch (cs.modules[cms.module_index].params[param_index].param_type) {
                .boolean => return fail(cs.ctx, sr, "expected buffer value, found boolean", .{}),
                .buffer, .constant_or_buffer => { // constant_or_buffer are immediately unwrapped to buffers in codegen (for now)
                    try addInstruction(cms, .{ .copy_buffer = .{ .out = buffer_dest, .in = .{ .self_param = param_index } } });
                },
                .constant => {
                    try addInstruction(cms, .{ .float_to_buffer = .{ .out = buffer_dest, .in = .{ .self_param = param_index } } });
                },
                .curve => return fail(cs.ctx, sr, "expected buffer value, found curve", .{}),
                .one_of => |e| return fail(cs.ctx, sr, "expected buffer value, found enum value", .{}),
            }
        },
        .track_param => |x| {
            switch (cs.tracks[x.track_index].params[x.param_index].param_type) {
                .boolean => return fail(cs.ctx, sr, "expected buffer value, found boolean", .{}),
                .buffer, .constant_or_buffer => { // constant_or_buffer are immediately unwrapped to buffers in codegen (for now)
                    try addInstruction(cms, .{ .copy_buffer = .{ .out = buffer_dest, .in = .{ .track_param = x } } });
                },
                .constant => {
                    try addInstruction(cms, .{ .float_to_buffer = .{ .out = buffer_dest, .in = .{ .track_param = x } } });
                },
                .curve => return fail(cs.ctx, sr, "expected buffer value, found curve", .{}),
                .one_of => |e| return fail(cs.ctx, sr, "expected buffer value, found enum value", .{}),
            }
        },
    }
}

fn genTopLevelStatement(cs: *CodegenState, cms: *CodegenModuleState, statement: Statement) !void {
    std.debug.assert(cms.current_delay == null);
    std.debug.assert(cms.current_track_call == null);

    switch (statement) {
        .let_assignment => |x| {
            cms.local_results[x.local_index] = try genExpression(cs, .{ .module = cms }, x.expression, null);
        },
        .output => |expression| {
            const result_loc: BufferDest = .{ .output_index = 0 };
            const result = try genExpression(cs, .{ .module = cms }, expression, result_loc);
            try commitOutput(cs, cms, expression.source_range, result, result_loc);
            releaseExpressionResult(cms, result); // this should do nothing (because we passed a result loc)
        },
        .feedback => |expression| {
            return fail(cs.ctx, expression.source_range, "`feedback` can only be used within a `delay` operation", .{});
        },
    }
}

pub const CodeGenTrackResult = struct {
    note_values: []const []const ExpressionResult, // values in order of track params
};

pub const CodeGenCustomModuleInner = struct {
    fields: []const Field, // owned slice
    delays: []const DelayDecl, // owned slice
    note_trackers: []const NoteTrackerDecl, // owned slice
    triggers: []const TriggerDecl, // owned slice
    instructions: []const Instruction, // owned slice
};

pub const CodeGenModuleResult = struct {
    num_outputs: usize,
    num_temps: usize,
    num_temp_floats: usize,
    inner: union(enum) {
        builtin,
        custom: CodeGenCustomModuleInner,
    },
};

pub const ExportedModule = struct {
    name: []const u8,
    module_index: usize,
};

pub const CodeGenResult = struct {
    arena: std.heap.ArenaAllocator,
    track_results: []const CodeGenTrackResult,
    module_results: []const CodeGenModuleResult,
    exported_modules: []const ExportedModule,

    pub fn deinit(self: *CodeGenResult) void {
        self.arena.deinit();
    }
};

// codegen entry point
pub fn codegen(
    ctx: Context,
    parse_result: ParseResult,
    inner_allocator: *std.mem.Allocator,
    dump_codegen_out: ?std.io.StreamSource.Writer,
) !CodeGenResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    // globals
    var global_results = try arena.allocator.alloc(?ExpressionResult, parse_result.globals.len);
    var global_visited = try arena.allocator.alloc(bool, parse_result.globals.len);
    std.mem.set(?ExpressionResult, global_results, null);
    std.mem.set(bool, global_visited, false);
    var track_results = try arena.allocator.alloc(?CodeGenTrackResult, parse_result.tracks.len);
    std.mem.set(?CodeGenTrackResult, track_results, null);
    var module_results = try arena.allocator.alloc(?CodeGenModuleResult, parse_result.modules.len);
    std.mem.set(?CodeGenModuleResult, module_results, null);

    var cs: CodegenState = .{
        .arena_allocator = &arena.allocator,
        .inner_allocator = inner_allocator,
        .ctx = ctx,
        .globals = parse_result.globals,
        .curves = parse_result.curves,
        .tracks = parse_result.tracks,
        .modules = parse_result.modules,
        .global_results = global_results,
        .global_visited = global_visited,
        .track_results = track_results,
        .module_results = module_results,
        .dump_codegen_out = dump_codegen_out,
    };

    // generate builtin modules
    var builtin_index: usize = 0;
    for (ctx.builtin_packages) |pkg| {
        for (pkg.builtins) |builtin| {
            module_results[builtin_index] = .{
                .num_outputs = builtin.num_outputs,
                .num_temps = builtin.num_temps,
                .num_temp_floats = 0,
                .inner = .builtin,
            };
            builtin_index += 1;
        }
    }

    for (parse_result.globals) |global, global_index| {
        // note: genExpression has the ability to call this recursively, if a global refers
        // to another global that hasn't been generated yet.
        if (global_visited[global_index]) {
            continue;
        }
        global_visited[global_index] = true;
        global_results[global_index] = try genExpression(&cs, .global, global.value, null);
    }

    var exported_modules = std.ArrayList(ExportedModule).init(&arena.allocator);
    for (parse_result.globals) |global, i| {
        switch (global_results[i].?) {
            .literal_module => |module_index| {
                if (parse_result.modules[module_index].info == null) continue;
                try exported_modules.append(.{
                    .name = global.name,
                    .module_index = module_index,
                });
            },
            else => {},
        }
    }

    // convert []?T to []T
    var track_results2 = try arena.allocator.alloc(CodeGenTrackResult, track_results.len);
    for (track_results) |maybe_result, i| {
        track_results2[i] = maybe_result.?;
    }
    var module_results2 = try arena.allocator.alloc(CodeGenModuleResult, module_results.len);
    for (module_results) |maybe_result, i| {
        module_results2[i] = maybe_result.?;
    }

    return CodeGenResult{
        .arena = arena,
        .track_results = track_results2,
        .module_results = module_results2,
        .exported_modules = exported_modules.toOwnedSlice(),
    };
}
