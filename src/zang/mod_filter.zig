// filter implementation ripped from farbrausch's v2 (public domain)
// https://github.com/farbrausch/fr_public/blob/master/v2/LICENSE.txt
// https://github.com/farbrausch/fr_public/blob/master/v2/synth_core.cpp

const std = @import("std");

const Impulse = @import("note_span.zig").Impulse;

const fcdcoffset: f32 = 3.814697265625e-6; // 2^-18

pub const FilterType = enum{
    Bypass,
    LowPass,
    BandPass,
    HighPass,
    Notch,
    AllPass,
};

// convert a frequency into a cutoff value so it can be used with the filter
pub fn cutoffFromFrequency(frequency: f32, sample_rate: f32) f32 {
    var v: f32 = undefined;
    v = 2.0 * (1.0 - std.math.cos(std.math.pi * frequency / sample_rate));
    v = std.math.max(0.0, std.math.min(1.0, v));
    v = std.math.sqrt(v);
    return v;
}

pub const Filter = struct{
    filterType: FilterType,
    l: f32,
    b: f32,
    cutoff: f32, // 0-1
    resonance: f32, // 0-1

    pub fn init(filterType: FilterType, cutoff: f32, resonance: f32) Filter {
        return Filter{
            .filterType = filterType,
            .l = 0.0,
            .b = 0.0,
            .cutoff = cutoff,
            .resonance = resonance,
        };
    }

    // FIXME - make this work with Triggerable
    pub fn paint(self: *Filter, buf: []f32, input: []const f32) void {
        std.debug.assert(buf.len == input.len);

        var l_mul: f32 = 0.0;
        var b_mul: f32 = 0.0;
        var h_mul: f32 = 0.0;

        switch (self.filterType) {
            .Bypass => {
                std.mem.copy(f32, buf, input);
                return;
            },
            .LowPass => {
                l_mul = 1.0;
            },
            .BandPass => {
                b_mul = 1.0;
            },
            .HighPass => {
                h_mul = 1.0;
            },
            .Notch => {
                l_mul = 1.0;
                h_mul = 1.0;
            },
            .AllPass => {
                l_mul = 1.0;
                b_mul = 1.0;
                h_mul = 1.0;
            },
        }

        var i: usize = 0;

        const cutoff = std.math.max(0.0, std.math.min(1.0, self.cutoff));
        const res = 1.0 - std.math.max(0.0, std.math.min(1.0, self.resonance));

        var l = self.l;
        var b = self.b;
        var h: f32 = undefined;

        while (i < buf.len) : (i += 1) {
            // run 2x oversampled step

            // the filters get slightly biased inputs to avoid the state variables
            // getting too close to 0 for prolonged periods of time (which would
            // cause denormals to appear)
            const in = input[i] + fcdcoffset;

            // step 1
            l += cutoff * b - fcdcoffset; // undo bias here (1 sample delay)
            b += cutoff * (in - b * res - l);

            // step 2
            l += cutoff * b;
            h = in - b * res - l;
            b += cutoff * h;

            buf[i] += l * l_mul + b * b_mul + h * h_mul;
        }

        self.l = l;
        self.b = b;
    }

    pub fn paintControlledCutoff(
        self: *Filter,
        sample_rate: f32,
        buf: []f32,
        input: []const f32,
        input_cutoff: []const f32,
    ) void {
        std.debug.assert(buf.len == input.len);

        var l_mul: f32 = 0.0;
        var b_mul: f32 = 0.0;
        var h_mul: f32 = 0.0;

        switch (self.filterType) {
            .Bypass => {
                std.mem.copy(f32, buf, input);
                return;
            },
            .LowPass => {
                l_mul = 1.0;
            },
            .BandPass => {
                b_mul = 1.0;
            },
            .HighPass => {
                h_mul = 1.0;
            },
            .Notch => {
                l_mul = 1.0;
                h_mul = 1.0;
            },
            .AllPass => {
                l_mul = 1.0;
                b_mul = 1.0;
                h_mul = 1.0;
            },
        }

        var i: usize = 0;

        const res = 1.0 - std.math.max(0.0, std.math.min(1.0, self.resonance));

        var l = self.l;
        var b = self.b;
        var h: f32 = undefined;

        while (i < buf.len) : (i += 1) {
            const cutoff = std.math.max(0.0, std.math.min(1.0, input_cutoff[i]));

            // run 2x oversampled step

            // the filters get slightly biased inputs to avoid the state variables
            // getting too close to 0 for prolonged periods of time (which would
            // cause denormals to appear)
            const in = input[i] + fcdcoffset;

            // step 1
            l += cutoff * b - fcdcoffset; // undo bias here (1 sample delay)
            b += cutoff * (in - b * res - l);

            // step 2
            l += cutoff * b;
            h = in - b * res - l;
            b += cutoff * h;

            buf[i] += l * l_mul + b * b_mul + h * h_mul;
        }

        self.l = l;
        self.b = b;

        if (buf.len > 0) {
            self.cutoff = input_cutoff[buf.len - 1];
        }
    }

    // TODO - allow resonance to be controlled
};