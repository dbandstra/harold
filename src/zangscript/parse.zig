const std = @import("std");
const Source = @import("tokenize.zig").Source;
const SourceLocation = @import("tokenize.zig").SourceLocation;
const SourceRange = @import("tokenize.zig").SourceRange;
const Token = @import("tokenize.zig").Token;
const TokenType = @import("tokenize.zig").TokenType;
const Tokenizer = @import("tokenize.zig").Tokenizer;
const fail = @import("fail.zig").fail;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const parsePrintModule = @import("parse_print.zig").parsePrintModule;

pub const ParamTypeEnum = struct {
    zig_name: []const u8,
    values: []const []const u8,
};

pub const ParamType = union(enum) {
    boolean,
    buffer,
    constant,
    constant_or_buffer,

    // currently only builtin modules can define enum params
    one_of: ParamTypeEnum,
};

pub const ModuleParam = struct {
    name: []const u8,
    param_type: ParamType,
};

pub const Field = struct {
    type_token: Token,
    resolved_module_index: usize,
};

pub const ParsedModuleInfo = struct {
    scope: *Scope,
    fields: []const Field,
    locals: []const Local,
};

pub const Module = struct {
    name: []const u8,
    params: []const ModuleParam,
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
    field_index: usize, // index of the field in the "self" module
    args: []const CallArg,
};

pub const Delay = struct {
    num_samples: usize,
    scope: *Scope,
};

pub const BinArithOp = enum {
    add,
    mul,
    pow,
};

pub const BinArith = struct {
    op: BinArithOp,
    a: *const Expression,
    b: *const Expression,
};

pub const Local = struct {
    name: []const u8,
};

pub const ExpressionInner = union(enum) {
    call: Call,
    delay: Delay,
    literal_boolean: bool,
    literal_number: f32,
    literal_enum_value: []const u8,
    self_param: usize,
    negate: *const Expression,
    bin_arith: BinArith,
    local: usize, // index into flat `locals` array
    feedback, // only allowed within `delay` expressions
};

pub const Expression = struct {
    source_range: SourceRange,
    inner: ExpressionInner,
};

pub const LetAssignment = struct {
    local_index: usize,
    expression: *const Expression,
};

pub const Statement = union(enum) {
    let_assignment: LetAssignment,
    output: *const Expression,
    feedback: *const Expression,
};

const UnresolvedModuleInfo = struct {
    scope: *Scope,
    fields: []const UnresolvedField,
    locals: []const Local,
};

const UnresolvedField = struct {
    type_token: Token,
};

const ParseState = struct {
    arena_allocator: *std.mem.Allocator,
    tokenizer: Tokenizer,
    modules: std.ArrayList(Module),
    unresolved_infos: std.ArrayList(?UnresolvedModuleInfo), // null for builtins
};

const ParseModuleState = struct {
    params: []const ModuleParam,
    fields: std.ArrayList(UnresolvedField),
    locals: std.ArrayList(Local),
};

fn expectParamType(ps: *ParseState) !ParamType {
    const type_token = try ps.tokenizer.expectIdentifier("param type");
    const type_name = ps.tokenizer.source.getString(type_token.source_range);
    if (std.mem.eql(u8, type_name, "boolean")) {
        return .boolean;
    }
    if (std.mem.eql(u8, type_name, "constant")) {
        return .constant;
    }
    if (std.mem.eql(u8, type_name, "waveform")) {
        return .buffer;
    }
    if (std.mem.eql(u8, type_name, "cob")) {
        return .constant_or_buffer;
    }
    return ps.tokenizer.failExpected("param_type", type_token.source_range);
}

