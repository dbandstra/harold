const std = @import("std");
const zang = @import("zang");
const wav = @import("zig-wav");

const example = @import("example_song.zig");

const NUM_SECONDS = 6 * 60 + 25; // how long to render

const bytes_per_sample = switch (example.AUDIO_FORMAT) {
    .signed8 => 1,
    .signed16_lsb => 2,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const allocator = &gpa.allocator;

    var output_arrays = try allocator.create([example.MainModule.num_temps][example.AUDIO_BUFFER_SIZE]f32);
    defer allocator.destroy(output_arrays);

    var temp_arrays = try allocator.create([example.MainModule.num_temps][example.AUDIO_BUFFER_SIZE]f32);
    defer allocator.destroy(temp_arrays);

    var mixbuf = try allocator.create([example.AUDIO_BUFFER_SIZE * bytes_per_sample * example.MainModule.num_outputs]u8);
    defer allocator.destroy(mixbuf);

    var main_module = example.MainModule.init();

    var outputs: [example.MainModule.num_outputs][]f32 = undefined;
    for (outputs) |*output, i|
        output.* = &output_arrays[i];

    var temps: [example.MainModule.num_temps][]f32 = undefined;
    for (temps) |*temp, i|
        temp.* = &temp_arrays[i];

    const file = try std.fs.cwd().createFile("out.wav", .{});
    defer file.close();
    var writer = file.writer();

    try wav.writeHeader(writer, .{
        .num_channels = example.MainModule.num_outputs,
        .sample_rate = example.AUDIO_SAMPLE_RATE,
        .format = switch (example.AUDIO_FORMAT) {
            .signed8 => .unsigned8,
            .signed16_lsb => .signed16_lsb,
        },
    });

    const total = NUM_SECONDS * example.AUDIO_SAMPLE_RATE;
    const num_iterations = (total + example.AUDIO_BUFFER_SIZE - 1) / example.AUDIO_BUFFER_SIZE;

    var progress: std.Progress = .{};
    const progress_node = try progress.start("rendering audio", num_iterations);
    defer progress_node.end();

    var start: usize = 0;
    var bytes_written: usize = 0;
    while (start < total) {
        const len = std.math.min(example.AUDIO_BUFFER_SIZE, total - start);

        const span = zang.Span.init(0, len);

        for (outputs) |*output, i|
            zang.zero(span, output.*);

        main_module.paint(span, outputs, temps);

        for (outputs) |output, i| {
            const m = bytes_per_sample * example.MainModule.num_outputs;
            const out_slice = mixbuf[0 .. len * m];
            zang.mixDown(
                out_slice,
                output[span.start..span.end],
                example.AUDIO_FORMAT,
                example.MainModule.num_outputs,
                i,
                0.25,
            );
            if (example.AUDIO_FORMAT == .signed8) {
                // wav files use unsigned 8-bit, so convert
                for (out_slice) |*byte| {
                    const signed_byte = @bitCast(i8, byte.*);
                    byte.* = @intCast(u8, i16(signed_byte) + 128);
                }
            }
            try writer.writeAll(out_slice);
        }

        start += len;
        bytes_written += len * bytes_per_sample;

        progress_node.completeOne();
    }

    try wav.patchHeader(writer, file.seekableStream(), bytes_written);
}
