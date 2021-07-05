const std = @import("std");
const zang = @import("zang");
const mod = @import("modules");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT: zang.AudioFormat = .signed16_lsb;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    \\example_fmsynth
;

const a4 = 440.0;
const polyphony = 8;

const Oscillator = struct {
    pub const num_outputs = 1;
    pub const num_temps = 0;
    pub const Params = struct {
        sample_rate: f32,
        waveform: u2,
        freq: []const f32,
        phase: ?[]const f32,
        feedback: f32,
    };

    t: f32,
    feedback1: f32,
    feedback2: f32,

    pub fn init() @This() {
        return .{
            .t = 0.0,
            .feedback1 = 0,
            .feedback2 = 0,
        };
    }

    pub fn paint(
        self: *@This(),
        span: zang.Span,
        outputs: [num_outputs][]f32,
        temps: [num_temps][]f32,
        note_id_changed: bool,
        params: Params,
    ) void {
        const output = outputs[0][span.start..span.end];

        var t = self.t;
        // it actually goes out of tune without this!...
        defer self.t = t - std.math.trunc(t);

        const inv_sample_rate = 1.0 / params.sample_rate;

        var i: usize = 0;
        while (i < output.len) : (i += 1) {
            const phase = if (params.phase) |p| p[span.start + i] else 0;
            const feedback = (self.feedback1 + self.feedback2) * params.feedback;

            const s = std.math.sin((t + phase + feedback) * std.math.pi * 2);
            const sample = switch (params.waveform) {
                0 => s,
                1 => std.math.max(s, 0),
                2 => std.math.fabs(s),
                3 => if (std.math.sin((t + phase + feedback) * std.math.pi * 4) >= 0)
                    std.math.fabs(s)
                else
                    0,
            };

            output[i] += sample;

            t += params.freq[span.start + i] * inv_sample_rate;
            self.feedback2 = self.feedback1;
            self.feedback1 = sample;
        }
    }
};

