// in this example a canned melody is played

const std = @import("std");
const zang = @import("zang");
const f = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;
pub const AUDIO_CHANNELS = 1;

const A4 = 440.0;

const MyNoteParams = PulseModOscillator.Params;
const MyNotes = zang.Notes(MyNoteParams);

const Note = common.Note;
const track1Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A4, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs4, .note_on = true }, .dur = 8 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = false }, .dur = 4 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A3, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E3, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F3, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs3, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = false }, .dur = 4 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A2, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs2, .note_on = true }, .dur = 8 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = false }, .dur = 2 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D1, .note_on = true }, .dur = 128 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D1, .note_on = false }, .dur = 0 },
};
const track2Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A5, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D5, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs5, .note_on = true }, .dur = 8 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D5, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D5, .note_on = false }, .dur = 4 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G4, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A4, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E4, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F4, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs4, .note_on = true }, .dur = 3 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D4, .note_on = false }, .dur = 4 },

    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A3, .note_on = true }, .dur = 10 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.F3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = true }, .dur = 1 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs3, .note_on = true }, .dur = 8 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = true }, .dur = 12 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = false }, .dur = 2 },
};
const ofs = 130;
const A = 6;
const B = 6;
const C = 5;
const D = 4;
const E = 4;
const track3Delay = ofs;
const track3Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs2, .note_on = true }, .dur = A + B + C + D + E + 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = true }, .dur = 14 + (14 + 30) },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D2, .note_on = false }, .dur = 0 },
};
const track4Delay = ofs + A;
const track4Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E2, .note_on = true }, .dur = B + C + D + E + 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E2, .note_on = false }, .dur = 0 },
};
const track5Delay = ofs + A + B;
const track5Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.G2, .note_on = true }, .dur = C + D + E + 30 + (14) },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E2, .note_on = true }, .dur = 14 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Fs2, .note_on = true }, .dur = 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Fs2, .note_on = false }, .dur = 0 },
};
const track6Delay = ofs + A + B + C;
const track6Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Bb2, .note_on = true }, .dur = D + E + 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A2, .note_on = true }, .dur = 14 + (14 + 30) },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.A2, .note_on = false }, .dur = 0 },
};
const track7Delay = ofs + A + B + C + D;
const track7Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs3, .note_on = true }, .dur = E + 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.Cs3, .note_on = false }, .dur = 0 },
};
const track8Delay = ofs + A + B + C + D + E;
const track8Init = []Note(MyNoteParams) {
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.E3, .note_on = true }, .dur = 30 },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = true }, .dur = 14 + (14 + 30) },
    Note(MyNoteParams){ .value = MyNoteParams{ .freq = A4 * f.D3, .note_on = false }, .dur = 0 },
};

const NUM_TRACKS = 8;
const NOTE_DURATION = 0.08;

const tracks = [NUM_TRACKS][]const MyNotes.SongNote {
    common.compileSong(MyNoteParams, track1Init.len, track1Init, NOTE_DURATION, 0.0),
    common.compileSong(MyNoteParams, track2Init.len, track2Init, NOTE_DURATION, 0.0),
    common.compileSong(MyNoteParams, track3Init.len, track3Init, NOTE_DURATION, track3Delay),
    common.compileSong(MyNoteParams, track4Init.len, track4Init, NOTE_DURATION, track4Delay),
    common.compileSong(MyNoteParams, track5Init.len, track5Init, NOTE_DURATION, track5Delay),
    common.compileSong(MyNoteParams, track6Init.len, track6Init, NOTE_DURATION, track6Delay),
    common.compileSong(MyNoteParams, track7Init.len, track7Init, NOTE_DURATION, track7Delay),
    common.compileSong(MyNoteParams, track8Init.len, track8Init, NOTE_DURATION, track8Delay),
};

