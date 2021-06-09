const std = @import("std");
const Context = @import("context.zig").Context;
const Source = @import("context.zig").Source;
const SourceLocation = @import("context.zig").SourceLocation;
const SourceRange = @import("context.zig").SourceRange;
const Token = @import("tokenize.zig").Token;
const TokenType = @import("tokenize.zig").TokenType;
const Tokenizer = @import("tokenize.zig").Tokenizer;
const fail = @import("fail.zig").fail;
const BuiltinEnum = @import("builtins.zig").BuiltinEnum;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const parsePrintModule = @import("parse_print.zig").parsePrintModule;

pub const Curve = struct {
    points: []const CurvePoint,
};

pub const CurvePoint = struct {
    t: NumberLiteral,
    value: NumberLiteral,
};

pub const Track = struct {
    params: []const ModuleParam,
    notes: []const TrackNote,
};

pub const TrackNote = struct {
    t: NumberLiteral,
    args_source_range: SourceRange,
    args: []const CallArg,
};

pub const ParamType = union(enum) {
    boolean,
    buffer,
    constant,
    constant_or_buffer,
    curve,
    one_of: BuiltinEnum,
};

pub const ModuleParam = struct {
    name: []const u8,
    param_type: ParamType,
};

pub const ParsedModuleInfo = struct {
    scope: *Scope,
    locals: []const Local,
};

pub const Module = struct {
    params: []const ModuleParam,
    builtin_name: ?[]const u8,
    zig_package_name: ?[]const u8, // only set for builtin modules
    info: ?ParsedModuleInfo, // null for builtin modules
};

pub const Scope = struct {
    parent: ?*const Scope,
    statements: std.ArrayList(Statement),
};

pub const CallArg = struct {
    param_name: []const u8,
    param_name_token: Token,
    value: *const Expression,
};

pub const Call = struct {
    field_expr: *const Expression, // should be a literal_module
    args: []const CallArg,
};

pub const TrackCall = struct {
    track_expr: *const Expression,
    speed: *const Expression,
    scope: *Scope,
};

pub const Delay = struct {
    num_samples: usize,
    scope: *Scope,
};

pub const UnArithOp = enum {
    abs,
    cos,
    neg,
    sin,
    sqrt,
};

pub const UnArith = struct {
    op: UnArithOp,
    a: *const Expression,
};

pub const BinArithOp = enum {
    add,
    div,
    max,
    min,
    mul,
    pow,
    sub,
};

pub const BinArith = struct {
    op: BinArithOp,
    a: *const Expression,
    b: *const Expression,
};

pub const Local = struct {
    name: []const u8,
};

pub const Global = struct {
    name: []const u8,
    value: *const Expression,
};

pub const NumberLiteral = struct {
    value: f32,
    // copy the number literal verbatim from the script so we don't get things
    // like 0.7 becoming 0.699999988079071
    verbatim: []const u8,
};

pub const EnumLiteral = struct {
    label: []const u8,
    payload: ?*const Expression,
};

pub const ExpressionInner = union(enum) {
    call: Call,
    track_call: TrackCall,
    delay: Delay,
    literal_boolean: bool,
    literal_number: NumberLiteral,
    literal_enum_value: EnumLiteral,
    literal_curve: usize,
    literal_track: usize,
    literal_module: usize,
    un_arith: UnArith,
    bin_arith: BinArith,
    local: usize, // index into flat `locals` array
    feedback, // only allowed within `delay` expressions
    name: Token, // a name that isn't a local, so it can't be resolved until codegen
};

pub const Expression = struct {
    source_range: SourceRange,
    inner: ExpressionInner,
};

pub const Statement = union(enum) {
    let_assignment: struct { local_index: usize, expression: *const Expression },
    output: *const Expression,
    feedback: *const Expression,
};

const ParseState = struct {
    arena_allocator: *std.mem.Allocator,
    tokenizer: Tokenizer,
    globals: std.ArrayList(Global),
    enums: std.ArrayList(BuiltinEnum),
    curves: std.ArrayList(Curve),
    tracks: std.ArrayList(Track),
    modules: std.ArrayList(Module),
};

