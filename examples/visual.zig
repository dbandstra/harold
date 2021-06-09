const std = @import("std");
const fft = @import("common/fft.zig").fft;
const example = @import(@import("build_options").example);
const Recorder = @import("recorder.zig").Recorder;

const fontdata = @embedFile("font.dat");
const fontchar_w = 8;
const fontchar_h = 13;

pub const Screen = struct {
    width: usize,
    height: usize,
    pixels: []u32,
    pitch: usize,
};

// guaranteed to already be clipped to within the screen's bounds
pub const ClipRect = struct { x: usize, y: usize, w: usize, h: usize };
fn clipRect(screen: Screen, x: usize, y: usize, w: usize, h: usize) ?ClipRect {
    if (x >= screen.width or y >= screen.height) return null;
    if (w == 0 or h == 0) return null;
    return ClipRect{
        .x = x,
        .y = y,
        .w = std.math.min(w, screen.width - x),
        .h = std.math.min(h, screen.height - y),
    };
}

fn drawFill(screen: Screen, rect: ClipRect, color: u32) void {
    var i: usize = 0;
    while (i < rect.h) : (i += 1) {
        const start = (rect.y + i) * screen.pitch + rect.x;
        std.mem.set(u32, screen.pixels[start .. start + rect.w], color);
    }
}

fn drawString(screen: Screen, rect: ClipRect, s: []const u8) void {
    const color: u32 = 0xAAAAAAAA;

    var x = rect.x;
    var y = rect.y;
    for (s) |ch| {
        if (ch != '\n' and (ch < 32 or ch >= 128)) {
            continue;
        }
        // wrap long lines
        if (ch == '\n' or x + fontchar_w >= rect.x + rect.w) {
            x = rect.x;
            y += fontchar_h + 1;
            if (ch == '\n') {
                continue;
            }
        }
        if (y >= rect.y + rect.h) {
            break;
        }
        if (x >= rect.x + rect.w) {
            continue;
        }
        const index = @intCast(usize, ch - 32) * fontchar_h;
        var out_index = y * screen.pitch + x;
        var sy: usize = 0;
        const sy_end = std.math.min(fontchar_h, rect.y + rect.h - y);
        while (sy < sy_end) : (sy += 1) {
            const fontrow = fontdata[index + sy];
            var bit: u8 = 1;
            var sx: usize = 0;
            const sx_end = std.math.min(fontchar_w, rect.x + rect.w - x);
            while (sx < sx_end) : (sx += 1) {
                if ((fontrow & bit) != 0) {
                    screen.pixels[out_index + sx] = color;
                }
                bit <<= 1;
            }
            out_index += screen.pitch;
        }
        x += fontchar_w + 1;
    }
}

fn stringWidth(s: []const u8) usize {
    if (s.len == 0) return 0;
    return s.len * (fontchar_w + 1) - 1;
}

