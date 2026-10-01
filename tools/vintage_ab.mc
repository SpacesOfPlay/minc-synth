// vintage_ab.mc: an A/B set for tuning the VINTAGE audio level.
//
//   minc run tools/vintage_ab.mc
//
// The VINTAGE audio factor (volts an audio signal swings) only shows
// where audio drives a control input. Four such patches, each rendered
// in MODERN and in VINTAGE at three factors, into build/vintage_ab/. In
// every file a C3 is held for 8 s while the modulation depth rises from
// 0 to full, so one file walks the whole knob.

import math;
import str;
import file;
import "../src/profile.mc";
import "../src/engine_cmd.mc";
import "../src/engine.mc";
import "../src/rack.mc";
import "../src/wav.mc";

const i32 SR = 48000;
const i32 SECONDS = 8;
const i32 BLOCK = 512;
const i32 NOTE = 48;
const str DIR = "build/vintage_ab";

struct Patch {
    str name;
    str depth;                          // the knob swept from 0 to full
    f32 depth_max;                      // its value at full, in its own units
    fn(Engine*): void build;
}

// A bank core an octave up, into the cutoff of a ladder playing a saw.
void filter_fm(Engine* e) {
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "keys.pitch", "bank1.pitch1");
    ignore engine_connect(e, "osc.saw", "lowpass.in1");
    ignore engine_connect(e, "bank1.sine1", "atten.in1");
    ignore engine_connect(e, "atten.out1", "lowpass.cv1");
    ignore engine_connect(e, "lowpass.out", "amp1.in1");
    ignore engine_connect(e, "env1.env", "amp1.cv1");
    ignore engine_connect(e, "amp1.out", "out.l");
    ignore engine_set(e, "bank1.oct1", 1.0f);
    ignore engine_set(e, "lowpass.cutoff", 1.0f);
    ignore engine_set(e, "lowpass.res", 0.3f);
    ignore engine_set(e, "lowpass.cv1_depth", 1.0f);
    ignore engine_set(e, "env1.sustain", 1.0f);
}

// A bank core a fifth up into an oscillator's pitch input: audio-rate FM.
void pitch_fm(Engine* e) {
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "keys.pitch", "bank1.pitch1");
    ignore engine_connect(e, "bank1.sine1", "atten.in1");
    ignore engine_connect(e, "atten.out1", "osc.pitch2");
    ignore engine_connect(e, "osc.tri", "amp1.in1");
    ignore engine_connect(e, "env1.env", "amp1.cv1");
    ignore engine_connect(e, "amp1.out", "out.l");
    ignore engine_set(e, "bank1.fine1", 7.0f / 12.0f);
    ignore engine_set(e, "env1.sustain", 1.0f);
}

// White noise into the cutoff of a resonant ladder playing a saw.
void noise_cutoff(Engine* e) {
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "osc.saw", "lowpass.in1");
    ignore engine_connect(e, "noise.white", "atten.in1");
    ignore engine_connect(e, "atten.out1", "lowpass.cv1");
    ignore engine_connect(e, "lowpass.out", "amp1.in1");
    ignore engine_connect(e, "env1.env", "amp1.cv1");
    ignore engine_connect(e, "amp1.out", "out.l");
    ignore engine_set(e, "lowpass.cutoff", 0.5f);
    ignore engine_set(e, "lowpass.res", 0.6f);
    ignore engine_set(e, "lowpass.cv1_depth", 1.0f);
    ignore engine_set(e, "env1.sustain", 1.0f);
}

// A bank core two octaves up into an amplifier's CV: amplitude modulation.
void amp_mod(Engine* e) {
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "keys.pitch", "bank1.pitch1");
    ignore engine_connect(e, "osc.saw", "amp1.in1");
    ignore engine_connect(e, "env1.env", "amp1.cv1");
    ignore engine_connect(e, "bank1.sine1", "atten.in1");
    ignore engine_connect(e, "atten.out1", "amp1.cv2");
    ignore engine_connect(e, "amp1.out", "out.l");
    ignore engine_set(e, "bank1.oct1", 2.0f);
    ignore engine_set(e, "bank1.fine1", 0.03f);
    ignore engine_set(e, "env1.sustain", 0.5f);
}

Patch[4] PATCHES = {
    Patch{ "1-filter-fm", "atten.gain1", 1.0f, filter_fm },
    Patch{ "2-pitch-fm", "atten.gain1", 1.0f, pitch_fm },
    Patch{ "3-noise-cutoff", "atten.gain1", 1.0f, noise_cutoff },
    Patch{ "4-amp-mod", "atten.gain1", 1.0f, amp_mod },
};

// One file: the patch in `profile`, the VINTAGE audio factor set first.
bool render(Patch* pt, i32 profile, f32 factor, str label, f32* buf) {
    PROFILE_SCALE[PROFILE_VINTAGE][CLS_AUDIO] = factor;
    Engine* e = engine_new_os(cast(f32, SR), 2);
    defer engine_free(e);
    rack_build(e);
    core_set_profile(&e.core, profile);
    pt.build(e);
    ignore engine_set(e, pt.depth, 0.0f);
    ignore engine_key_on(e, NOTE);
    i32 frames = SR * SECONDS;
    f32 peak = 0.0f;
    for i32 done = 0; done < frames; done += BLOCK {
        f32 t = cast(f32, done) / cast(f32, frames);
        ignore engine_set(e, pt.depth, t * pt.depth_max);
        engine_render(e, buf + done * 2, BLOCK, 2);
    }
    for i32 i = 0; i < frames * 2; i++ { if fabsf(buf[i]) > peak { peak = fabsf(buf[i]); } }
    string path = format("{}/{}-{}.wav", DIR, pt.name, label);
    defer free(path);
    bool ok = wav_write_format(str_from(path.data, path.len), buf, frames, 2, SR, WAV_PCM24);
    print("{}  peak {}\n", path, cast(f64, peak));
    return ok;
}

i32 main() {
    if !dir_create(DIR) {
        eprint("cannot create {}\n", DIR);
        return 1;
    }
    f32 start = PROFILE_SCALE[PROFILE_VINTAGE][CLS_AUDIO];
    f32* buf = alloc<f32>(SR * SECONDS * 2);
    defer free(buf);
    for i32 i = 0; i < 4; i++ {
        Patch* pt = &PATCHES[i];
        if !render(pt, PROFILE_MODERN, start, "a-modern-5v", buf) { return 1; }
        if !render(pt, PROFILE_VINTAGE, 1.0f, "b-vintage-1.0v", buf) { return 1; }
        if !render(pt, PROFILE_VINTAGE, 1.5f, "c-vintage-1.5v", buf) { return 1; }
        if !render(pt, PROFILE_VINTAGE, 2.5f, "d-vintage-2.5v", buf) { return 1; }
    }
    return 0;
}