const Instrument = struct {
    pub const num_outputs = 1;
    pub const num_temps = 5;
    pub const Params = struct {
        sample_rate: f32,
        modulator_freq_mul: f32,
        modulator_waveform: u2,
        modulator_volume: f32,
        modulator_attack: f32,
        modulator_decay: f32,
        modulator_sustain: f32,
        modulator_release: f32,
        modulator_feedback: f32,
        modulator_tremolo: f32,
        modulator_vibrato: f32,
        carrier_freq_mul: f32,
        carrier_waveform: u2,
        carrier_volume: f32,
        carrier_attack: f32,
        carrier_decay: f32,
        carrier_sustain: f32,
        carrier_release: f32,
        carrier_tremolo: f32,
        carrier_vibrato: f32,
        freq: f32,
        note_on: bool,
    };

    vibrato_lfo: mod.SineOsc,
    tremolo_lfo: mod.SineOsc,
    modulator: Oscillator,
    modulator_env: mod.Envelope,
    carrier: Oscillator,
    carrier_env: mod.Envelope,

    pub fn init() Instrument {
        return .{
            .vibrato_lfo = mod.SineOsc.init(),
            .tremolo_lfo = mod.SineOsc.init(),
            .modulator = Oscillator.init(),
            .modulator_env = mod.Envelope.init(),
            .carrier = Oscillator.init(),
            .carrier_env = mod.Envelope.init(),
        };
    }

    pub fn paint(
        self: *Instrument,
        span: zang.Span,
        outputs: [num_outputs][]f32,
        temps: [num_temps][]f32,
        note_id_changed: bool,
        params: Params,
    ) void {
        // temp3 = tremolo lfo
        zang.zero(span, temps[3]);
        self.tremolo_lfo.paint(span, .{temps[3]}, .{}, note_id_changed, .{
            .sample_rate = params.sample_rate,
            .freq = zang.constant(3.7),
            .phase = zang.constant(0),
        });

        // temp4 = vibrato lfo
        zang.zero(span, temps[4]);
        self.vibrato_lfo.paint(span, .{temps[4]}, .{}, note_id_changed, .{
            .sample_rate = params.sample_rate,
            .freq = zang.constant(6.4),
            .phase = zang.constant(0),
        });

        // temp1 = tremolo lfo for modulator
        zang.copy(span, temps[1], temps[3]);
        zang.multiplyWithScalar(span, temps[1], params.modulator_tremolo);
        zang.addScalarInto(span, temps[1], 1.0);

        // temp2 = frequency for modulator
        zang.copy(span, temps[2], temps[4]);
        zang.multiplyWithScalar(span, temps[2], params.modulator_vibrato * 0.1);
        zang.addScalarInto(span, temps[2], 1.0);
        zang.multiplyWithScalar(span, temps[2], params.freq * params.modulator_freq_mul);

        // temp0 = modulator oscillator
        zang.zero(span, temps[0]);
        self.modulator.paint(span, .{temps[0]}, .{}, note_id_changed, .{
            .sample_rate = params.sample_rate,
            .freq = temps[2],
            .waveform = params.modulator_waveform,
            .phase = null,
            .feedback = params.modulator_feedback * 0.1,
        });
        zang.multiplyWithScalar(span, temps[0], params.modulator_volume);
        zang.multiplyWith(span, temps[0], temps[1]);

        // temp1 = modulator envelope
        zang.zero(span, temps[1]);
        self.modulator_env.paint(span, .{temps[1]}, .{}, note_id_changed, .{
            .sample_rate = params.sample_rate,
            .attack = .{ .cubed = params.modulator_attack },
            .decay = .{ .cubed = params.modulator_decay },
            .sustain_volume = params.modulator_sustain,
            .release = .{ .cubed = params.modulator_release },
            .note_on = params.note_on,
        });

        // temp0 = modulator with envelope applied
        zang.multiplyWith(span, temps[0], temps[1]);

        // temp3 = tremolo lfo for carrier
        zang.multiplyWithScalar(span, temps[3], params.carrier_tremolo);
        zang.addScalarInto(span, temps[3], 1.0);

        // temp4 = frequency for carrier
        zang.multiplyWithScalar(span, temps[4], params.carrier_vibrato * 0.1);
        zang.addScalarInto(span, temps[4], 1.0);
        zang.multiplyWithScalar(span, temps[4], params.freq * params.carrier_freq_mul);

        // temp1 = carrier oscillator
        zang.zero(span, temps[1]);
        self.carrier.paint(span, .{temps[1]}, .{}, note_id_changed, .{
            .sample_rate = params.sample_rate,
            .freq = temps[4],
            .waveform = params.carrier_waveform,
            .phase = temps[0],
            .feedback = 0,
        });
        zang.multiplyWithScalar(span, temps[1], params.carrier_volume);
        zang.multiplyWith(span, temps[1], temps[3]);

        // temp2 = carrier envelope
        zang.zero(span, temps[2]);
        self.carrier_env.paint(span, .{temps[2]}, .{}, note_id_changed, .{
            .sample_rate = params.sample_rate,
            .attack = .{ .cubed = params.carrier_attack },
            .decay = .{ .cubed = params.carrier_decay },
            .sustain_volume = params.carrier_sustain,
            .release = .{ .cubed = params.carrier_release },
            .note_on = params.note_on,
        });

        // output carrier with envelope applied
        zang.multiply(span, outputs[0], temps[1], temps[2]);
    }
};