fn hueToRgb(p: f32, q: f32, t_: f32) f32 {
    var t = t_;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn hslToRgb(h: f32, s: f32, l: f32) u32 {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;

    if (s == 0.0) {
        r = 1.0;
        g = 1.0;
        b = 1.0;
    } else {
        const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
        const p = 2 * l - q;
        r = hueToRgb(p, q, h + 1.0 / 3.0);
        g = hueToRgb(p, q, h);
        b = hueToRgb(p, q, h - 1.0 / 3.0);
    }

    // kludge
    const sqrt_h = std.math.sqrt(h);
    r *= sqrt_h;
    g *= sqrt_h;
    b *= sqrt_h;

    return @as(u32, 0xFF000000) |
        (@floatToInt(u32, b * 255) << 16) |
        (@floatToInt(u32, g * 255) << 8) |
        (@floatToInt(u32, r * 255));
}

fn scrollBlit(screen: Screen, x: usize, y: usize, w: usize, h: usize, buffer: []const u32, drawindex: usize) void {
    var i: usize = 0;
    while (i < h) : (i += 1) {
        const dest_start = (y + i) * screen.pitch + x;
        const dest = screen.pixels[dest_start .. dest_start + w];

        const src_start = i * w;
        const src = buffer[src_start .. src_start + w];

        std.mem.copy(u32, dest[w - drawindex ..], src[0..drawindex]);
        std.mem.copy(u32, dest[0 .. w - drawindex], src[drawindex..]);
    }
}

fn getFFTValue(f_: f32, in_fft: []const f32, logarithmic: bool) f32 {
    var f = f_;

    if (logarithmic) {
        const exp = 10.0;
        f = (std.math.pow(f32, exp, f) - 1.0) / (exp - 1.0);
    }

    f *= 511.5;
    const f_floor = std.math.floor(f);
    const index0 = @floatToInt(usize, f_floor);
    const index1 = std.math.min(511, index0 + 1);
    const frac = f - f_floor;

    const fft_value0 = in_fft[index0];
    const fft_value1 = in_fft[index1];

    return fft_value0 * (1.0 - frac) + fft_value1 * frac;
}

pub const BlitContext = struct {
    recorder_state: std.meta.TagType(Recorder.State),
};

pub const VTable = struct {
    offset: usize, // offset of `vtable: *const VTable` in instance object
    delFn: fn (self: **const VTable, allocator: *std.mem.Allocator) void,
    plotFn: fn (self: **const VTable, samples: []const f32, mul: f32, logarithmic: bool, sr: f32, oscil_freq: ?[]const f32) bool,
    blitFn: fn (self: **const VTable, screen: Screen, ctx: BlitContext) void,
};

fn makeVTable(comptime T: type) VTable {
    const S = struct {
        const vtable = VTable{
            .offset = blk: {
                inline for (@typeInfo(T).Struct.fields) |field| {
                    if (comptime std.mem.eql(u8, field.name, "vtable")) {
                        break :blk @byteOffsetOf(T, field.name);
                    }
                }
                @compileError("missing vtable field");
            },
            .delFn = delFn,
            .plotFn = plotFn,
            .blitFn = blitFn,
        };
        fn delFn(self: **const VTable, allocator: *std.mem.Allocator) void {
            @intToPtr(*T, @ptrToInt(self) - self.*.offset).del(allocator);
        }
        fn plotFn(self: **const VTable, samples: []const f32, mul: f32, logarithmic: bool, sr: f32, oscil_freq: ?[]const f32) bool {
            if (!@hasDecl(T, "plot")) return false;
            return @intToPtr(*T, @ptrToInt(self) - self.*.offset).plot(samples, mul, logarithmic, sr, oscil_freq);
        }
        fn blitFn(self: **const VTable, screen: Screen, ctx: BlitContext) void {
            @intToPtr(*T, @ptrToInt(self) - self.*.offset).blit(screen, ctx);
        }
    };
    return S.vtable;
}

// area chart where x=frequency and y=amplitude
pub const DrawSpectrum = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    old_y: []u32,
    fft_real: []f32,
    fft_imag: []f32,
    fft_out: []f32,
    logarithmic: bool,
    state: enum { up_to_date, needs_blit, needs_full_reblit },

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawSpectrum {
        var self = try allocator.create(DrawSpectrum);
        errdefer allocator.destroy(self);
        var old_y = try allocator.alloc(u32, width);
        errdefer allocator.free(old_y);
        var fft_real = try allocator.alloc(f32, 1024);
        errdefer allocator.free(fft_real);
        var fft_imag = try allocator.alloc(f32, 1024);
        errdefer allocator.free(fft_imag);
        var fft_out = try allocator.alloc(f32, 512);
        errdefer allocator.free(fft_out);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .old_y = old_y,
            .fft_real = fft_real,
            .fft_imag = fft_imag,
            .fft_out = fft_out,
            .logarithmic = false,
            .state = .needs_full_reblit,
        };
        // old_y doesn't need to be initialized as long as state is .needs_full_reblit
        std.mem.set(f32, self.fft_out, 0.0);
        return self;
    }

    pub fn del(self: *DrawSpectrum, allocator: *std.mem.Allocator) void {
        allocator.free(self.old_y);
        allocator.free(self.fft_real);
        allocator.free(self.fft_imag);
        allocator.free(self.fft_out);
        allocator.destroy(self);
    }

    pub fn plot(self: *DrawSpectrum, samples: []const f32, _mul: f32, logarithmic: bool, _sr: f32, _oscil_freq: ?[]const f32) bool {
        std.debug.assert(samples.len == 1024); // FIXME

        std.mem.copy(f32, self.fft_real, samples);
        std.mem.set(f32, self.fft_imag, 0.0);
        fft(1024, self.fft_real, self.fft_imag);

        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const v = std.math.fabs(self.fft_real[i]) * (1.0 / 1024.0);
            const v2 = std.math.sqrt(v); // kludge for visibility
            self.fft_out[i] = v2;
        }

        self.logarithmic = logarithmic;
        if (self.state == .up_to_date) {
            self.state = .needs_blit;
        }

        return true;
    }

    pub fn blit(self: *DrawSpectrum, screen: Screen, _context: BlitContext) void {
        if (self.state == .up_to_date) return;
        defer self.state = .up_to_date;

        const background_color: u32 = 0x00000000;

        var i: usize = 0;
        while (i < self.width) : (i += 1) {
            const fi = @intToFloat(f32, i) / @intToFloat(f32, self.width - 1);
            const fv = getFFTValue(fi, self.fft_out, self.logarithmic) * @intToFloat(f32, self.height);

            // where the graph will transition from background to foreground color
            var new_y: u32 = undefined;
            // antaliasing between background_color and color
            var transition_color: u32 = undefined;
            var color: u32 = undefined;

            if (fv != fv) {
                // show NaNs as a 1px tall red line
                new_y = @intCast(u32, self.height - 1);
                transition_color = 0xFFFF0000;
                color = 0xFFFF0000;
            } else {
                const value = @floatToInt(u32, std.math.floor(fv));
                const value_clipped = std.math.min(value, self.height - 1);

                new_y = @intCast(u32, self.height - value_clipped);

                // the transition pixel will have a blended color value
                const frac = fv - std.math.floor(fv);
                const co: u32 = @floatToInt(u32, 0x44 * frac);
                transition_color = @as(u32, 0xFF000000) | (co << 16) | (co << 8) | co;
                color = 0xFF444444;
            }

            const sx = self.x + i;
            var sy = self.y;
            if (self.state == .needs_full_reblit) {
                // redraw fully
                while (sy < self.y + new_y) : (sy += 1) {
                    screen.pixels[sy * screen.pitch + sx] = background_color;
                }
                if (sy < self.y + self.height) {
                    screen.pixels[sy * screen.pitch + sx] = transition_color;
                    sy += 1;
                }
                while (sy < self.y + self.height) : (sy += 1) {
                    screen.pixels[sy * screen.pitch + sx] = color;
                }
            } else {
                const old_y = self.old_y[i];
                if (old_y < new_y) {
                    // new_y is lower down. fill in the overlap with background color
                    sy += old_y;
                    while (sy < self.y + new_y) : (sy += 1) {
                        screen.pixels[sy * screen.pitch + sx] = background_color;
                    }
                    if (sy < self.y + self.height) {
                        screen.pixels[sy * screen.pitch + sx] = transition_color;
                        sy += 1;
                    }
                } else if (old_y > new_y) {
                    // new_y is higher up. fill in the overlap with foreground color
                    sy += new_y;
                    if (sy < self.y + self.height) {
                        screen.pixels[sy * screen.pitch + sx] = transition_color;
                        sy += 1;
                    }
                    // add one to cover up the old transition pixel
                    const until = std.math.min(old_y + 1, self.height);
                    while (sy < self.y + until) : (sy += 1) {
                        screen.pixels[sy * screen.pitch + sx] = color;
                    }
                }
            }

            self.old_y[i] = new_y;
        }
    }
};