const ParseModuleState = struct {
    params: []const ModuleParam,
    locals: std.ArrayList(Local),
};

const ParseContext = union(enum) {
    global,
    module: ParseContextModule,
};

const ParseContextModule = struct {
    ps_mod: *ParseModuleState,
    scope: *const Scope,
};

// names that you can't use for params or locals because they are builtin functions or constants
const reserved_names = [_][]const u8{
    "abs",
    "cos",
    "max",
    "min",
    "pi",
    "pow",
    "sample_rate",
    "sin",
    "sqrt",
};

fn defineCurve(ps: *ParseState) !usize {
    var points = std.ArrayList(CurvePoint).init(ps.arena_allocator);
    var maybe_last_t: ?f32 = null;
    while (true) {
        const token = try ps.tokenizer.next();
        switch (token.tt) {
            .kw_end => break,
            .number => |t| {
                if (maybe_last_t) |last_t| {
                    if (t <= last_t) {
                        return fail(ps.tokenizer.ctx, token.source_range, "time value must be greater than the previous time value", .{});
                    }
                }
                maybe_last_t = t;
                const value_token = try ps.tokenizer.next();
                const value = switch (value_token.tt) {
                    .number => |v| v,
                    else => return ps.tokenizer.failExpected("number", value_token),
                };
                try points.append(.{
                    .t = .{ .value = t, .verbatim = ps.tokenizer.ctx.source.getString(token.source_range) },
                    .value = .{ .value = value, .verbatim = ps.tokenizer.ctx.source.getString(value_token.source_range) },
                });
            },
            else => return ps.tokenizer.failExpected("number or `end`", token),
        }
    }
    const curve_index = ps.curves.items.len;
    try ps.curves.append(.{
        .points = points.toOwnedSlice(),
    });
    return curve_index;
}

fn expectParamType(ps: *ParseState, for_track: bool) !ParamType {
    const type_token = try ps.tokenizer.next();
    const type_name = ps.tokenizer.ctx.source.getString(type_token.source_range);
    if (type_token.tt != .name) {
        return ps.tokenizer.failExpected("param type", type_token);
    }
    const param_type: ParamType = blk: {
        if (std.mem.eql(u8, type_name, "boolean")) break :blk .boolean;
        if (std.mem.eql(u8, type_name, "constant")) break :blk .constant;
        if (std.mem.eql(u8, type_name, "waveform")) break :blk .buffer;
        if (std.mem.eql(u8, type_name, "cob")) break :blk .constant_or_buffer;
        if (std.mem.eql(u8, type_name, "curve")) break :blk .curve;
        for (ps.enums.items) |e| {
            if (std.mem.eql(u8, e.name, type_name)) {
                break :blk ParamType{ .one_of = e };
            }
        }
        return ps.tokenizer.failExpected("param type", type_token);
    };
    if (for_track and (param_type == .buffer or param_type == .constant_or_buffer)) {
        return fail(ps.tokenizer.ctx, type_token.source_range, "track param cannot be cob or waveform", .{});
    }
    return param_type;
}

fn parseParamDeclarations(ps: *ParseState, params: *std.ArrayList(ModuleParam), for_track: bool) !void {
    while (true) {
        const token = try ps.tokenizer.next();
        switch (token.tt) {
            .kw_begin => break,
            .name => {
                const param_name = ps.tokenizer.ctx.source.getString(token.source_range);
                for (reserved_names) |name| {
                    if (std.mem.eql(u8, name, param_name)) {
                        return fail(ps.tokenizer.ctx, token.source_range, "`<` is a reserved name", .{});
                    }
                }
                for (params.items) |param| {
                    if (std.mem.eql(u8, param.name, param_name)) {
                        return fail(ps.tokenizer.ctx, token.source_range, "redeclaration of param `<`", .{});
                    }
                }
                try ps.tokenizer.expectNext(.sym_colon);
                const param_type = try expectParamType(ps, for_track);
                try ps.tokenizer.expectNext(.sym_comma);
                try params.append(.{
                    .name = param_name,
                    .param_type = param_type,
                });
            },
            else => return ps.tokenizer.failExpected("param declaration or `begin`", token),
        }
    }
}

