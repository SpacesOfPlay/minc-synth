// presets.mc: writes the built-in presets to patches/*.patch.
//
//   minc run tools/presets.mc
//
// Each preset is a small function that patches cables and sets knobs in
// their own units, by name; the file holds the same patch in the text
// format (normalized knobs). Each is then mastered: rendered for a few
// seconds with a key held, and OUT's master set so the render peaks near
// -2 dBFS (the limiter's knee is at -3 dBFS, so the loudest moments
// lean on it a little). The files are what the app and the tests
// load. A preset changed in the app and saved over its file is just as
// valid; update or drop its definition here if that happens.

import math;
import str;
import file;
import "../src/dsp_math.mc";
import "../src/engine_cmd.mc";
import "../src/engine.mc";
import "../src/rack.mc";
import "../src/patch.mc";
import "../src/patch_io.mc";

struct Preset {
    str name;
    i32 profile;
    fn(Patch*, Engine*): void build;
}

// ---- helpers ----

void cable(Patch* p, Engine* e, str src, str dst) {
    i32 s = engine_output_ref(e, src);
    i32 d = engine_input_ref(e, dst);
    if s < 0 || d < 0 {
        eprint("no such port: {} -> {}\n", src, dst);
        exit(1);
    }
    if !patch_connect(p, e, s, d) {
        eprint("refused: {} -> {}\n", src, dst);
        exit(1);
    }
}

void set(Patch* p, Engine* e, str ref, f32 value) {
    i32 k = engine_param_ref(e, ref);
    if k < 0 {
        eprint("no such knob: {}\n", ref);
        exit(1);
    }
    ignore patch_set_param(p, e, k, param_unmap(&e.core.params[k], value));
}

// Semitones above C4 as volts.
f32 st(f32 semitones) { return semitones / 12.0f; }

// A row of the sequencer, in semitones, on the 2 V range with the quantizer on.
void seq_row(Patch* p, Engine* e, str row, str range_p, str quant_p, i32[8] notes) {
    set(p, e, range_p, 1.0f);           // 2 V
    set(p, e, quant_p, 1.0f);
    for i32 i = 0; i < 8; i++ {
        string ref = format("seq.{}{}", row, i + 1);
        defer free(ref);
        set(p, e, str_from(ref.data, ref.len), st(cast(f32, notes[i])) / 2.0f);
    }
}

void stereo_out(Patch* p, Engine* e, str src) {
    cable(p, e, src, "out.l");
    cable(p, e, src, "out.r");
}

// ---- the presets ----

// Three detuned saws an octave down through the ladder, the classic.
void unison_bass(Patch* p, Engine* e) {
    cable(p, e, "keys.pitch", "bank1.pitch1");
    cable(p, e, "bank1.saw1", "mix1.in1");
    cable(p, e, "bank1.saw2", "mix1.in2");
    cable(p, e, "bank1.saw3", "mix1.in3");
    cable(p, e, "mix1.out", "lowpass.in1");
    cable(p, e, "lowpass.out", "amp1.in1");
    cable(p, e, "env1.env", "amp1.cv1");
    cable(p, e, "env2.env", "lowpass.cv1");
    stereo_out(p, e, "amp1.out");
    set(p, e, "keys.octave", -1.0f);
    set(p, e, "keys.glide", 0.02f);
    set(p, e, "bank1.fine1", -0.007f);
    set(p, e, "bank1.fine3", 0.008f);
    set(p, e, "bank1.oct2", -1.0f);
    set(p, e, "mix1.level1", 0.55f);
    set(p, e, "mix1.level2", 0.55f);
    set(p, e, "mix1.level3", 0.55f);
    set(p, e, "lowpass.cutoff", -1.0f);
    set(p, e, "lowpass.res", 0.35f);
    set(p, e, "lowpass.drive", 1.6f);
    set(p, e, "lowpass.cv1_depth", 0.55f);
    set(p, e, "env1.attack", 0.004f);
    set(p, e, "env1.decay", 0.3f);
    set(p, e, "env1.sustain", 0.7f);
    set(p, e, "env1.release", 0.15f);
    set(p, e, "env2.attack", 0.004f);
    set(p, e, "env2.decay", 0.35f);
    set(p, e, "env2.sustain", 0.15f);
    set(p, e, "env2.release", 0.2f);
}