fn defineModule(ps: *ParseState) !void {
    const module_name_token = try ps.tokenizer.expectIdentifier("module name");
    const module_name = ps.tokenizer.source.getString(module_name_token.source_range);
    if (module_name[0] < 'A' or module_name[0] > 'Z') {
        return fail(ps.tokenizer.source, module_name_token.source_range, "module name must start with a capital letter", .{});
    }
    _ = try ps.tokenizer.expectOneOf(&[_]TokenType{.sym_colon});

    var params = std.ArrayList(ModuleParam).init(ps.arena_allocator);

    while (true) {
        const token = try ps.tokenizer.expectOneOf(&[_]TokenType{ .kw_begin, .identifier });
        switch (token.tt) {
            else => unreachable,
            .kw_begin => break,
            .identifier => {
                // param declaration
                const param_name = ps.tokenizer.source.getString(token.source_range);
                if (param_name[0] < 'a' or param_name[0] > 'z') {
                    return fail(ps.tokenizer.source, token.source_range, "param name must start with a lowercase letter", .{});
                }
                for (params.items) |param| {
                    if (std.mem.eql(u8, param.name, param_name)) {
                        return fail(ps.tokenizer.source, token.source_range, "redeclaration of param `<`", .{});
                    }
                }
                _ = try ps.tokenizer.expectOneOf(&[_]TokenType{.sym_colon});
                const param_type = try expectParamType(ps);
                _ = try ps.tokenizer.expectOneOf(&[_]TokenType{.sym_comma});
                try params.append(.{
                    .name = param_name,
                    .param_type = param_type,
                });
            },
        }
    }

    // parse paint block
    var ps_mod: ParseModuleState = .{
        .params = params.toOwnedSlice(),
        .fields = std.ArrayList(UnresolvedField).init(ps.arena_allocator),
        .locals = std.ArrayList(Local).init(ps.arena_allocator),
    };

    const top_scope = try parseStatements(ps, &ps_mod, null);

    try ps.modules.append(.{
        .name = module_name,
        .zig_package_name = null,
        .params = ps_mod.params,
        .info = null, // this will get filled in later
    });
    try ps.unresolved_infos.append(UnresolvedModuleInfo{
        .scope = top_scope,
        .fields = ps_mod.fields.toOwnedSlice(),
        .locals = ps_mod.locals.toOwnedSlice(),
    });
}

const ParseError = error{
    Failed,
    OutOfMemory,
};

fn parseCall(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope, field_name_token: Token, field_name: []const u8) ParseError!Call {
    // add a field
    const field_index = ps_mod.fields.items.len;
    try ps_mod.fields.append(.{
        .type_token = field_name_token,
    });

    _ = try ps.tokenizer.expectOneOf(&[_]TokenType{.sym_left_paren});
    var args = std.ArrayList(CallArg).init(ps.arena_allocator);
    var first = true;
    var token = try ps.tokenizer.expect("`)` or arg name");
    while (token.tt != .sym_right_paren) {
        if (first) {
            first = false;
        } else {
            if (token.tt == .sym_comma) {
                token = try ps.tokenizer.expect("`)` or arg name");
            } else {
                return ps.tokenizer.failExpected("`,` or `)`", token.source_range);
            }
        }
        switch (token.tt) {
            .identifier => {
                const identifier = ps.tokenizer.source.getString(token.source_range);
                const equals_token = try ps.tokenizer.expect("`=`, `,` or `)`");
                if (equals_token.tt == .sym_equals) {
                    const subexpr = try expectExpression(ps, ps_mod, scope);
                    try args.append(.{
                        .param_name = identifier,
                        .param_name_token = token,
                        .value = subexpr,
                    });
                    token = try ps.tokenizer.expect("`)` or arg name");
                } else {
                    // shorthand param passing: `val` expands to `val=val`
                    const inner = parseLocalOrParam(ps_mod, scope, identifier) orelse
                        return fail(ps.tokenizer.source, token.source_range, "no param or local called `<`", .{});
                    const loc0 = token.source_range.loc0;
                    const subexpr = try createExpr(ps, loc0, inner);
                    try args.append(.{
                        .param_name = identifier,
                        .param_name_token = token,
                        .value = subexpr,
                    });
                    token = equals_token;
                }
            },
            else => {
                return ps.tokenizer.failExpected("`)` or arg name", token.source_range);
            },
        }
    }
    return Call{
        .field_index = field_index,
        .args = args.toOwnedSlice(),
    };
}

fn parseDelay(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope) ParseError!Delay {
    // constant number for the number of delay samples (this is a limitation of my current delay implementation)
    const num_samples = blk: {
        const token = try ps.tokenizer.expectOneOf(&[_]TokenType{.number});
        const s = ps.tokenizer.source.getString(token.source_range);
        const n = std.fmt.parseInt(usize, s, 10) catch {
            return fail(ps.tokenizer.source, token.source_range, "malformatted integer", .{});
        };
        break :blk n;
    };
    // keyword `begin`
    _ = try ps.tokenizer.expectOneOf(&[_]TokenType{.kw_begin});
    // inner statements
    const inner_scope = try parseStatements(ps, ps_mod, scope);
    return Delay{
        .num_samples = num_samples,
        .scope = inner_scope,
    };
}

fn createExpr(ps: *ParseState, loc0: SourceLocation, inner: ExpressionInner) !*const Expression {
    // you pass the location of the start of the expression. this function will use the tokenizer's
    // current location to set the expression's end location
    const expr = try ps.arena_allocator.create(Expression);
    expr.* = .{
        .source_range = .{ .loc0 = loc0, .loc1 = ps.tokenizer.loc },
        .inner = inner,
    };
    return expr;
}