fn defineTrack(ps: *ParseState) !usize {
    var params = std.ArrayList(ModuleParam).init(ps.arena_allocator);
    try parseParamDeclarations(ps, &params, true);

    var notes = std.ArrayList(TrackNote).init(ps.arena_allocator);
    var maybe_last_t: ?f32 = null;
    while (true) {
        const token = try ps.tokenizer.next();
        switch (token.tt) {
            .kw_end => break,
            .number => |t| {
                if (maybe_last_t) |last_t| {
                    if (t <= last_t) {
                        return fail(ps.tokenizer.ctx, token.source_range, "time value must be greater than the previous time value", .{});
                    }
                }
                maybe_last_t = t;
                const loc0 = ps.tokenizer.loc; // FIXME - not perfect - includes whitespace before the `(`
                const args = try parseCallArgs(ps, .global);
                try notes.append(.{
                    .t = .{ .value = t, .verbatim = ps.tokenizer.ctx.source.getString(token.source_range) },
                    .args_source_range = .{ .loc0 = loc0, .loc1 = ps.tokenizer.loc },
                    .args = args,
                });
            },
            else => return ps.tokenizer.failExpected("number or `end`", token),
        }
    }
    const track_index = ps.tracks.items.len;
    try ps.tracks.append(.{
        .params = params.toOwnedSlice(),
        .notes = notes.toOwnedSlice(),
    });
    return track_index;
}

fn defineModule(ps: *ParseState) !usize {
    var params = std.ArrayList(ModuleParam).init(ps.arena_allocator);
    // all modules have an implicitly declared param called "sample_rate"
    try params.append(.{ .name = "sample_rate", .param_type = .constant });
    try parseParamDeclarations(ps, &params, false);

    // parse paint block
    var ps_mod: ParseModuleState = .{
        .params = params.toOwnedSlice(),
        .locals = std.ArrayList(Local).init(ps.arena_allocator),
    };

    const top_scope = try parseStatements(ps, &ps_mod, null);

    const module_index = ps.modules.items.len;
    // FIXME a zig compiler bug prevents me from doing this all in one literal
    // (it compiles but then segfaults at runtime)
    var module: Module = .{
        .builtin_name = null,
        .zig_package_name = null,
        .params = ps_mod.params,
        .info = null,
    };
    module.info = .{
        .scope = top_scope,
        .locals = ps_mod.locals.toOwnedSlice(),
    };
    try ps.modules.append(module);
    return module_index;
}

const ParseError = error{
    Failed,
    OutOfMemory,
};

fn parseCallArgs(ps: *ParseState, pc: ParseContext) ![]const CallArg {
    try ps.tokenizer.expectNext(.sym_left_paren);
    var args = std.ArrayList(CallArg).init(ps.arena_allocator);
    var token = try ps.tokenizer.next();
    while (token.tt != .sym_right_paren) {
        if (args.items.len > 0) {
            if (token.tt != .sym_comma) {
                return ps.tokenizer.failExpected("`,` or `)`", token);
            }
            token = try ps.tokenizer.next();
        }
        if (token.tt != .name) {
            return ps.tokenizer.failExpected("callee param name", token);
        }
        const param_name = ps.tokenizer.ctx.source.getString(token.source_range);
        const equals_token = try ps.tokenizer.next();
        if (equals_token.tt == .sym_equals) {
            try args.append(.{
                .param_name = param_name,
                .param_name_token = token,
                .value = try expectExpression(ps, pc),
            });
            token = try ps.tokenizer.next();
        } else {
            switch (pc) {
                .module => |pcm| {
                    // shorthand param passing: `val` expands to `val=val`
                    const subexpr = try createExprWithSourceRange(ps, token.source_range, resolveName(ps, pc, token));
                    try args.append(.{
                        .param_name = param_name,
                        .param_name_token = token,
                        .value = subexpr,
                    });
                    token = equals_token;
                },
                else => {},
            }
        }
    }
    return args.toOwnedSlice();
}