// scrolling 2d color plot of FFT data
pub const DrawSpectrumFull = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    fft_real: []f32,
    fft_imag: []f32,
    buffer: []u32,
    logarithmic: bool,
    drawindex: usize,

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawSpectrumFull {
        var self = try allocator.create(DrawSpectrumFull);
        errdefer allocator.destroy(self);
        var fft_real = try allocator.alloc(f32, 1024);
        errdefer allocator.free(fft_real);
        var fft_imag = try allocator.alloc(f32, 1024);
        errdefer allocator.free(fft_imag);
        var buffer = try allocator.alloc(u32, width * height);
        errdefer allocator.free(buffer);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .fft_real = fft_real,
            .fft_imag = fft_imag,
            .buffer = buffer,
            .logarithmic = false,
            .drawindex = 0,
        };
        std.mem.set(u32, self.buffer, 0);
        return self;
    }

    pub fn del(self: *DrawSpectrumFull, allocator: *std.mem.Allocator) void {
        allocator.free(self.fft_real);
        allocator.free(self.fft_imag);
        allocator.free(self.buffer);
        allocator.destroy(self);
    }

    pub fn plot(self: *DrawSpectrumFull, samples: []const f32, _mul: f32, logarithmic: bool, _sr: f32, _oscil_freq: ?[]const f32) bool {
        if (self.logarithmic != logarithmic) {
            self.logarithmic = logarithmic;
            std.mem.set(u32, self.buffer, 0.0);
            self.drawindex = 0;
        }

        std.debug.assert(samples.len == 1024); // FIXME

        std.mem.copy(f32, self.fft_real, samples);
        std.mem.set(f32, self.fft_imag, 0.0);
        fft(1024, self.fft_real, self.fft_imag);

        var i: usize = 0;
        while (i < self.height) : (i += 1) {
            const f = @intToFloat(f32, i) / @intToFloat(f32, self.height - 1);
            const fft_value = getFFTValue(f, self.fft_real, logarithmic);

            var color: u32 = undefined;

            if (fft_value != fft_value) {
                // NaN
                color = 0xFFFF0000;
            } else {
                // sqrt is a kludge to make things more visible
                const v = std.math.sqrt(std.math.fabs(fft_value) * (1.0 / 1024.0));
                color = hslToRgb(v, 1.0, 0.5);
            }

            self.buffer[(self.height - 1 - i) * self.width + self.drawindex] = color;
        }

        self.drawindex += 1;
        if (self.drawindex == self.width) {
            self.drawindex = 0;
        }

        return true;
    }

    pub fn blit(self: *DrawSpectrumFull, screen: Screen, _ctx: BlitContext) void {
        scrollBlit(screen, self.x, self.y, self.width, self.height, self.buffer, self.drawindex);
    }
};