// OSC hard-synced to a bank core; an envelope sweeps the slave's pitch.
void sync_lead(Patch* p, Engine* e) {
    cable(p, e, "keys.pitch", "bank1.pitch1");
    cable(p, e, "keys.pitch", "osc.pitch1");
    cable(p, e, "bank1.saw1", "osc.sync");
    cable(p, e, "env2.env", "atten.in1");
    cable(p, e, "atten.out1", "osc.pitch2");
    cable(p, e, "osc.saw", "lowpass.in1");
    cable(p, e, "lowpass.out", "amp1.in1");
    cable(p, e, "env1.env", "amp1.cv1");
    stereo_out(p, e, "amp1.out");
    set(p, e, "keys.glide", 0.04f);
    set(p, e, "atten.gain1", 0.35f);            // env 10 V -> 3.5 octaves of sweep
    set(p, e, "osc.fine", st(2.0f));
    set(p, e, "lowpass.cutoff", 3.0f);
    set(p, e, "lowpass.res", 0.15f);
    set(p, e, "env1.attack", 0.003f);
    set(p, e, "env1.decay", 0.2f);
    set(p, e, "env1.sustain", 0.8f);
    set(p, e, "env1.release", 0.2f);
    set(p, e, "env2.attack", 0.01f);
    set(p, e, "env2.decay", 0.6f);
    set(p, e, "env2.sustain", 0.2f);
    set(p, e, "env2.release", 0.3f);
}

// The sequencer plays a saw through the ladder; plucked by two envelopes.
void ladder_arpeggio(Patch* p, Engine* e) {
    cable(p, e, "seq.a", "osc.pitch1");
    cable(p, e, "seq.gate", "env1.gate");
    cable(p, e, "seq.gate", "env2.gate");
    cable(p, e, "osc.saw", "lowpass.in1");
    cable(p, e, "lowpass.out", "amp1.in1");
    cable(p, e, "env1.env", "amp1.cv1");
    cable(p, e, "env2.env", "lowpass.cv1");
    stereo_out(p, e, "amp1.out");
    seq_row(p, e, "a", "seq.range_a", "seq.quant_a", { 0, 3, 7, 12, 7, 3, 10, 5 });
    set(p, e, "seq.rate", 6.0f);
    set(p, e, "seq.length", 0.4f);
    set(p, e, "osc.octave", -1.0f);
    set(p, e, "lowpass.cutoff", 0.0f);
    set(p, e, "lowpass.res", 0.5f);
    set(p, e, "lowpass.cv1_depth", 0.5f);
    set(p, e, "env1.attack", 0.002f);
    set(p, e, "env1.decay", 0.25f);
    set(p, e, "env1.sustain", 0.0f);
    set(p, e, "env1.release", 0.1f);
    set(p, e, "env2.attack", 0.002f);
    set(p, e, "env2.decay", 0.15f);
    set(p, e, "env2.sustain", 0.0f);
    set(p, e, "env2.release", 0.1f);
}

// The ladder self-oscillates; the sequencer plays it through the cutoff,
// and a little of each gate goes into the filter to pluck it.
void filter_bleeps(Patch* p, Engine* e) {
    cable(p, e, "seq.a", "lowpass.cv1");
    cable(p, e, "seq.gate", "atten.in1");
    cable(p, e, "atten.out1", "lowpass.in2");
    cable(p, e, "seq.gate", "env1.gate");
    cable(p, e, "lowpass.out", "atten.in2");        // a ringing filter is quiet: 6 dB up on the way out
    cable(p, e, "atten.out2", "amp1.in1");
    cable(p, e, "env1.env", "amp1.cv1");
    stereo_out(p, e, "amp1.out");
    seq_row(p, e, "a", "seq.range_a", "seq.quant_a", { 0, 7, 12, 19, 24, 12, 5, 17 });
    set(p, e, "seq.rate", 8.0f);
    set(p, e, "seq.length", 0.3f);
    set(p, e, "atten.gain1", 0.05f);
    set(p, e, "atten.gain2", 2.0f);
    set(p, e, "lowpass.cutoff", 0.0f);
    set(p, e, "lowpass.res", 1.0f);
    set(p, e, "lowpass.cv1_depth", 1.0f);
    set(p, e, "env1.attack", 0.001f);
    set(p, e, "env1.decay", 0.12f);
    set(p, e, "env1.sustain", 0.0f);
    set(p, e, "env1.release", 0.05f);
}