fn parseTrackCall(ps: *ParseState, pcm: ParseContextModule) ParseError!TrackCall {
    const track_expr = try expectExpression(ps, .{ .module = pcm });
    try ps.tokenizer.expectNext(.sym_comma);
    const speed_expr = try expectExpression(ps, .{ .module = pcm });
    try ps.tokenizer.expectNext(.kw_begin);
    const inner_scope = try parseStatements(ps, pcm.ps_mod, pcm.scope);
    return TrackCall{
        .track_expr = track_expr,
        .speed = speed_expr,
        .scope = inner_scope,
    };
}

fn parseDelay(ps: *ParseState, pcm: ParseContextModule) ParseError!Delay {
    // constant number for the number of delay samples (this is a limitation of my current delay implementation)
    const num_samples = blk: {
        const token = try ps.tokenizer.next();
        if (token.tt != .number) {
            return ps.tokenizer.failExpected("number", token);
        }
        const s = ps.tokenizer.ctx.source.getString(token.source_range);
        const n = std.fmt.parseInt(usize, s, 10) catch {
            return fail(ps.tokenizer.ctx, token.source_range, "malformatted integer", .{});
        };
        break :blk n;
    };
    // keyword `begin`
    try ps.tokenizer.expectNext(.kw_begin);
    // inner statements
    const inner_scope = try parseStatements(ps, pcm.ps_mod, pcm.scope);
    return Delay{
        .num_samples = num_samples,
        .scope = inner_scope,
    };
}

fn createExprWithSourceRange(ps: *ParseState, source_range: SourceRange, inner: ExpressionInner) !*const Expression {
    const expr = try ps.arena_allocator.create(Expression);
    expr.* = .{
        .source_range = source_range,
        .inner = inner,
    };
    return expr;
}

fn createExpr(ps: *ParseState, loc0: SourceLocation, inner: ExpressionInner) !*const Expression {
    // you pass the location of the start of the expression. this function will use the tokenizer's
    // current location to set the expression's end location
    return createExprWithSourceRange(ps, .{ .loc0 = loc0, .loc1 = ps.tokenizer.loc }, inner);
}

fn resolveName(ps: *ParseState, pc: ParseContext, token: Token) ExpressionInner {
    // is it a local? walk up the scopes
    switch (pc) {
        .global => {},
        .module => |pcm| {
            const name = ps.tokenizer.ctx.source.getString(token.source_range);
            var maybe_s: ?*const Scope = pcm.scope;
            while (maybe_s) |sc| : (maybe_s = sc.parent) {
                // loop through declarations in reverse order, because
                // redeclaring the same name (shadowing in the same scope) is
                // allowed
                var i = sc.statements.items.len;
                while (i > 0) {
                    i -= 1;
                    switch (sc.statements.items[i]) {
                        .let_assignment => |x| {
                            const local = pcm.ps_mod.locals.items[x.local_index];
                            if (std.mem.eql(u8, local.name, name)) {
                                return .{ .local = x.local_index };
                            }
                        },
                        else => {},
                    }
                }
            }
        },
    }
    // if it's not a local, it's a name that will be resolved during codegen
    // (i.e. a param or a global)
    return .{ .name = token };
}

const BinaryOperator = struct {
    symbol: TokenType,
    priority: usize,
    op: BinArithOp,
};

const binary_operators = [_]BinaryOperator{
    .{ .symbol = .sym_plus, .priority = 1, .op = .add },
    .{ .symbol = .sym_minus, .priority = 1, .op = .sub },
    .{ .symbol = .sym_asterisk, .priority = 2, .op = .mul },
    .{ .symbol = .sym_slash, .priority = 2, .op = .div },
};

fn expectExpression(ps: *ParseState, pc: ParseContext) ParseError!*const Expression {
    return expectExpression2(ps, pc, 0);
}