fn parseLocalOrParam(ps_mod: *ParseModuleState, scope: *const Scope, name: []const u8) ?ExpressionInner {
    const maybe_local_index = blk: {
        var maybe_s: ?*const Scope = scope;
        while (maybe_s) |sc| : (maybe_s = sc.parent) {
            for (sc.statements.items) |statement| {
                switch (statement) {
                    .let_assignment => |x| {
                        const local = ps_mod.locals.items[x.local_index];
                        if (std.mem.eql(u8, local.name, name)) {
                            break :blk x.local_index;
                        }
                    },
                    else => {},
                }
            }
        }
        break :blk null;
    };
    if (maybe_local_index) |local_index| {
        return ExpressionInner{ .local = local_index };
    }
    const maybe_param_index = for (ps_mod.params) |param, i| {
        if (std.mem.eql(u8, param.name, name)) {
            break i;
        }
    } else null;
    if (maybe_param_index) |param_index| {
        return ExpressionInner{ .self_param = param_index };
    }
    return null;
}

const BinaryOperator = struct {
    symbol: TokenType,
    priority: usize,
    op: BinArithOp,
};

const binary_operators = [_]BinaryOperator{
    .{ .symbol = .sym_plus, .priority = 1, .op = .add },
    .{ .symbol = .sym_asterisk, .priority = 2, .op = .mul },
    // note: exponentiation operator is not associative, unlike add and mul.
    // maybe i should make it an error to type `x**y**z` without putting one of
    // the pairs in parentheses.
    .{ .symbol = .sym_dbl_asterisk, .priority = 3, .op = .pow },
};

fn expectExpression(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope) ParseError!*const Expression {
    return expectExpression2(ps, ps_mod, scope, 0);
}

fn expectExpression2(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope, priority: usize) ParseError!*const Expression {
    var negate = false;
    const peeked_token = try ps.tokenizer.peek();
    if (if (peeked_token) |token| token.tt == .sym_minus else false) {
        _ = try ps.tokenizer.next(); // skip the peeked token
        negate = true;
    }

    var a = try expectTerm(ps, ps_mod, scope);
    const loc0 = a.source_range.loc0;

    if (negate) {
        a = try createExpr(ps, loc0, .{ .negate = a });
    }

    while (try ps.tokenizer.peek()) |token| {
        for (binary_operators) |bo| {
            if (token.tt == bo.symbol and priority <= bo.priority) {
                _ = try ps.tokenizer.next(); // skip the peeked token
                const b = try expectExpression2(ps, ps_mod, scope, bo.priority);
                a = try createExpr(ps, loc0, .{ .bin_arith = .{ .op = bo.op, .a = a, .b = b } });
                break;
            }
        } else {
            break;
        }
    }

    return a;
}

fn expectTerm(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope) ParseError!*const Expression {
    const token = try ps.tokenizer.expect("expression");
    const loc0 = token.source_range.loc0;

    switch (token.tt) {
        .sym_left_paren => {
            const a = try expectExpression(ps, ps_mod, scope);
            _ = try ps.tokenizer.expectOneOf(&[_]TokenType{.sym_right_paren});
            return a;
        },
        .identifier => {
            const s = ps.tokenizer.source.getString(token.source_range);
            if (s[0] >= 'A' and s[0] <= 'Z') {
                const call = try parseCall(ps, ps_mod, scope, token, s);
                return try createExpr(ps, loc0, .{ .call = call });
            }
            const inner = parseLocalOrParam(ps_mod, scope, s) orelse
                return fail(ps.tokenizer.source, token.source_range, "no local or param called `<`", .{});
            return try createExpr(ps, loc0, inner);
        },
        .kw_false => {
            return try createExpr(ps, loc0, .{ .literal_boolean = false });
        },
        .kw_true => {
            return try createExpr(ps, loc0, .{ .literal_boolean = true });
        },
        .number => {
            const s = ps.tokenizer.source.getString(token.source_range);
            const n = std.fmt.parseFloat(f32, s) catch {
                return fail(ps.tokenizer.source, token.source_range, "malformatted number", .{});
            };
            return try createExpr(ps, loc0, .{ .literal_number = n });
        },
        .enum_value => {
            const s = ps.tokenizer.source.getString(token.source_range);
            return try createExpr(ps, loc0, .{ .literal_enum_value = s });
        },
        .kw_delay => {
            const delay = try parseDelay(ps, ps_mod, scope);
            return try createExpr(ps, loc0, .{ .delay = delay });
        },
        .kw_feedback => {
            return try createExpr(ps, loc0, .feedback);
        },
        else => {
            return ps.tokenizer.failExpected("expression", token.source_range);
        },
    }
}