// Three octaves of saws through the fixed filter bank, the cutoff
// drifting on a slow random voltage. Plays without keys.
void bank_drone(Patch* p, Engine* e) {
    cable(p, e, "bank1.saw1", "mix1.in1");
    cable(p, e, "bank1.saw2", "mix1.in2");
    cable(p, e, "bank1.saw3", "mix1.in3");
    cable(p, e, "mix1.out", "spectrum.in");
    cable(p, e, "spectrum.out", "lowpass.in1");
    cable(p, e, "noise.smooth", "lowpass.cv1");
    stereo_out(p, e, "lowpass.out");
    set(p, e, "bank1.freq", -1.0f);
    set(p, e, "bank1.oct2", -1.0f);
    set(p, e, "bank1.oct3", 1.0f);
    set(p, e, "bank1.fine1", -0.01f);
    set(p, e, "bank1.fine3", 0.012f);
    set(p, e, "mix1.level1", 0.5f);
    set(p, e, "mix1.level2", 0.6f);
    set(p, e, "mix1.level3", 0.35f);
    f32[14] bands = { 1.0f, 0.8f, 0.5f, 1.0f, 0.3f, 0.9f, 0.2f, 0.7f, 0.2f, 0.5f, 0.15f, 0.4f, 0.1f, 0.3f };
    str[14] names = { "low", "125", "177", "250", "354", "500", "707", "1k", "1.4k", "2k", "2.8k", "4k", "5.6k", "high" };
    for i32 i = 0; i < 14; i++ {
        string ref = format("spectrum.{}", names[i]);
        defer free(ref);
        set(p, e, str_from(ref.data, ref.len), bands[i]);
    }
    set(p, e, "noise.rate", 0.3f);
    set(p, e, "noise.slew", 1.5f);
    set(p, e, "lowpass.cutoff", 1.0f);
    set(p, e, "lowpass.res", 0.3f);
    set(p, e, "lowpass.cv1_depth", 0.3f);
}

// VINTAGE. A bank core's pulse clocks the sequencer through GATES; white
// noise through the band-pass is the hat, a low sine the kick.
void noise_percussion(Patch* p, Engine* e) {
    cable(p, e, "bank2.pulse1", "gates.sig1");
    cable(p, e, "gates.gate1", "seq.clock");
    cable(p, e, "noise.white", "band.in");
    cable(p, e, "band.bp", "amp1.in1");
    cable(p, e, "seq.gate", "env1.gate");
    cable(p, e, "env1.env", "amp1.cv1");
    cable(p, e, "osc.sine", "amp2.in1");
    cable(p, e, "seq.step1", "env2.gate");
    cable(p, e, "seq.step4", "env2.gate");
    cable(p, e, "seq.step6", "env2.gate");
    cable(p, e, "env2.env", "amp2.cv1");
    cable(p, e, "amp1.out", "mix1.in1");
    cable(p, e, "amp2.out", "mix1.in2");
    stereo_out(p, e, "mix1.out");
    set(p, e, "bank2.freq", -4.0f);
    set(p, e, "bank2.oct1", -1.0f);              // 8 Hz
    set(p, e, "band.center", 3.0f);              // about 2 kHz
    set(p, e, "band.width", 0.6f);
    set(p, e, "seq.length", 0.15f);
    set(p, e, "env1.attack", 0.001f);
    set(p, e, "env1.decay", 0.08f);
    set(p, e, "env1.sustain", 0.0f);
    set(p, e, "env1.release", 0.03f);
    set(p, e, "osc.octave", -2.0f);
    set(p, e, "env2.attack", 0.001f);
    set(p, e, "env2.decay", 0.25f);
    set(p, e, "env2.sustain", 0.0f);
    set(p, e, "env2.release", 0.1f);
    set(p, e, "mix1.level1", 0.5f);
    set(p, e, "mix1.level2", 0.9f);
}