fn expectExpression2(ps: *ParseState, pc: ParseContext, priority: usize) ParseError!*const Expression {
    var negate = false;
    if ((try ps.tokenizer.peek()).tt == .sym_minus) {
        _ = try ps.tokenizer.next(); // skip the peeked token
        negate = true;
    }

    var a = try expectTerm(ps, pc);
    const loc0 = a.source_range.loc0;

    if ((try ps.tokenizer.peek()).tt == .sym_left_paren) {
        switch (pc) {
            .module => |pcm| {
                const args = try parseCallArgs(ps, .{ .module = pcm });
                a = try createExpr(ps, loc0, .{ .call = .{ .field_expr = a, .args = args } });
            },
            else => return fail(ps.tokenizer.ctx, a.source_range, "not a function", .{}),
        }
    }

    if (negate) {
        a = try createExpr(ps, loc0, .{ .un_arith = .{ .op = .neg, .a = a } });
    }

    while (true) {
        const token = try ps.tokenizer.peek();
        for (binary_operators) |bo| {
            const T = std.meta.TagType(TokenType);
            if (@as(T, token.tt) == @as(T, bo.symbol) and priority < bo.priority) {
                _ = try ps.tokenizer.next(); // skip the peeked token
                const b = try expectExpression2(ps, pc, bo.priority);
                a = try createExpr(ps, loc0, .{ .bin_arith = .{ .op = bo.op, .a = a, .b = b } });
                break;
            }
        } else {
            break;
        }
    }

    return a;
}

fn parseUnaryFunction(ps: *ParseState, pc: ParseContext, loc0: SourceLocation, op: UnArithOp) !*const Expression {
    try ps.tokenizer.expectNext(.sym_left_paren);
    const a = try expectExpression(ps, pc);
    try ps.tokenizer.expectNext(.sym_right_paren);
    return try createExpr(ps, loc0, .{ .un_arith = .{ .op = op, .a = a } });
}

fn parseBinaryFunction(ps: *ParseState, pc: ParseContext, loc0: SourceLocation, op: BinArithOp) !*const Expression {
    try ps.tokenizer.expectNext(.sym_left_paren);
    const a = try expectExpression(ps, pc);
    try ps.tokenizer.expectNext(.sym_comma);
    const b = try expectExpression(ps, pc);
    try ps.tokenizer.expectNext(.sym_right_paren);
    return try createExpr(ps, loc0, .{ .bin_arith = .{ .op = op, .a = a, .b = b } });
}

