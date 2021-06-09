const std = @import("std");
const zangscript = @import("zangscript");

// parse a zig file at runtime looking for builtin module definitions
const BuiltinParser = struct {
    arena_allocator: *std.mem.Allocator,
    contents: []const u8,
    tree: *std.zig.ast.Tree,

    fn getToken(self: BuiltinParser, token_index: usize) []const u8 {
        const token_loc = self.tree.token_locs[token_index];
        return self.contents[token_loc.start..token_loc.end];
    }

    fn parseIntLiteral(self: BuiltinParser, var_decl: *const std.zig.ast.Node.VarDecl) ?usize {
        const init_node = var_decl.getInitNode() orelse return null;
        const lit = init_node.castTag(.IntegerLiteral) orelse return null;
        return std.fmt.parseInt(usize, self.getToken(lit.token), 10) catch return null;
    }

    // `one_of` (enums) not supported
    fn parseParamType(self: BuiltinParser, type_expr: *std.zig.ast.Node) ?zangscript.ParamType {
        if (type_expr.castTag(.Identifier)) |identifier| {
            const type_name = self.getToken(identifier.token);
            if (std.mem.eql(u8, type_name, "bool")) {
                return .boolean;
            }
            if (std.mem.eql(u8, type_name, "f32")) {
                return .constant;
            }
        } else if (type_expr.castTag(.SliceType)) |st| {
            if (st.ptr_info.const_token != null and st.ptr_info.allowzero_token == null and st.ptr_info.sentinel == null) {
                if (st.rhs.castTag(.Identifier)) |rhs_identifier| {
                    const type_name = self.getToken(rhs_identifier.token);
                    if (std.mem.eql(u8, type_name, "f32")) {
                        return .buffer;
                    }
                }
            }
        } else if (type_expr.castTag(.Period)) |infix_op| {
            if (infix_op.lhs.castTag(.Identifier)) |lhs_identifier| {
                if (std.mem.eql(u8, self.getToken(lhs_identifier.token), "zang")) {
                    if (infix_op.rhs.castTag(.Identifier)) |rhs_identifier| {
                        if (std.mem.eql(u8, self.getToken(rhs_identifier.token), "ConstantOrBuffer")) {
                            return .constant_or_buffer;
                        }
                    }
                }
            }
        }
        return null;
    }

    fn parseParams(
        self: BuiltinParser,
        stderr: *std.fs.File.Writer,
        var_decl: *const std.zig.ast.Node.VarDecl,
    ) ![]const zangscript.ModuleParam {
        const init_node = var_decl.getInitNode() orelse {
            try stderr.print("expected init node\n", .{});
            return error.Failed;
        };
        const container_decl = init_node.castTag(.ContainerDecl) orelse {
            try stderr.print("expected container decl\n", .{});
            return error.Failed;
        };

        var params = std.ArrayList(zangscript.ModuleParam).init(self.arena_allocator);

        for (container_decl.fieldsAndDeclsConst()) |node_ptr| {
            const field = node_ptr.castTag(.ContainerField) orelse continue;
            const name = self.getToken(field.name_token);
            const type_expr = field.type_expr orelse {
                try stderr.print("expected type expr\n", .{});
                return error.Failed;
            };
            const param_type = self.parseParamType(type_expr) orelse {
                try stderr.print("{s}: unrecognized param type\n", .{name});
                return error.Failed;
            };
            try params.append(.{
                .name = try std.mem.dupe(self.arena_allocator, u8, name),
                .param_type = param_type,
            });
        }

        return params.items;
    }

    fn parseTopLevelDecl(
        self: BuiltinParser,
        stderr: *std.fs.File.Writer,
        var_decl: *std.zig.ast.Node.VarDecl,
    ) !?zangscript.BuiltinModule {
        // TODO check for `pub`, and initial uppercase
        const init_node = var_decl.getInitNode() orelse return null;
        const container_decl = init_node.castTag(.ContainerDecl) orelse return null;

        const name = self.getToken(var_decl.name_token);

        var num_outputs: ?usize = null;
        var num_temps: ?usize = null;
        var params: ?[]const zangscript.ModuleParam = null;

        for (container_decl.fieldsAndDeclsConst()) |node_ptr| {
            const var_decl2 = node_ptr.castTag(.VarDecl) orelse continue;
            const name2 = self.getToken(var_decl2.name_token);
            if (std.mem.eql(u8, name2, "num_outputs")) {
                num_outputs = self.parseIntLiteral(var_decl2) orelse {
                    try stderr.print("num_outputs: expected an integer literal\n", .{});
                    return error.Failed;
                };
            }
            if (std.mem.eql(u8, name2, "num_temps")) {
                num_temps = self.parseIntLiteral(var_decl2) orelse {
                    try stderr.print("num_temps: expected an integer literal\n", .{});
                    return error.Failed;
                };
            }
            if (std.mem.eql(u8, name2, "Params")) {
                params = try self.parseParams(stderr, var_decl2);
            }
        }

        return zangscript.BuiltinModule{
            .name = try std.mem.dupe(self.arena_allocator, u8, name),
            .params = params orelse return null,
            .num_temps = num_temps orelse return null,
            .num_outputs = num_outputs orelse return null,
        };
    }
};

pub fn parseBuiltins(
    arena_allocator: *std.mem.Allocator,
    temp_allocator: *std.mem.Allocator,
    stderr: *std.fs.File.Writer,
    name: []const u8,
    filename: []const u8,
    contents: []const u8,
) !zangscript.BuiltinPackage {
    var builtins = std.ArrayList(zangscript.BuiltinModule).init(arena_allocator);
    var enums = std.ArrayList(zangscript.BuiltinEnum).init(arena_allocator);

    var tree = std.zig.parse(temp_allocator, contents) catch |err| {
        try stderr.print("failed to parse {s}: {}\n", .{ filename, err });
        return error.Failed;
    };
    defer tree.deinit(temp_allocator);

    if (tree.errors.len > 0) {
        try stderr.print("parse error in {s}\n", .{filename});
        for (tree.errors) |err| {
            const token_start = tree.tokens.items(.start)[err.token];
            var line: usize = 1;
            var col: usize = 1;
            for (contents[0..token_start]) |ch| {
                if (ch == '\n') {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
            }
            try stderr.print("(line {}, col {}) ", .{ line, col });
            try tree.renderError(err, stderr);
            try stderr.writeAll("\n");
        }
        return error.Failed;
    }

    var bp: BuiltinParser = .{
        .arena_allocator = arena_allocator,
        .contents = contents,
        .tree = &tree,
    };

    for (tree.rootDecls()) |node_index| {
        if (tree.nodes.items(.tag)[node_index] != .global_var_decl)
            continue;
        const var_decl = tree.globalVarDecl(node_index);
        if (try bp.parseTopLevelDecl(stderr, var_decl)) |builtin| {
            try builtins.append(builtin);
        }
    }

    return zangscript.BuiltinPackage{
        .zig_package_name = name,
        .zig_import_path = filename,
        .builtins = builtins.items,
        .enums = enums.items,
    };
}
