const std = @import("std");
const Context = @import("context.zig").Context;
const SourceRange = @import("context.zig").SourceRange;
const BuiltinEnumValue = @import("builtins.zig").BuiltinEnumValue;

fn printSourceRange(writer: anytype, contents: []const u8, source_range: SourceRange) !void {
    try writer.writeAll(contents[source_range.loc0.index..source_range.loc1.index]);
}

fn printErrorMessage(writer: anytype, maybe_source_range: ?SourceRange, contents: []const u8, comptime fmt: []const u8, args: anytype) !void {
    comptime var arg_index: usize = 0;
    inline for (fmt) |ch| {
        if (ch == '%') {
            // source range
            try printSourceRange(writer, contents, args[arg_index]);
            arg_index += 1;
        } else if (ch == '#') {
            // string
            try writer.writeAll(args[arg_index]);
            arg_index += 1;
        } else if (ch == '<') {
            // the maybe_source_range that was passed in
            if (maybe_source_range) |source_range| {
                try printSourceRange(writer, contents, source_range);
            } else {
                try writer.writeByte('?');
            }
        } else if (ch == '|') {
            // list of enum values
            const values: []const BuiltinEnumValue = args[arg_index];
            for (values) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeByte('\'');
                try writer.writeAll(value.label);
                try writer.writeByte('\'');
                switch (value.payload_type) {
                    .none => {},
                    .f32 => try writer.writeAll("(number)"),
                }
            }
            arg_index += 1;
        } else {
            try writer.writeByte(ch);
        }
    }
}

fn printError(ctx: Context, maybe_source_range: ?SourceRange, comptime fmt: []const u8, args: anytype) !void {
    const KNRM = if (ctx.errors_color) "\x1B[0m" else "";
    const KBOLD = if (ctx.errors_color) "\x1B[1m" else "";
    const KRED = if (ctx.errors_color) "\x1B[31m" else "";
    const KYEL = if (ctx.errors_color) "\x1B[33m" else "";
    const KWHITE = if (ctx.errors_color) "\x1B[37m" else "";

    const out = ctx.errors_out;

    const source_range = maybe_source_range orelse {
        // we don't know where in the source file the error occurred
        try out.print("{s}{s}{s}: {s}", .{ KYEL, KBOLD, ctx.source.filename, KWHITE });
        try printErrorMessage(out, null, ctx.source.contents, fmt, args);
        try out.print("{s}\n\n", .{KNRM});
        return;
    };

    // we want to echo the problematic line from the source file.
    // look backward to find the start of the line
    var i: usize = source_range.loc0.index;
    while (i > 0) : (i -= 1) {
        if (ctx.source.contents[i - 1] == '\n') {
            break;
        }
    }
    const start = i;
    // look forward to find the end of the line
    i = source_range.loc0.index;
    while (i < ctx.source.contents.len) : (i += 1) {
        if (ctx.source.contents[i] == '\n' or ctx.source.contents[i] == '\r') {
            break;
        }
    }
    const end = i;

    const line_num = source_range.loc0.line + 1;
    const column_num = source_range.loc0.index - start + 1;

    // print source filename, line number, and column number
    try out.print("{s}{s}{s}:{}:{}: {s}", .{ KYEL, KBOLD, ctx.source.filename, line_num, column_num, KWHITE });

    // print the error message
    try printErrorMessage(out, maybe_source_range, ctx.source.contents, fmt, args);
    try out.print("{s}\n\n", .{KNRM});

    if (source_range.loc0.index == source_range.loc1.index) {
        // if there's no span, it's probably an "expected X, found end of file" error.
        // there's nothing to echo (but we still want to show the line number)
        return;
    }

    // echo the source line
    try out.print("{s}\n", .{ctx.source.contents[start..end]});

    // show arrows pointing at the problematic span
    i = start;
    while (i < source_range.loc0.index) : (i += 1) {
        try out.print(" ", .{});
    }
    try out.print("{s}{s}", .{ KRED, KBOLD });
    while (i < end and i < source_range.loc1.index) : (i += 1) {
        try out.print("^", .{});
    }
    try out.print("{s}\n", .{KNRM});
}

pub fn fail(ctx: Context, maybe_source_range: ?SourceRange, comptime fmt: []const u8, args: anytype) error{Failed} {
    printError(ctx, maybe_source_range, fmt, args) catch {};
    return error.Failed;
}