// scrolling waveform view
pub const DrawWaveform = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    buffer: []u32,
    drawindex: usize,
    dirty: bool,

    const background_color: u32 = 0x18181818;
    const waveform_color: u32 = 0x44444444;
    const clipped_color: u32 = 0xFFFF0000;
    const center_line_color: u32 = 0x66666666;

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawWaveform {
        var self = try allocator.create(DrawWaveform);
        errdefer allocator.destroy(self);
        var buffer = try allocator.alloc(u32, width * height);
        errdefer allocator.free(buffer);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .buffer = buffer,
            .drawindex = 0,
            .dirty = true,
        };
        std.mem.set(u32, self.buffer, background_color);
        const start = height / 2 * width;
        std.mem.set(u32, self.buffer[start .. start + width], center_line_color);
        return self;
    }

    pub fn del(self: *DrawWaveform, allocator: *std.mem.Allocator) void {
        allocator.free(self.buffer);
        allocator.destroy(self);
    }

    pub fn plot(self: *DrawWaveform, samples: []const f32, mul: f32, _logarithmic: bool, _sr: f32, _oscil_freq: ?[]const f32) bool {
        var sample_min = samples[0];
        var sample_max = samples[0];
        for (samples[1..]) |sample| {
            if (sample < sample_min) sample_min = sample;
            if (sample > sample_max) sample_max = sample;
        }
        sample_min *= mul;
        sample_max *= mul;

        const y_mid = self.height / 2;
        var sx = self.drawindex;
        var sy: usize = 0;

        if (sample_min != sample_min or sample_max != sample_max) {
            // show NaN as a red center line
            while (sy < y_mid) : (sy += 1) {
                self.buffer[sy * self.width + sx] = background_color;
            }
            self.buffer[sy * self.width + sx] = clipped_color;
            sy += 1;
            while (sy < self.height) : (sy += 1) {
                self.buffer[sy * self.width + sx] = background_color;
            }
        } else {
            const fy_mid = @intToFloat(f32, y_mid);
            const fy_max = @intToFloat(f32, self.height - 1);
            const y0 = @floatToInt(usize, std.math.clamp(fy_mid - sample_max * fy_mid, 0, fy_max) + 0.5);
            const y1 = @floatToInt(usize, std.math.clamp(fy_mid - sample_min * fy_mid, 0, fy_max) + 0.5);
            var until: usize = undefined;

            if (sample_max >= 1.0) {
                self.buffer[sy * self.width + sx] = clipped_color;
                sy += 1;
            }
            until = std.math.min(y0, y_mid);
            while (sy < until) : (sy += 1) {
                self.buffer[sy * self.width + sx] = background_color;
            }
            until = std.math.min(y1, y_mid);
            while (sy < until) : (sy += 1) {
                self.buffer[sy * self.width + sx] = waveform_color;
            }
            while (sy < y_mid) : (sy += 1) {
                self.buffer[sy * self.width + sx] = background_color;
            }
            self.buffer[sy * self.width + sx] = center_line_color;
            sy += 1;
            if (y0 > y_mid) {
                until = std.math.min(y0, self.height);
                while (sy < until) : (sy += 1) {
                    self.buffer[sy * self.width + sx] = background_color;
                }
            }
            until = std.math.min(y1, self.height);
            while (sy < until) : (sy += 1) {
                self.buffer[sy * self.width + sx] = waveform_color;
            }
            while (sy < self.height) : (sy += 1) {
                self.buffer[sy * self.width + sx] = background_color;
            }
            if (sample_min <= -1.0) {
                sy -= 1;
                self.buffer[sy * self.width + sx] = clipped_color;
            }
        }

        self.dirty = true;
        self.drawindex += 1;
        if (self.drawindex == self.width) {
            self.drawindex = 0;
        }

        return true;
    }

    pub fn blit(self: *DrawWaveform, screen: Screen, _ctx: BlitContext) void {
        if (!self.dirty) return;
        self.dirty = false;

        scrollBlit(screen, self.x, self.y, self.width, self.height, self.buffer, self.drawindex);
    }
};