fn expectTerm(ps: *ParseState, pc: ParseContext) ParseError!*const Expression {
    const token = try ps.tokenizer.next();
    const loc0 = token.source_range.loc0;

    switch (token.tt) {
        .sym_left_paren => {
            const a = try expectExpression(ps, pc);
            try ps.tokenizer.expectNext(.sym_right_paren);
            return a;
        },
        .kw_defmodule => {
            const module_index = try defineModule(ps);
            return try createExpr(ps, loc0, .{ .literal_module = module_index });
        },
        .kw_defcurve => {
            const curve_index = try defineCurve(ps);
            return try createExpr(ps, loc0, .{ .literal_curve = curve_index });
        },
        .kw_deftrack => {
            const track_index = try defineTrack(ps);
            return try createExpr(ps, loc0, .{ .literal_track = track_index });
        },
        .kw_from => {
            switch (pc) {
                .module => |pcm| {
                    const track_call = try parseTrackCall(ps, pcm);
                    return try createExpr(ps, loc0, .{ .track_call = track_call });
                },
                else => return fail(ps.tokenizer.ctx, token.source_range, "cannot call track outside of module context", .{}),
            }
        },
        .name => {
            const s = ps.tokenizer.ctx.source.getString(token.source_range);
            // this list of builtins corresponds to the `reserved_names` list
            if (std.mem.eql(u8, s, "abs")) {
                return parseUnaryFunction(ps, pc, loc0, .abs);
            } else if (std.mem.eql(u8, s, "cos")) {
                return parseUnaryFunction(ps, pc, loc0, .cos);
            } else if (std.mem.eql(u8, s, "max")) {
                return parseBinaryFunction(ps, pc, loc0, .max);
            } else if (std.mem.eql(u8, s, "min")) {
                return parseBinaryFunction(ps, pc, loc0, .min);
            } else if (std.mem.eql(u8, s, "pi")) {
                return try createExpr(ps, loc0, .{ .literal_number = .{ .value = std.math.pi, .verbatim = "std.math.pi" } });
            } else if (std.mem.eql(u8, s, "pow")) {
                return parseBinaryFunction(ps, pc, loc0, .pow);
            } else if (std.mem.eql(u8, s, "sin")) {
                return parseUnaryFunction(ps, pc, loc0, .sin);
            } else if (std.mem.eql(u8, s, "sqrt")) {
                return parseUnaryFunction(ps, pc, loc0, .sqrt);
            }
            return try createExpr(ps, loc0, resolveName(ps, pc, token));
        },
        .kw_false => {
            return try createExpr(ps, loc0, .{ .literal_boolean = false });
        },
        .kw_true => {
            return try createExpr(ps, loc0, .{ .literal_boolean = true });
        },
        .number => |n| {
            return try createExpr(ps, loc0, .{
                .literal_number = .{
                    .value = n,
                    .verbatim = ps.tokenizer.ctx.source.getString(token.source_range),
                },
            });
        },
        .enum_value => {
            const s = ps.tokenizer.ctx.source.getString(token.source_range);
            const peeked_token = try ps.tokenizer.peek();
            if (peeked_token.tt == .sym_left_paren) {
                _ = try ps.tokenizer.next();
                const payload = try expectExpression(ps, pc);
                try ps.tokenizer.expectNext(.sym_right_paren);

                const enum_literal: EnumLiteral = .{ .label = s, .payload = payload };
                return try createExpr(ps, loc0, .{ .literal_enum_value = enum_literal });
            } else {
                const enum_literal: EnumLiteral = .{ .label = s, .payload = null };
                return try createExprWithSourceRange(ps, token.source_range, .{ .literal_enum_value = enum_literal });
            }
        },
        .kw_delay => {
            switch (pc) {
                .module => |pcm| {
                    const delay = try parseDelay(ps, pcm);
                    return try createExpr(ps, loc0, .{ .delay = delay });
                },
                else => return fail(ps.tokenizer.ctx, token.source_range, "cannot use delay outside of module context", .{}),
            }
        },
        .kw_feedback => {
            switch (pc) {
                .module => |pcm| return try createExpr(ps, loc0, .feedback),
                else => return fail(ps.tokenizer.ctx, token.source_range, "cannot use feedback outside of module context", .{}),
            }
        },
        else => return ps.tokenizer.failExpected("expression", token),
    }
}

fn parseLocalDecl(ps: *ParseState, ps_mod: *ParseModuleState, scope: *Scope, name_token: Token) !void {
    const name = ps.tokenizer.ctx.source.getString(name_token.source_range);
    try ps.tokenizer.expectNext(.sym_equals);
    for (reserved_names) |reserved_name| {
        if (std.mem.eql(u8, name, reserved_name)) {
            return fail(ps.tokenizer.ctx, name_token.source_range, "`<` is a reserved name", .{});
        }
    }
    // note: locals are allowed to shadow globals, params, and even previous locals
    const expr = try expectExpression(ps, .{ .module = .{ .ps_mod = ps_mod, .scope = scope } });
    const local_index = ps_mod.locals.items.len;
    try ps_mod.locals.append(.{
        .name = name,
    });
    try scope.statements.append(.{
        .let_assignment = .{
            .local_index = local_index,
            .expression = expr,
        },
    });
}

