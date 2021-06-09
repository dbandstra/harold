const std = @import("std");

const Trigger = @import("trigger.zig").Trigger;
const Impulse = @import("notes.zig").Impulse;
const Notes = @import("notes.zig").Notes;
const Span = @import("basics.zig").Span;

const span = Span.init(0, 1024);

const ExpectedResult = struct {
    start: usize,
    end: usize,
    params: f32,
    note_id_changed: bool,
};

fn testAll(
    trigger: *Trigger(f32),
    iap: Notes(f32).ImpulsesAndParamses,
    expected: []const ExpectedResult,
) !void {
    var ctr = trigger.counter(span, iap);

    for (expected) |e| {
        const r = trigger.next(&ctr).?;
        try std.testing.expectEqual(e.start, r.span.start);
        try std.testing.expectEqual(e.end, r.span.end);
        try std.testing.expectEqual(e.params, r.params);
        try std.testing.expectEqual(e.note_id_changed, r.note_id_changed);
    }

    try std.testing.expectEqual(
        @as(?Trigger(f32).NewPaintReturnValue, null),
        trigger.next(&ctr),
    );
}

test "Trigger: no notes" {
    var trigger = Trigger(f32).init();

    try testAll(&trigger, .{
        .impulses = &[_]Impulse{},
        .paramses = &[_]f32{},
    }, &[_]ExpectedResult{});
}

test "Trigger: first note at frame=0" {
    var trigger = Trigger(f32).init();

    try testAll(&trigger, .{
        .impulses = &[_]Impulse{
            .{ .frame = 0, .note_id = 1, .event_id = 1 },
        },
        .paramses = &[_]f32{
            440.0,
        },
    }, &[_]ExpectedResult{
        .{ .start = 0, .end = 1024, .params = 440.0, .note_id_changed = true },
    });
}

test "Trigger: first note after frame=0" {
    var trigger = Trigger(f32).init();

    try testAll(&trigger, .{
        .impulses = &[_]Impulse{
            .{ .frame = 500, .note_id = 1, .event_id = 1 },
        },
        .paramses = &[_]f32{
            440.0,
        },
    }, &[_]ExpectedResult{
        .{ .start = 500, .end = 1024, .params = 440.0, .note_id_changed = true },
    });
}

test "Trigger: carryover" {
    var trigger = Trigger(f32).init();

    try testAll(&trigger, .{
        .impulses = &[_]Impulse{
            .{ .frame = 0, .note_id = 1, .event_id = 1 },
            .{ .frame = 200, .note_id = 2, .event_id = 2 },
        },
        .paramses = &[_]f32{
            440.0,
            220.0,
        },
    }, &[_]ExpectedResult{
        .{ .start = 0, .end = 200, .params = 440.0, .note_id_changed = true },
        .{ .start = 200, .end = 1024, .params = 220.0, .note_id_changed = true },
    });

    try testAll(&trigger, .{
        .impulses = &[_]Impulse{
            .{ .frame = 500, .note_id = 3, .event_id = 1 },
            .{ .frame = 600, .note_id = 3, .event_id = 2 }, // same
        },
        .paramses = &[_]f32{
            330.0,
            660.0,
        },
    }, &[_]ExpectedResult{
        .{ .start = 0, .end = 500, .params = 220.0, .note_id_changed = false },
        .{ .start = 500, .end = 600, .params = 330.0, .note_id_changed = true },
        .{ .start = 600, .end = 1024, .params = 660.0, .note_id_changed = false },
    });

    try testAll(&trigger, .{
        .impulses = &[_]Impulse{},
        .paramses = &[_]f32{},
    }, &[_]ExpectedResult{
        .{ .start = 0, .end = 1024, .params = 660.0, .note_id_changed = false },
    });
}

test "Trigger: two notes starting at the same time" {
    var trigger = Trigger(f32).init();

    try testAll(&trigger, .{
        .impulses = &[_]Impulse{
            .{ .frame = 200, .note_id = 1, .event_id = 1 },
            .{ .frame = 200, .note_id = 2, .event_id = 2 },
        },
        .paramses = &[_]f32{
            440.0,
            220.0,
        },
    }, &[_]ExpectedResult{
        .{ .start = 200, .end = 1024, .params = 220.0, .note_id_changed = true },
    });
}