pub const DrawOscilloscope = struct {
    const _vtable = makeVTable(@This());

    const PaintedSpan = struct {
        y0: usize,
        y1: usize,
    };

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    mul: f32,
    samples: []f32,
    buffered_samples: []f32,
    num_buffered_samples: usize,
    painted_spans: []PaintedSpan,
    accum: f32,
    state: enum { up_to_date, needs_blit, needs_full_reblit },

    const background_color: u32 = 0xFF181818;
    const waveform_color: u32 = 0xFFAAAAAA;

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawOscilloscope {
        var self = try allocator.create(DrawOscilloscope);
        errdefer allocator.destroy(self);
        var samples = try allocator.alloc(f32, width);
        errdefer allocator.free(samples);
        var buffered_samples = try allocator.alloc(f32, width);
        errdefer allocator.free(buffered_samples);
        var painted_spans = try allocator.alloc(PaintedSpan, width);
        errdefer allocator.free(old_y);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .mul = 1.0,
            .samples = samples,
            .buffered_samples = buffered_samples,
            .num_buffered_samples = 0,
            .painted_spans = painted_spans,
            .accum = 0,
            .state = .needs_full_reblit,
        };
        std.mem.set(f32, samples, 0.0);
        return self;
    }

    pub fn del(self: *DrawOscilloscope, allocator: *std.mem.Allocator) void {
        allocator.free(self.samples);
        allocator.free(self.buffered_samples);
        allocator.free(self.painted_spans);
        allocator.destroy(self);
    }

    pub fn plot(self: *DrawOscilloscope, samples: []const f32, mul: f32, _logarithmic: bool, sr: f32, oscil_freq: ?[]const f32) bool {
        self.mul = mul; // meh
        // TODO can i refactor this into two classes? - one doesn't know about buffering.
        // the other wraps it and implements buffering. would that work?
        const inv_sr = 1.0 / sr;
        var n: usize = 0;
        var drain_buffer = false;
        if (oscil_freq) |freq| {
            // sync to oscil_freq
            for (samples) |_, i| {
                self.accum += freq[i] * inv_sr;
                // if frequency is so high that self.accum >= 2.0, you have bigger problems...
                if (self.accum >= 1.0) {
                    n = i;
                    self.accum -= 1.0;
                    drain_buffer = true;
                }
            }
        } else {
            // no syncing
            n = samples.len;
            drain_buffer = true;
        }
        // `n` is the number of new samples to move from `samples` to `self.samples`.
        const num_to_push = n + (if (drain_buffer) self.num_buffered_samples else 0);
        // move down existing self.samples to make room for the new stuff.
        if (num_to_push < self.samples.len) {
            const diff = self.samples.len - num_to_push;
            std.mem.copy(f32, self.samples[0..diff], self.samples[num_to_push..]);
        }
        // now add in buffered samples
        if (drain_buffer) {
            if (n >= self.samples.len) {
                // buffered samples will be immediately pushed all the way off by new samples
            } else {
                const buf = self.buffered_samples[0..self.num_buffered_samples];
                if (buf.len + n <= self.samples.len) {
                    // whole of buf fits in self.samples
                    const start = self.samples.len - n - buf.len;
                    std.mem.copy(f32, self.samples[start .. start + buf.len], buf);
                } else {
                    // only the latter part of buf will fit in self.samples
                    const num_to_copy = self.samples.len - n;
                    const b_start = buf.len - num_to_copy;
                    std.mem.copy(f32, self.samples[0..num_to_copy], buf[b_start..]);
                }
            }
            self.num_buffered_samples = 0;
        }
        // now add in new samples
        if (n <= self.samples.len) {
            // whole of new samples fits in self.samples
            const start = self.samples.len - n;
            std.mem.copy(f32, self.samples[start..], samples[0..n]);
        } else {
            // only the latter part of new samples will fit in self.samples
            std.mem.copy(f32, self.samples, samples[n - self.samples.len .. n]);
        }
        // everything after `n`, we add to self.buffered_samples.
        // it's possible there are still some old buffered_samples there.
        if (n < samples.len) {
            const to_buffer = samples[n..];
            const nbs = self.num_buffered_samples;
            if (nbs + to_buffer.len <= self.buffered_samples.len) {
                // there's empty space to fit all of it, just append it.
                std.mem.copy(f32, self.buffered_samples[nbs .. nbs + to_buffer.len], to_buffer);
                self.num_buffered_samples += to_buffer.len;
            } else if (to_buffer.len >= self.buffered_samples.len) {
                // new stuff will take up the entire buffer
                const start = to_buffer.len - self.buffered_samples.len;
                std.mem.copy(f32, self.buffered_samples, to_buffer[start..]);
                self.num_buffered_samples = self.buffered_samples.len;
            } else {
                // new stuff fits but has to push back old stuff.
                const to_keep = self.buffered_samples.len - to_buffer.len;
                std.mem.copy(f32, self.buffered_samples[0..to_keep], self.buffered_samples[nbs - to_keep .. 0]);
                std.mem.copy(f32, self.buffered_samples[to_keep..], to_buffer);
                self.num_buffered_samples = self.buffered_samples.len;
            }
        }

        if (self.state == .up_to_date) {
            self.state = .needs_blit;
        }
        return true;
    }

    pub fn blit(self: *DrawOscilloscope, screen: Screen, _ctx: BlitContext) void {
        if (self.state == .up_to_date) return;
        defer self.state = .up_to_date;

        const y_mid = self.height / 2;
        var old_y: usize = undefined;

        var i: usize = 0;
        while (i < self.width) : (i += 1) {
            const sx = self.x + i;
            const sample = std.math.max(-1.0, std.math.min(1.0, self.samples[i] * self.mul));

            var y: usize = undefined;
            var color: u32 = undefined;

            if (sample != sample) {
                // NaN - 1px red line in the center
                y = self.height / 2;
                color = 0xFFFF0000;
            } else {
                y = @floatToInt(usize, @intToFloat(f32, y_mid) - sample * @intToFloat(f32, self.height / 2) + 0.5);
                color = waveform_color;
            }

            const y_0 = if (i == 0) y else old_y;
            const y_1 = y;
            const y0 = std.math.min(y_0, y_1);
            const y1 = if (y_0 == y_1) std.math.min(y_0 + 1, self.height) else std.math.max(y_0, y_1);
            if (self.state == .needs_full_reblit) {
                var sy: usize = 0;
                while (sy < y0) : (sy += 1) {
                    screen.pixels[(self.y + sy) * screen.pitch + sx] = background_color;
                }
                while (sy < y1) : (sy += 1) {
                    screen.pixels[(self.y + sy) * screen.pitch + sx] = color;
                }
                while (sy < self.height) : (sy += 1) {
                    screen.pixels[(self.y + sy) * screen.pitch + sx] = background_color;
                }
            } else {
                const old_span = self.painted_spans[i];
                var sy = old_span.y0;
                while (sy < old_span.y1) : (sy += 1) {
                    screen.pixels[(self.y + sy) * screen.pitch + sx] = background_color;
                }
                sy = y0;
                while (sy < y1) : (sy += 1) {
                    screen.pixels[(self.y + sy) * screen.pitch + sx] = color;
                }
            }
            self.painted_spans[i] = .{ .y0 = y0, .y1 = y1 };
            old_y = y;
        }
    }
};