// an example of a custom "module"
const PulseModOscillator = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 3;
    pub const Params = struct {
        freq: f32,
        note_on: bool,
    };

    carrier: zang.Oscillator,
    modulator: zang.Oscillator,
    // ratio: the carrier oscillator will use whatever frequency you give the
    // PulseModOscillator. the modulator oscillator will multiply the frequency
    // by this ratio. for example, a ratio of 0.5 means that the modulator
    // oscillator will always play at half the frequency of the carrier
    // oscillator
    ratio: f32,
    // multiplier: the modulator oscillator's output is multiplied by this
    // before it is fed in to the phase input of the carrier oscillator.
    multiplier: f32,

    fn init(ratio: f32, multiplier: f32) PulseModOscillator {
        return PulseModOscillator{
            .carrier = zang.Oscillator.init(),
            .modulator = zang.Oscillator.init(),
            .ratio = ratio,
            .multiplier = multiplier,
        };
    }

    fn reset(self: *PulseModOscillator) void {}

    fn paint(self: *PulseModOscillator, sample_rate: f32, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32, params: Params) void {
        const out = outputs[0];

        zang.set(temps[0], params.freq);
        zang.set(temps[1], params.freq * self.ratio);
        zang.zero(temps[2]);
        self.modulator.paint(sample_rate, [1][]f32{temps[2]}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sine,
            .freq = zang.buffer(temps[1]),
            .phase = zang.constant(0.0),
            .colour = 0.5,
        });
        zang.zero(temps[1]);
        zang.multiplyScalar(temps[1], temps[2], self.multiplier);
        self.carrier.paint(sample_rate, [1][]f32{out}, [0][]f32{}, zang.Oscillator.Params {
            .waveform = .Sine,
            .freq = zang.buffer(temps[0]),
            .phase = zang.buffer(temps[1]),
            .colour = 0.5,
        });
    }
};

var g_buffers: struct {
    buf0: [AUDIO_BUFFER_SIZE]f32,
    buf1: [AUDIO_BUFFER_SIZE]f32,
    buf2: [AUDIO_BUFFER_SIZE]f32,
    buf3: [AUDIO_BUFFER_SIZE]f32,
    buf4: [AUDIO_BUFFER_SIZE]f32,
} = undefined;

pub const MainModule = struct {
    osc: [NUM_TRACKS]zang.Triggerable(PulseModOscillator),
    env: [NUM_TRACKS]zang.Triggerable(zang.Envelope),
    trackers: [NUM_TRACKS]MyNotes.NoteTracker,

    pub fn init() MainModule {
        var mod: MainModule = undefined;

        var i: usize = 0;
        while (i < NUM_TRACKS) : (i += 1) {
            mod.osc[i] = zang.initTriggerable(PulseModOscillator.init(1.0, 1.5));
            mod.env[i] = zang.initTriggerable(zang.Envelope.init(zang.EnvParams {
                .attack_duration = 0.025,
                .decay_duration = 0.1,
                .sustain_volume = 0.5,
                .release_duration = 0.15,
            }));
            mod.trackers[i] = MyNotes.NoteTracker.init(tracks[i]);
        }

        return mod;
    }

    pub fn paint(self: *MainModule, sample_rate: f32) [AUDIO_CHANNELS][]const f32 {
        const out = g_buffers.buf0[0..];
        const tmp0 = g_buffers.buf1[0..];
        const tmp1 = g_buffers.buf2[0..];
        const tmp2 = g_buffers.buf3[0..];
        const tmp3 = g_buffers.buf4[0..];

        zang.zero(out);

        var i: usize = 0;
        while (i < NUM_TRACKS) : (i += 1) {
            const impulses = self.trackers[i].getImpulses(sample_rate, out.len);

            zang.zero(tmp0);
            self.osc[i].paintFromImpulses(sample_rate, [1][]f32{tmp0}, [3][]f32{tmp1, tmp2, tmp3}, impulses);
            zang.zero(tmp1);
            {
                var conv = zang.ParamsConverter(MyNoteParams, zang.Envelope.Params).init();
                self.env[i].paintFromImpulses(sample_rate, [1][]f32{tmp1}, [0][]f32{}, conv.autoStructural(impulses));
            }
            zang.multiply(out, tmp0, tmp1);
        }

        return [AUDIO_CHANNELS][]const f32 {
            out,
        };
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {}
};
