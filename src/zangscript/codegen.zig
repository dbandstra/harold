const std = @import("std");
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const ModuleDef = @import("first_pass.zig").ModuleDef;
const Expression = @import("second_pass.zig").Expression;
const CallArg = @import("second_pass.zig").CallArg;
const Call = @import("second_pass.zig").Call;
const Literal = @import("second_pass.zig").Literal;
const getExpressionType = @import("second_pass.zig").getExpressionType;

// TODO i'm tending towards the idea of this file not even being involved at all
// in runtime script mode.
// so type checking and everything like that should be moved all into second_pass.
// this file will be very specific for generating zig code, i think.
// although, i'm not sure. temp floats are not needed for runtime script mode,
// but temps (temp buffers) are? (although i could just allocate those dynamically
// as well since i don't have a lot of performance requirements for script mode.)

// FIXME - tag type should be datatype? (constant, boolean, constant_or_buffer)
pub const InstrCallArg = union(enum) {
    temp: usize,
    temp_float: usize,
    temp_bool: usize,
};

pub const InstrCall = struct {
    result_loc: ResultLoc,
    field_index: usize,
    // list of temp indices for the callee's internal use
    temps: std.ArrayList(usize),
    // in the order of the callee module's params
    args: []InstrCallArg,
};

pub const BufferLoc = union(enum) {
    temp: usize,
    output: usize,
};

pub const ResultLoc = union(enum) {
    buffer: BufferLoc,
    temp_float: usize,
    temp_bool: usize,
};

pub const InstrLoadBoolean = struct {
    out_index: usize,
    value: bool,
};

pub const InstrLoadConstant = struct {
    out_index: usize,
    value: f32,
};

pub const InstrFloatToBuffer = struct {
    out: BufferLoc,
    in_temp_float: usize,
};

pub const InstrLoadParamFloat = struct {
    out_temp_float: usize,
    param_index: usize,
};

pub const InstrArithFloatFloat = struct {
    operator: enum { add, multiply },
    out_temp_float: usize,
    a_temp_float: usize,
    b_temp_float: usize,
};

pub const InstrArithBufferFloat = struct {
    operator: enum { add, multiply },
    out: BufferLoc,
    temp_index: usize,
    temp_float_index: usize,
};

pub const Instruction = union(enum) {
    call: InstrCall,
    float_to_buffer: InstrFloatToBuffer,
    load_param_float: InstrLoadParamFloat,
    load_boolean: InstrLoadBoolean,
    load_constant: InstrLoadConstant,
    arith_float_float: InstrArithFloatFloat,
    arith_buffer_float: InstrArithBufferFloat,
};

const CodegenState = struct {
    allocator: *std.mem.Allocator,
    source: Source,
    module_def: *ModuleDef,
    instructions: std.ArrayList(Instruction),
    num_temps: usize,
    num_temp_floats: usize,
    num_temp_bools: usize,
};

const GenError = error{
    Failed,
    OutOfMemory,
};

