const builtins = @import("zangscript/builtins.zig");
pub const BuiltinEnum = builtins.BuiltinEnum;
pub const BuiltinModule = builtins.BuiltinModule;
pub const BuiltinPackage = builtins.BuiltinPackage;
pub const getBuiltinModule = builtins.getBuiltinModule;
pub const zang_builtin_package = builtins.zang_builtin_package;

const parse_ = @import("zangscript/parse.zig");
pub const ModuleParam = parse_.ModuleParam;

const compile_ = @import("zangscript/compile.zig");
pub const CompileOptions = compile_.CompileOptions;
pub const CompiledScript = compile_.CompiledScript;
pub const compile = compile_.compile;

const codegen_zig = @import("zangscript/codegen_zig.zig");
pub const generateZig = codegen_zig.generateZig;

const runtime = @import("zangscript/runtime.zig");
pub const Value = runtime.Value;
pub const ModuleBase = runtime.ModuleBase;
pub const initModule = runtime.initModule;
