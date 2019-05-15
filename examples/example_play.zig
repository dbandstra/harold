const zang = @import("zang");
const note_frequencies = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/sdl.zig");
const PMOscInstrument = @import("modules.zig").PMOscInstrument;
const FilteredSawtoothInstrument = @import("modules.zig").FilteredSawtoothInstrument;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    c\\example_play
    c\\
    c\\Play a simple monophonic synthesizer
    c\\with the keyboard.
    c\\
    c\\Press spacebar to create a low drone
    c\\in another voice.
;

const A4 = 440.0;

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 4;

    key0: ?i32,
    iq0: zang.Notes(PMOscInstrument.Params).ImpulseQueue,
    instr0: PMOscInstrument,
    trig0: zang.Trigger(PMOscInstrument.Params),
    iq1: zang.Notes(FilteredSawtoothInstrument.Params).ImpulseQueue,
    instr1: FilteredSawtoothInstrument,
    trig1: zang.Trigger(FilteredSawtoothInstrument.Params),

    pub fn init() MainModule {
        return MainModule{
            .key0 = null,
            .iq0 = zang.Notes(PMOscInstrument.Params).ImpulseQueue.init(),
            .instr0 = PMOscInstrument.init(1.0),
            .trig0 = zang.Trigger(PMOscInstrument.Params).init(),
            .iq1 = zang.Notes(FilteredSawtoothInstrument.Params).ImpulseQueue.init(),
            .instr1 = FilteredSawtoothInstrument.init(),
            .trig1 = zang.Trigger(FilteredSawtoothInstrument.Params).init(),
        };
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        {
            var ctr = self.trig0.counter(span, self.iq0.consume());
            while (self.trig0.next(&ctr)) |result| {
                self.instr0.paint(result.span, outputs, temps, result.note_id_changed, result.params);
            }
        }
        {
            var ctr = self.trig1.counter(span, self.iq1.consume());
            while (self.trig1.next(&ctr)) |result| {
                self.instr1.paint(result.span, outputs, [3][]f32{temps[0], temps[1], temps[2]}, result.note_id_changed, result.params);
            }
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (key == c.SDLK_SPACE) {
            self.iq1.push(impulse_frame, FilteredSawtoothInstrument.Params {
                .sample_rate = AUDIO_SAMPLE_RATE,
                .freq = A4 * note_frequencies.C4 / 4.0,
                .note_on = down,
            });
        } else if (common.getKeyRelFreq(key)) |rel_freq| {
            if (down or (if (self.key0) |nh| nh == key else false)) {
                self.key0 = if (down) key else null;
                self.iq0.push(impulse_frame, PMOscInstrument.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = A4 * rel_freq,
                    .note_on = down,
                });
            }
        }
    }
};