pub const MainModule = struct {
    pub const num_outputs = 1;
    pub const num_temps = Instrument.num_temps;

    pub const output_audio = common.AudioOut{ .mono = 0 };
    pub const output_visualize = 0;

    const Voice = struct {
        module: Instrument,
        trigger: zang.Trigger(Instrument.Params),
    };

    parameters: [19]common.Parameter = [_]common.Parameter{
        .{ .desc = "Modulator frequency multiplier:", .value = 2.0 },
        .{ .desc = "Modulator waveform:", .value = 0 },
        .{ .desc = "Modulator volume:  ", .value = 1.0 },
        .{ .desc = "Modulator attack:  ", .value = 0.025 },
        .{ .desc = "Modulator decay:   ", .value = 0.1 },
        .{ .desc = "Modulator sustain: ", .value = 0.5 },
        .{ .desc = "Modulator release: ", .value = 1.0 },
        .{ .desc = "Modulator tremolo: ", .value = 0.0 },
        .{ .desc = "Modulator vibrato: ", .value = 0.0 },
        .{ .desc = "Modulator feedback:", .value = 0.0 },
        .{ .desc = "Carrier frequency multiplier:", .value = 1.0 },
        .{ .desc = "Carrier waveform:", .value = 0.0 },
        .{ .desc = "Carrier volume:  ", .value = 1.0 },
        .{ .desc = "Carrier attack:  ", .value = 0.025 },
        .{ .desc = "Carrier decay:   ", .value = 0.1 },
        .{ .desc = "Carrier sustain: ", .value = 0.5 },
        .{ .desc = "Carrier release: ", .value = 1.0 },
        .{ .desc = "Carrier tremolo: ", .value = 0.0 },
        .{ .desc = "Carrier vibrato: ", .value = 0.0 },
    },

    dispatcher: zang.Notes(Instrument.Params).PolyphonyDispatcher(polyphony),
    voices: [polyphony]Voice,

    note_ids: [common.key_bindings.len]?usize,
    next_note_id: usize,

    iq: zang.Notes(Instrument.Params).ImpulseQueue,

    pub fn init() MainModule {
        var self: MainModule = .{
            .note_ids = [1]?usize{null} ** common.key_bindings.len,
            .next_note_id = 1,
            .iq = zang.Notes(Instrument.Params).ImpulseQueue.init(),
            .dispatcher = zang.Notes(Instrument.Params).PolyphonyDispatcher(polyphony).init(),
            .voices = undefined,
        };
        var i: usize = 0;
        while (i < polyphony) : (i += 1) {
            self.voices[i] = .{
                .module = Instrument.init(),
                .trigger = zang.Trigger(Instrument.Params).init(),
            };
        }
        return self;
    }

    pub fn paint(
        self: *MainModule,
        span: zang.Span,
        outputs: [num_outputs][]f32,
        temps: [num_temps][]f32,
    ) void {
        const iap = self.iq.consume();

        const poly_iap = self.dispatcher.dispatch(iap);

        for (self.voices) |*voice, i| {
            var ctr = voice.trigger.counter(span, poly_iap[i]);
            while (voice.trigger.next(&ctr)) |result| {
                voice.module.paint(
                    result.span,
                    outputs,
                    temps,
                    result.note_id_changed,
                    result.params,
                );
            }
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) bool {
        for (common.key_bindings) |kb, i| {
            if (kb.key != key)
                continue;

            const params: Instrument.Params = .{
                .sample_rate = AUDIO_SAMPLE_RATE,
                .modulator_freq_mul = self.parameters[0].value,
                .modulator_waveform = @floatToInt(u2, self.parameters[1].value),
                .modulator_volume = self.parameters[2].value,
                .modulator_attack = self.parameters[3].value,
                .modulator_decay = self.parameters[4].value,
                .modulator_sustain = self.parameters[5].value,
                .modulator_release = self.parameters[6].value,
                .modulator_tremolo = self.parameters[7].value,
                .modulator_vibrato = self.parameters[8].value,
                .modulator_feedback = self.parameters[9].value,
                .carrier_freq_mul = self.parameters[10].value,
                .carrier_waveform = @floatToInt(u2, self.parameters[11].value),
                .carrier_volume = self.parameters[12].value,
                .carrier_attack = self.parameters[13].value,
                .carrier_decay = self.parameters[14].value,
                .carrier_sustain = self.parameters[15].value,
                .carrier_release = self.parameters[16].value,
                .carrier_tremolo = self.parameters[17].value,
                .carrier_vibrato = self.parameters[18].value,
                .freq = a4 * kb.rel_freq,
                .note_on = down,
            };

            if (down) {
                self.iq.push(impulse_frame, self.next_note_id, params);
                self.note_ids[i] = self.next_note_id;
                self.next_note_id += 1;
            } else if (self.note_ids[i]) |note_id| {
                self.iq.push(impulse_frame, note_id, params);
                self.note_ids[i] = null;
            }
        }
        return true;
    }
};