// VINTAGE. A three-stage switch adds a root, a fifth or an octave to a
// sequenced bass line, so the melody turns over every 24 steps.
void step_switch_melody(Patch* p, Engine* e) {
    cable(p, e, "bank2.pulse1", "gates.sig1");
    cable(p, e, "gates.gate1", "seq.clock");
    cable(p, e, "seq.clock", "stepsw.shift");
    cable(p, e, "offsets.out1", "stepsw.a");
    cable(p, e, "offsets.out2", "stepsw.b");
    cable(p, e, "offsets.out3", "stepsw.c");
    cable(p, e, "stepsw.out", "osc.pitch1");
    cable(p, e, "seq.a", "osc.pitch2");
    cable(p, e, "seq.gate", "env1.gate");
    cable(p, e, "seq.gate", "env2.gate");
    cable(p, e, "osc.pulse", "lowpass.in1");
    cable(p, e, "lowpass.out", "amp1.in1");
    cable(p, e, "env1.env", "amp1.cv1");
    cable(p, e, "env2.env", "lowpass.cv1");
    stereo_out(p, e, "amp1.out");
    set(p, e, "bank2.freq", -4.0f);
    set(p, e, "bank2.oct1", -2.0f);              // 4 Hz
    set(p, e, "offsets.coarse2", st(7.0f));
    set(p, e, "offsets.coarse3", st(12.0f));
    seq_row(p, e, "a", "seq.range_a", "seq.quant_a", { 0, 0, 3, 0, 5, 3, 0, 10 });
    set(p, e, "seq.length", 0.5f);
    set(p, e, "osc.octave", -1.0f);
    set(p, e, "osc.width", 0.3f);
    set(p, e, "lowpass.cutoff", -0.5f);
    set(p, e, "lowpass.res", 0.4f);
    set(p, e, "lowpass.cv1_depth", 0.4f);
    set(p, e, "env1.attack", 0.002f);
    set(p, e, "env1.decay", 0.2f);
    set(p, e, "env1.sustain", 0.6f);
    set(p, e, "env1.release", 0.1f);
    set(p, e, "env2.attack", 0.002f);
    set(p, e, "env2.decay", 0.12f);
    set(p, e, "env2.sustain", 0.1f);
    set(p, e, "env2.release", 0.1f);
}

// The filtered output feeds back into the oscillator's linear FM, with a
// bank sine mixed in: a growl that breaks up on the higher keys. Deeper
// feedback (index 2, mix 0.7) is plain distortion, by ear.
void fm_chaos(Patch* p, Engine* e) {
    cable(p, e, "keys.pitch", "osc.pitch1");
    cable(p, e, "keys.pitch", "bank1.pitch1");
    cable(p, e, "osc.saw", "lowpass.in1");
    cable(p, e, "lowpass.out", "amp1.in1");
    cable(p, e, "env1.env", "amp1.cv1");
    cable(p, e, "env2.env", "lowpass.cv1");
    cable(p, e, "amp1.out", "mix2.in1");
    cable(p, e, "bank1.sine1", "mix2.in2");
    cable(p, e, "mix2.out", "osc.fm");
    stereo_out(p, e, "amp1.out");
    set(p, e, "osc.fm", 0.6f);
    set(p, e, "bank1.oct1", 1.0f);
    set(p, e, "bank1.fine1", st(0.3f));
    set(p, e, "mix2.level1", 0.4f);
    set(p, e, "mix2.level2", 0.3f);
    set(p, e, "lowpass.cutoff", 1.5f);
    set(p, e, "lowpass.res", 0.6f);
    set(p, e, "lowpass.cv1_depth", 0.5f);
    set(p, e, "env1.attack", 0.005f);
    set(p, e, "env1.decay", 0.4f);
    set(p, e, "env1.sustain", 0.6f);
    set(p, e, "env1.release", 0.3f);
    set(p, e, "env2.attack", 0.01f);
    set(p, e, "env2.decay", 0.5f);
    set(p, e, "env2.sustain", 0.3f);
    set(p, e, "env2.release", 0.3f);
}

const f32 MASTER_TARGET = 0.8f;         // peak, of full scale
const i32 MASTER_KEY = 48;              // C3, held through the render
const i32 MASTER_SECONDS = 4;

// The peak of the patch played from a fresh engine for a few seconds,
// with OUT's master at its default.
f32 preset_peak(Patch* p) {
    Engine* e = engine_new_os(48000.0f, 2);
    defer engine_free(e);
    rack_build(e);
    patch_apply_to_engine(p, e);
    ignore engine_key_on(e, MASTER_KEY);
    // A polyphonic preset is played in chords, so it is mastered on one.
    if p.params[engine_param_ref(e, "keys.voices")] > 0.0f {
        ignore engine_key_on(e, MASTER_KEY + 4);
        ignore engine_key_on(e, MASTER_KEY + 7);
        ignore engine_key_on(e, MASTER_KEY + 11);
    }
    f32[1024] buf;
    f32 peak = 0.0f;
    i32 frames = 48000 * MASTER_SECONDS;
    for i32 done = 0; done < frames; done += 512 {
        engine_render(e, &buf[0], 512, 2);
        for i32 i = 0; i < 1024; i++ { if fabsf(buf[i]) > peak { peak = fabsf(buf[i]); } }
    }
    return peak;
}

