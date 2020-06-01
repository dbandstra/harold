const std = @import("std");
const zangscript = @import("zangscript");

pub fn dumpBuiltins(out: std.io.StreamSource.OutStream, builtin_packages: []const zangscript.BuiltinPackage) !void {
    for (builtin_packages) |pkg| {
        try out.print("package \"{}\" imported from \"{}\"\n", .{ pkg.zig_package_name, pkg.zig_import_path });
        for (pkg.builtins) |mod| {
            try out.print("    {} ({} outputs, {} temps)\n", .{ mod.name, mod.num_outputs, mod.num_temps });
            for (mod.params) |param| {
                const type_name: []const u8 = switch (param.param_type) {
                    .boolean => "boolean",
                    .constant => "constant",
                    .buffer => "buffer",
                    .constant_or_buffer => "cob",
                    .curve => "curve",
                    .one_of => "one_of", // TODO dump in detail
                };
                try out.print("        {}: {}\n", .{ param.name, type_name });
            }
        }
        // TODO dump pkg.enums
    }
}