fn parseGlobalDecl(ps: *ParseState, name_token: Token) !void {
    const name = ps.tokenizer.ctx.source.getString(name_token.source_range);
    try ps.tokenizer.expectNext(.sym_equals);
    for (reserved_names) |reserved_name| {
        if (std.mem.eql(u8, name, reserved_name)) {
            return fail(ps.tokenizer.ctx, name_token.source_range, "`<` is a reserved name", .{});
        }
    }
    // globals are different from locals in that they are define-anywhere, where shadowing doesn't make sense
    for (ps.globals.items) |global| {
        if (std.mem.eql(u8, name, global.name)) {
            return fail(ps.tokenizer.ctx, name_token.source_range, "redeclaration of global `<`", .{});
        }
    }
    const expr = try expectExpression(ps, .global);
    try ps.globals.append(.{
        .name = name,
        .value = expr,
    });
}

fn parseStatements(ps: *ParseState, ps_mod: *ParseModuleState, parent_scope: ?*const Scope) !*Scope {
    var scope = try ps.arena_allocator.create(Scope);
    scope.* = .{
        .parent = parent_scope,
        .statements = std.ArrayList(Statement).init(ps.arena_allocator),
    };
    const pc: ParseContext = .{
        .module = .{ .ps_mod = ps_mod, .scope = scope },
    };
    while (true) {
        const token = try ps.tokenizer.next();
        switch (token.tt) {
            .kw_end => break,
            .name => {
                try parseLocalDecl(ps, ps_mod, scope, token);
            },
            .kw_out => {
                const expr = try expectExpression(ps, pc);
                try scope.statements.append(.{ .output = expr });
            },
            .kw_feedback => {
                const expr = try expectExpression(ps, pc);
                try scope.statements.append(.{ .feedback = expr });
            },
            else => return ps.tokenizer.failExpected("local declaration, `out`, `feedback` or `end`", token),
        }
    }
    return scope;
}

pub const ParseResult = struct {
    arena: std.heap.ArenaAllocator,
    globals: []const Global,
    curves: []const Curve,
    tracks: []const Track,
    modules: []const Module,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub fn parse(
    ctx: Context,
    inner_allocator: *std.mem.Allocator,
    dump_parse_out: ?std.io.StreamSource.Writer,
) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    var ps: ParseState = .{
        .arena_allocator = &arena.allocator,
        .tokenizer = Tokenizer.init(ctx),
        .globals = std.ArrayList(Global).init(&arena.allocator),
        .enums = std.ArrayList(BuiltinEnum).init(&arena.allocator),
        .curves = std.ArrayList(Curve).init(&arena.allocator),
        .tracks = std.ArrayList(Track).init(&arena.allocator),
        .modules = std.ArrayList(Module).init(&arena.allocator),
    };

    // add builtins
    for (ctx.builtin_packages) |pkg| {
        try ps.enums.appendSlice(pkg.enums);
        for (pkg.builtins) |builtin| {
            const module_index = ps.modules.items.len;
            try ps.modules.append(.{
                .builtin_name = builtin.name,
                .zig_package_name = pkg.zig_package_name,
                .params = builtin.params,
                .info = null,
            });
            // add a global declaration for this builtin. hopefully this never comes up in a
            // compile error, because this source range is bogus
            const sr: SourceRange = .{
                .loc0 = .{ .line = 0, .index = 0 },
                .loc1 = .{ .line = 0, .index = 0 },
            };
            try ps.globals.append(.{
                .name = builtin.name,
                .value = try createExprWithSourceRange(&ps, sr, .{ .literal_module = module_index }),
            });
        }
    }

    // parse the file
    while (true) {
        const token = try ps.tokenizer.next();
        switch (token.tt) {
            .end_of_file => break,
            .name => try parseGlobalDecl(&ps, token),
            else => return ps.tokenizer.failExpected("declaration or end of file", token),
        }
    }

    const modules = ps.modules.toOwnedSlice();

    // diagnostic print
    if (dump_parse_out) |out| {
        for (modules) |module, module_index| {
            parsePrintModule(out, ctx.source, modules, module_index, module) catch |err| std.debug.warn("parsePrintModule failed: {}\n", .{err});
        }
    }

    return ParseResult{
        .arena = arena,
        .globals = ps.globals.toOwnedSlice(),
        .curves = ps.curves.toOwnedSlice(),
        .tracks = ps.tracks.toOwnedSlice(),
        .modules = modules,
    };
}