// Sets OUT's master so the render peaks near the target; the knob stops
// at 1, so a quiet patch gets what it can.
void master(Patch* p, Engine* e) {
    i32 k = engine_param_ref(e, "out.master");
    f32 before = param_map(&e.core.params[k], p.params[k]);
    f32 peak = preset_peak(p);
    if peak < 1e-4f { return; }
    f32 want = before * MASTER_TARGET / peak;
    f32 m = clampf(want, 0.05f, 1.0f);
    set(p, e, "out.master", m);
    // Past the master's stop, the two level knobs (0.8 by default) give
    // a little more.
    if want > 1.0f {
        f32 level = clampf(0.8f * want / m, 0.8f, 1.0f);
        set(p, e, "out.level_l", level);
        set(p, e, "out.level_r", level);
    }
    // A render that hit the limiter comes down less than the master does:
    // measure again and correct once more.
    f32 again = preset_peak(p);
    if want <= 1.0f && fabsf(again - MASTER_TARGET) > 0.02f {
        m = clampf(m * MASTER_TARGET / again, 0.05f, 1.0f);
        set(p, e, "out.master", m);
        again = preset_peak(p);
    }
    print("  peak {} at master {} -> master {}, peak about {}\n", cast(f64, peak), cast(f64, before), cast(f64, m), cast(f64, again));
}

// Six voices, each two detuned saws through its own ladder, with its own
// envelopes: a pad that plays chords.
void poly_pad(Patch* p, Engine* e) {
    cable(p, e, "keys.pitch", "bank1.pitch1");
    cable(p, e, "bank1.saw1", "mix1.in1");
    cable(p, e, "bank1.saw2", "mix1.in2");
    cable(p, e, "mix1.out", "lowpass.in1");
    cable(p, e, "lowpass.out", "amp1.in1");
    cable(p, e, "env1.env", "amp1.cv1");
    cable(p, e, "env2.env", "lowpass.cv1");
    stereo_out(p, e, "amp1.out");
    set(p, e, "keys.voices", 6.0f);
    set(p, e, "bank1.fine1", -0.008f);
    set(p, e, "bank1.fine2", 0.008f);
    set(p, e, "mix1.level1", 0.5f);
    set(p, e, "mix1.level2", 0.5f);
    set(p, e, "lowpass.cutoff", 0.0f);
    set(p, e, "lowpass.res", 0.25f);
    set(p, e, "lowpass.cv1_depth", 0.45f);
    set(p, e, "env1.attack", 0.25f);
    set(p, e, "env1.decay", 1.0f);
    set(p, e, "env1.sustain", 0.8f);
    set(p, e, "env1.release", 1.2f);
    set(p, e, "env2.attack", 0.6f);
    set(p, e, "env2.decay", 1.5f);
    set(p, e, "env2.sustain", 0.4f);
    set(p, e, "env2.release", 1.2f);
}

Preset[9] PRESETS = {
    Preset{ "01-unison-bass", PROFILE_MODERN, unison_bass },
    Preset{ "02-sync-lead", PROFILE_MODERN, sync_lead },
    Preset{ "03-ladder-arpeggio", PROFILE_MODERN, ladder_arpeggio },
    Preset{ "04-filter-bleeps", PROFILE_MODERN, filter_bleeps },
    Preset{ "05-bank-drone", PROFILE_MODERN, bank_drone },
    Preset{ "06-noise-percussion", PROFILE_VINTAGE, noise_percussion },
    Preset{ "07-step-switch-melody", PROFILE_VINTAGE, step_switch_melody },
    Preset{ "08-fm-chaos", PROFILE_MODERN, fm_chaos },
    Preset{ "09-poly-pad", PROFILE_MODERN, poly_pad },
};

i32 main() {
    if !dir_create("patches") {
        eprint("cannot create patches/\n");
        return 1;
    }
    for i32 i = 0; i < 9; i++ {
        Engine* e = engine_new(48000.0f);
        defer engine_free(e);
        rack_build(e);
        Patch* p = new(Patch);
        defer free(p);
        patch_init(p, e);
        ignore patch_set_profile(p, e, PRESETS[i].profile);
        PRESETS[i].build(p, e);
        master(p, e);
        string path = format("patches/{}.patch", PRESETS[i].name);
        defer free(path);
        if !patch_io_save(p, e, str_from(path.data, path.len)) {
            eprint("cannot write {}\n", path);
            return 1;
        }
        print("{}: {} cables\n", path, p.n_cables);
        patch_free(p);
    }
    return 0;
}