fn parseLetAssignment(ps: *ParseState, ps_mod: *ParseModuleState, scope: *Scope) !void {
    const name_token = try ps.tokenizer.expectOneOf(&[_]TokenType{.identifier});
    const name = ps.tokenizer.source.getString(name_token.source_range);
    if (name[0] < 'a' or name[0] > 'z') {
        return fail(ps.tokenizer.source, name_token.source_range, "local name must start with a lowercase letter", .{});
    }
    _ = try ps.tokenizer.expectOneOf(&[_]TokenType{.sym_equals});
    // note: locals are allowed to shadow params
    var maybe_s: ?*const Scope = scope;
    while (maybe_s) |s| : (maybe_s = s.parent) {
        for (s.statements.items) |statement| {
            switch (statement) {
                .let_assignment => |x| {
                    const local = ps_mod.locals.items[x.local_index];
                    if (std.mem.eql(u8, local.name, name)) {
                        return fail(ps.tokenizer.source, name_token.source_range, "redeclaration of local `<`", .{});
                    }
                },
                .output => {},
                .feedback => {},
            }
        }
    }
    const expr = try expectExpression(ps, ps_mod, scope);
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

fn parseStatements(ps: *ParseState, ps_mod: *ParseModuleState, parent_scope: ?*const Scope) !*Scope {
    var scope = try ps.arena_allocator.create(Scope);
    scope.* = .{
        .parent = parent_scope,
        .statements = std.ArrayList(Statement).init(ps.arena_allocator),
    };

    while (try ps.tokenizer.next()) |token| {
        switch (token.tt) {
            .kw_end => break,
            .kw_let => {
                try parseLetAssignment(ps, ps_mod, scope);
            },
            .kw_out => {
                const expr = try expectExpression(ps, ps_mod, scope);
                try scope.statements.append(.{ .output = expr });
            },
            .kw_feedback => {
                const expr = try expectExpression(ps, ps_mod, scope);
                try scope.statements.append(.{ .feedback = expr });
            },
            else => {
                return ps.tokenizer.failExpected("`let`, `out`, `feedback` or `end`", token.source_range);
            },
        }
    }

    return scope;
}

pub const ParseResult = struct {
    arena: std.heap.ArenaAllocator,
    builtin_packages: []const BuiltinPackage,
    modules: []const Module,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub fn parse(
    source: Source,
    builtin_packages: []const BuiltinPackage,
    inner_allocator: *std.mem.Allocator,
) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    // first pass: parse top level, skipping over module implementations
    var ps: ParseState = .{
        .arena_allocator = &arena.allocator,
        .tokenizer = Tokenizer.init(source),
        .modules = std.ArrayList(Module).init(&arena.allocator),
        .unresolved_infos = std.ArrayList(?UnresolvedModuleInfo).init(inner_allocator),
    };
    defer ps.unresolved_infos.deinit();

    // add builtins
    for (builtin_packages) |pkg| {
        for (pkg.builtins) |builtin| {
            try ps.modules.append(.{
                .name = builtin.name,
                .zig_package_name = pkg.zig_package_name,
                .params = builtin.params,
                .info = null,
            });
            try ps.unresolved_infos.append(null);
        }
    }

    // parse the file
    while (try ps.tokenizer.next()) |token| {
        switch (token.tt) {
            .kw_def => try defineModule(&ps),
            else => return ps.tokenizer.failExpected("`def` or end of file", token.source_range),
        }
    }

    const modules = ps.modules.toOwnedSlice();

    // resolve fields, filling in the `info` field for each module
    for (modules) |*module, module_index| {
        const unresolved_info = ps.unresolved_infos.items[module_index] orelse continue;
        var resolved_fields = try arena.allocator.alloc(Field, unresolved_info.fields.len);
        for (unresolved_info.fields) |field, field_index| {
            const field_name = source.getString(field.type_token.source_range);
            const callee_module_index = for (modules) |m, i| {
                if (std.mem.eql(u8, field_name, m.name)) {
                    break i;
                }
            } else {
                return fail(source, field.type_token.source_range, "no module called `<`", .{});
            };
            resolved_fields[field_index] = .{
                .type_token = field.type_token,
                .resolved_module_index = callee_module_index,
            };
        }
        module.info = ParsedModuleInfo{
            .scope = unresolved_info.scope,
            .fields = resolved_fields,
            .locals = unresolved_info.locals,
        };
    }

    // diagnostic print
    for (modules) |module| {
        parsePrintModule(modules, module) catch |err| std.debug.warn("parsePrintModule failed: {}\n", .{err});
    }

    return ParseResult{
        .arena = arena,
        .builtin_packages = builtin_packages,
        .modules = modules,
    };
}