fn genExpression(state: *CodegenState, result_loc: ResultLoc, expression: *const Expression) GenError!void {
    switch (expression.inner) {
        .call => |call| {
            const callee = state.module_def.fields.span()[call.field_index].resolved_module;

            var icall: InstrCall = .{
                .result_loc = result_loc,
                .field_index = call.field_index,
                .temps = std.ArrayList(usize).init(state.allocator),
                .args = try state.allocator.alloc(InstrCallArg, callee.params.len),
            };
            // TODO deinit

            // the callee needs temps for its own internal use
            var i: usize = 0;
            while (i < callee.num_temps) : (i += 1) {
                try icall.temps.append(state.num_temps);
                state.num_temps += 1;
            }

            // pass params
            for (callee.params) |param, j| {
                // find this arg in the call node. (not necessarily in the same order.)
                const arg = blk: {
                    for (call.args.span()) |a| {
                        if (std.mem.eql(u8, a.arg_name, param.name)) {
                            break :blk a;
                        }
                    }
                    // missing args was already checked in second_pass
                    unreachable;
                };

                // allocate a temporary to store subexpression result
                switch (param.param_type) {
                    .constant_or_buffer => {
                        const out_index = state.num_temps;
                        state.num_temps += 1;
                        try genExpression(state, .{ .buffer = .{ .temp = out_index } }, arg.value);

                        icall.args[j] = .{ .temp = out_index };
                    },
                    .constant => {
                        const out_index = state.num_temp_floats;
                        state.num_temp_floats += 1;
                        try genExpression(state, .{ .temp_float = out_index }, arg.value);

                        icall.args[j] = .{ .temp_float = out_index };
                    },
                    .boolean => {
                        const out_index = state.num_temp_bools;
                        state.num_temp_bools += 1;
                        try genExpression(state, .{ .temp_bool = out_index }, arg.value);

                        icall.args[j] = .{ .temp_bool = out_index };
                    },
                    else => unreachable,
                }
            }

            try state.instructions.append(.{ .call = icall });
        },
        .literal => |literal| {
            switch (result_loc) {
                .buffer => |buffer_loc| {
                    const temp_float_index = state.num_temp_floats;
                    state.num_temp_floats += 1;
                    try state.instructions.append(.{
                        .load_constant = .{
                            .out_index = temp_float_index,
                            .value = switch (literal) {
                                .constant => |v| v,
                                else => unreachable,
                            },
                        },
                    });
                    try state.instructions.append(.{
                        .float_to_buffer = .{
                            .out = buffer_loc,
                            .in_temp_float = temp_float_index,
                        },
                    });
                },
                .temp_float => |index| {
                    try state.instructions.append(.{
                        .load_constant = .{
                            .out_index = index,
                            .value = switch (literal) {
                                .constant => |v| v,
                                else => unreachable,
                            },
                        },
                    });
                },
                .temp_bool => |index| {
                    try state.instructions.append(.{
                        .load_boolean = .{
                            .out_index = index,
                            .value = switch (literal) {
                                .boolean => |v| v,
                                else => unreachable,
                            },
                        },
                    });
                },
            }
        },
        .self_param => |param_index| {
            const param = &state.module_def.resolved.params[param_index];
            switch (result_loc) {
                .buffer => |buffer_loc| {
                    // result is a buffer. what is the param type?
                    switch (param.param_type) {
                        .constant => {
                            const temp_float_index = state.num_temp_floats;
                            state.num_temp_floats += 1;
                            try state.instructions.append(.{
                                .load_param_float = .{
                                    .out_temp_float = temp_float_index,
                                    .param_index = param_index,
                                },
                            });
                            try state.instructions.append(.{
                                .float_to_buffer = .{
                                    .out = buffer_loc,
                                    .in_temp_float = temp_float_index,
                                },
                            });
                        },
                        else => unreachable,
                    }
                },
                .temp_float => |index| {
                    // result is a float. what is the param type?
                    switch (param.param_type) {
                        .constant => {
                            try state.instructions.append(.{
                                .load_param_float = .{
                                    .out_temp_float = index,
                                    .param_index = param_index,
                                },
                            });
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        },
        .binary_arithmetic => |m| {
            // no type checking has been performed yet...
            // (not true?)
            const a_type = try getExpressionType(state.source, state.module_def, m.a);
            const b_type = try getExpressionType(state.source, state.module_def, m.b);

            switch (result_loc) {
                .temp_bool => {
                    unreachable;
                },
                .temp_float => |out_temp_float| {
                    // float = float + float
                    if (a_type != .constant or b_type != .constant) {
                        return fail(state.source, expression.source_range, "dest is float, so operands must both be floats", .{});
                    }

                    const out_index_a = state.num_temp_floats;
                    state.num_temp_floats += 1;
                    try genExpression(state, .{ .temp_float = out_index_a }, m.a);

                    const out_index_b = state.num_temp_floats;
                    state.num_temp_floats += 1;
                    try genExpression(state, .{ .temp_float = out_index_b }, m.b);

                    try state.instructions.append(.{
                        .arith_float_float = .{
                            .operator = switch (m.operator) {
                                .add => .add,
                                .multiply => .multiply,
                            },
                            .out_temp_float = out_temp_float,
                            .a_temp_float = out_index_a,
                            .b_temp_float = out_index_b,
                        },
                    });
                },
                .buffer => |buffer_loc| {
                    // FIXME constant_or_buffer makes no sense here!
                    if (a_type == .constant_or_buffer and b_type == .constant) {
                        const out_index_a = state.num_temps;
                        state.num_temps += 1;
                        try genExpression(state, .{ .buffer = .{ .temp = out_index_a } }, m.a);

                        const out_index_b = state.num_temp_floats;
                        state.num_temp_floats += 1;
                        try genExpression(state, .{ .temp_float = out_index_b }, m.b);

                        try state.instructions.append(.{
                            .arith_buffer_float = .{
                                .operator = switch (m.operator) {
                                    .add => .add,
                                    .multiply => .multiply,
                                },
                                .out = buffer_loc,
                                .temp_index = out_index_a,
                                .temp_float_index = out_index_b,
                            },
                        });
                    } else if (a_type == .constant and b_type == .constant_or_buffer) {
                        const out_index_a = state.num_temp_floats;
                        state.num_temp_floats += 1;
                        try genExpression(state, .{ .temp_float = out_index_a }, m.a);

                        const out_index_b = state.num_temps;
                        state.num_temps += 1;
                        try genExpression(state, .{ .buffer = .{ .temp = out_index_b } }, m.b);

                        try state.instructions.append(.{
                            .arith_buffer_float = .{
                                .operator = switch (m.operator) {
                                    .add => .add,
                                    .multiply => .multiply,
                                },
                                .out = buffer_loc,
                                .temp_index = out_index_a,
                                .temp_float_index = out_index_b,
                            },
                        });
                    } else if (a_type == .constant and b_type == .constant) {
                        const out_temp_float = state.num_temp_floats;
                        state.num_temp_floats += 1;

                        const out_index_a = state.num_temp_floats;
                        state.num_temp_floats += 1;
                        try genExpression(state, .{ .temp_float = out_index_a }, m.a);

                        const out_index_b = state.num_temp_floats;
                        state.num_temp_floats += 1;
                        try genExpression(state, .{ .temp_float = out_index_b }, m.b);

                        try state.instructions.append(.{
                            .arith_float_float = .{
                                .operator = switch (m.operator) {
                                    .add => .add,
                                    .multiply => .multiply,
                                },
                                .out_temp_float = out_temp_float,
                                .a_temp_float = out_index_a,
                                .b_temp_float = out_index_b,
                            },
                        });
                        try state.instructions.append(.{
                            .float_to_buffer = .{
                                .out = buffer_loc,
                                .in_temp_float = out_temp_float,
                            },
                        });
                    } else {
                        return fail(state.source, expression.source_range, "dest is buffer, unsupported operand types", .{});
                    }
                },
            }
        },
        .nothing => {},
    }
}

pub fn codegen(source: Source, module_def: *ModuleDef, expression: *const Expression, allocator: *std.mem.Allocator) !void {
    var state: CodegenState = .{
        .allocator = allocator,
        .source = source,
        .module_def = module_def,
        .instructions = std.ArrayList(Instruction).init(allocator),
        .num_temps = 0,
        .num_temp_floats = 0,
        .num_temp_bools = 0,
    };
    // TODO deinit

    try genExpression(&state, .{ .buffer = .{ .output = 0 } }, expression);

    module_def.resolved.num_outputs = 1;
    module_def.resolved.num_temps = state.num_temps;
    module_def.instructions = state.instructions.span();

    std.debug.warn("num_temps: {}\n", .{state.num_temps});
    std.debug.warn("num_temp_floats: {}\n", .{state.num_temp_floats});
    std.debug.warn("num_temp_bools: {}\n", .{state.num_temp_bools});
    printBytecode(module_def, state.instructions.span());
    std.debug.warn("\n", .{});
}

pub fn printBytecode(module_def: *const ModuleDef, instructions: []const Instruction) void {
    std.debug.warn("bytecode:\n", .{});
    for (instructions) |instr| {
        std.debug.warn("    ", .{});
        switch (instr) {
            .call => |call| {
                switch (call.result_loc) {
                    .buffer => |buffer_loc| {
                        switch (buffer_loc) {
                            .output => |n| std.debug.warn("output{}", .{n}),
                            .temp => |n| std.debug.warn("temp{}", .{n}),
                        }
                    },
                    .temp_float => |n| std.debug.warn("temp_float{}", .{n}),
                    .temp_bool => |n| std.debug.warn("temp_bool{}", .{n}),
                }
                std.debug.warn(" = CALL #{}({}: {})\n", .{
                    call.field_index,
                    module_def.fields.span()[call.field_index].name,
                    module_def.fields.span()[call.field_index].resolved_module.name,
                });
                std.debug.warn("        temps: [", .{});
                for (call.temps.span()) |temp, i| {
                    if (i > 0) std.debug.warn(", ", .{});
                    std.debug.warn("temp{}", .{temp});
                }
                std.debug.warn("]\n", .{});
                for (call.args) |arg, i| {
                    const param = &module_def.fields.span()[call.field_index].resolved_module.params[i];
                    std.debug.warn("        {} = ", .{param.name});
                    switch (arg) {
                        .temp => |v| {
                            std.debug.warn("temp{}\n", .{v});
                        },
                        .temp_float => |n| {
                            std.debug.warn("temp_float{}\n", .{n});
                        },
                        .temp_bool => |n| {
                            std.debug.warn("temp_bool{}\n", .{n});
                        },
                    }
                }
            },
            .load_constant => |x| {
                std.debug.warn("temp_float{} = LOADCONSTANT {d}\n", .{ x.out_index, x.value });
            },
            .load_boolean => |x| {
                std.debug.warn("temp_bool{} = LOADBOOLEAN {}\n", .{ x.out_index, x.value });
            },
            .float_to_buffer => |x| {
                switch (x.out) {
                    .temp => |n| std.debug.warn("temp{}", .{n}),
                    .output => |n| std.debug.warn("output{}", .{n}),
                }
                std.debug.warn(" = FLOAT_TO_BUFFER temp_float{}\n", .{x.in_temp_float});
            },
            .load_param_float => |x| {
                std.debug.warn("temp_float{} = LOADPARAM_FLOAT ${}({})\n", .{
                    x.out_temp_float,
                    x.param_index,
                    module_def.resolved.params[x.param_index].name,
                });
            },
            .arith_float_float => |x| {
                std.debug.warn("temp_float{} = ARITH_FLOAT_FLOAT {} temp_float{} temp_float{}\n", .{
                    x.operator,
                    x.out_temp_float,
                    x.a_temp_float,
                    x.b_temp_float,
                });
            },
            .arith_buffer_float => |x| {
                switch (x.out) {
                    .temp => |n| std.debug.warn("temp{}", .{n}),
                    .output => |n| std.debug.warn("output{}", .{n}),
                }
                std.debug.warn(" = ARITH_BUFFER_FLOAT {} temp{} temp_float{}\n", .{
                    x.operator,
                    x.temp_index,
                    x.temp_float_index,
                });
            },
        }
    }
}