pub const DrawStaticString = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    drawn: bool,
    string: []const u8,
    bgcolor: u32,

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize, string: []const u8, bgcolor: u32) !*DrawStaticString {
        var self = try allocator.create(DrawStaticString);
        errdefer allocator.destroy(self);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .drawn = false,
            .string = string,
            .bgcolor = bgcolor,
        };
        return self;
    }

    pub fn del(self: *DrawStaticString, allocator: *std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn blit(self: *DrawStaticString, screen: Screen, ctx: BlitContext) void {
        if (self.drawn) return;
        self.drawn = true;

        const rect = clipRect(screen, self.x, self.y, self.width, self.height) orelse return;
        drawFill(screen, rect, self.bgcolor);
        drawString(screen, rect, self.string);
    }
};

pub const DrawRecorderState = struct {
    const _vtable = makeVTable(@This());

    vtable: *const VTable,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    recorder_state: std.meta.TagType(Recorder.State),

    pub fn new(allocator: *std.mem.Allocator, x: usize, y: usize, width: usize, height: usize) !*DrawRecorderState {
        var self = try allocator.create(DrawRecorderState);
        errdefer allocator.destroy(self);
        self.* = .{
            .vtable = &_vtable,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .recorder_state = .idle,
        };
        return self;
    }

    pub fn del(self: *DrawRecorderState, allocator: *std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn blit(self: *DrawRecorderState, screen: Screen, ctx: BlitContext) void {
        if (self.recorder_state == ctx.recorder_state) return;
        self.recorder_state = ctx.recorder_state;

        const rect = clipRect(screen, self.x, self.y, self.width, self.height) orelse return;
        drawFill(screen, rect, 0);
        drawString(screen, rect, switch (ctx.recorder_state) {
            .idle => "",
            .recording => "RECORDING",
            .playing => "PLAYING BACK",
        });
    }
};

pub const Visuals = struct {
    const State = enum {
        help,
        main,
        oscil,
        full_fft,
    };

    allocator: *std.mem.Allocator,
    screen_w: usize,
    screen_h: usize,

    state: State,
    clear: bool,
    widgets: std.ArrayList(**const VTable),

    logarithmic_fft: bool,
    script_error: ?[]const u8,

    pub fn init(allocator: *std.mem.Allocator, screen_w: usize, screen_h: usize) !Visuals {
        var self: Visuals = .{
            .allocator = allocator,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .state = .main,
            .clear = true,
            .widgets = std.ArrayList(**const VTable).init(allocator),
            .logarithmic_fft = false,
            .script_error = null,
        };
        self.setState(.main);
        return self;
    }

    pub fn deinit(self: *Visuals) void {
        self.clearWidgets();
        self.widgets.deinit();
    }

    fn clearWidgets(self: *Visuals) void {
        while (self.widgets.popOrNull()) |widget| {
            widget.*.delFn(widget, self.allocator);
        }
    }

    fn addWidget(self: *Visuals, inew: anytype) !void {
        var instance = try inew;
        self.widgets.append(&instance.vtable) catch |err| {
            instance.del(self.allocator);
            return err;
        };
    }

    fn addWidgets(self: *Visuals) !void {
        const fft_height = 128;
        const waveform_height = 81;
        const bottom_padding = fontchar_h;

        const str0 = "F1:Help ";
        try self.addWidget(DrawStaticString.new(
            self.allocator,
            0,
            0,
            stringWidth(str0),
            fontchar_h,
            str0,
            if (self.state == .help) 0xFF444444 else 0,
        ));
        const str1 = "F2:Waveform ";
        try self.addWidget(DrawStaticString.new(
            self.allocator,
            stringWidth(str0),
            0,
            stringWidth(str1),
            fontchar_h,
            str1,
            if (self.state == .main) 0xFF444444 else 0,
        ));
        const str2 = "F3:Oscillo ";
        try self.addWidget(DrawStaticString.new(
            self.allocator,
            stringWidth(str0) + stringWidth(str1),
            0,
            stringWidth(str2),
            fontchar_h,
            str2,
            if (self.state == .oscil) 0xFF444444 else 0,
        ));
        const str3 = "F4:Spectrum ";
        try self.addWidget(DrawStaticString.new(
            self.allocator,
            stringWidth(str0) + stringWidth(str1) + stringWidth(str2),
            0,
            stringWidth(str3),
            fontchar_h,
            str3,
            if (self.state == .full_fft) 0xFF444444 else 0,
        ));

        switch (self.state) {
            .help => {
                const help_h = 247;
                try self.addWidget(DrawStaticString.new(
                    self.allocator,
                    12,
                    fontchar_h + 13,
                    self.screen_w - 12 * 2,
                    help_h,
                    example.DESCRIPTION,
                    0,
                ));
                const text =
                    \\-----------------------------------------------------
                    \\
                    \\Help reference
                    \\
                    \\Press F1, F2, F3, or F4 to change the visualization
                    \\mode. Stay in this mode for the fastest performance.
                    \\
                    \\Press F5 to toggle between linear and logarithmic
                    \\spectrum display.
                    \\
                    \\Press ` (backquote/tilde) to record and play back
                    \\keypresses (if applicable to the loaded example).
                    \\
                    \\Press Enter to reload the loaded example.
                    \\
                    \\Press Escape to quit.
                    \\
                    \\-----------------------------------------------------
                ;
                try self.addWidget(DrawStaticString.new(
                    self.allocator,
                    12,
                    help_h,
                    self.screen_w - 12 * 2,
                    self.screen_h - bottom_padding - help_h,
                    text,
                    0,
                ));
            },
            .main => {
                if (self.script_error) |script_error| {
                    try self.addWidget(DrawStaticString.new(
                        self.allocator,
                        12,
                        fontchar_h + 13,
                        self.screen_w - 12 * 2,
                        self.screen_h - bottom_padding - waveform_height - (fontchar_h + 13),
                        script_error,
                        0,
                    ));
                } else {
                    try self.addWidget(DrawStaticString.new(
                        self.allocator,
                        12,
                        fontchar_h + 13,
                        self.screen_w - 12 * 2,
                        self.screen_h - bottom_padding - waveform_height - (fontchar_h + 13),
                        example.DESCRIPTION,
                        0,
                    ));
                }
                try self.addWidget(DrawWaveform.new(
                    self.allocator,
                    0,
                    self.screen_h - bottom_padding - waveform_height,
                    self.screen_w,
                    waveform_height,
                ));
                try self.addWidget(DrawSpectrum.new(
                    self.allocator,
                    0,
                    self.screen_h - bottom_padding - waveform_height - fft_height,
                    self.screen_w,
                    fft_height,
                ));
            },
            .oscil => {
                const height = 350;
                try self.addWidget(DrawOscilloscope.new(
                    self.allocator,
                    0,
                    self.screen_h - bottom_padding - height,
                    self.screen_w,
                    height,
                ));
            },
            .full_fft => {
                try self.addWidget(DrawSpectrumFull.new(
                    self.allocator,
                    0,
                    fontchar_h,
                    self.screen_w,
                    self.screen_h - fontchar_h - fontchar_h,
                ));
            },
        }

        try self.addWidget(DrawRecorderState.new(
            self.allocator,
            0,
            self.screen_h - fontchar_h,
            self.screen_w,
            fontchar_h,
        ));
    }

    pub fn setState(self: *Visuals, state: State) void {
        self.clearWidgets();
        self.state = state;
        self.addWidgets() catch |err| {
            std.debug.warn("error while initializing widgets: {}\n", .{err});
        };
        self.clear = true;
    }

    pub fn toggleLogarithmicFFT(self: *Visuals) void {
        self.logarithmic_fft = !self.logarithmic_fft;
    }

    pub fn setScriptError(self: *Visuals, script_error: ?[]const u8) void {
        self.script_error = script_error;
    }

    // called on the audio thread.
    // return true if a redraw should be triggered
    pub fn newInput(self: *Visuals, samples: []const f32, mul: f32, sr: f32, oscil_freq: ?[]const f32) bool {
        var redraw = false;

        var j: usize = 0;
        while (j < samples.len / 1024) : (j += 1) {
            const output = samples[j * 1024 .. j * 1024 + 1024];

            for (self.widgets.items) |widget| {
                if (widget.*.plotFn(widget, output, mul, self.logarithmic_fft, sr, oscil_freq)) {
                    redraw = true;
                }
            }
        }

        return redraw;
    }

    // called on the main thread with the audio thread locked
    pub fn blit(self: *Visuals, screen: Screen, ctx: BlitContext) void {
        if (self.clear) {
            self.clear = false;
            drawFill(screen, .{ .x = 0, .y = 0, .w = screen.width, .h = screen.height }, 0);
        }

        for (self.widgets.items) |widget| {
            widget.*.blitFn(widget, screen, ctx);
        }
    }
};
