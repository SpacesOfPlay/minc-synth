// test_poly.mc: voices. KEYS hands each key a voice, cables carry the
// voices, the voiced modules run one circuit per voice, and OUT plays
// them all. A mono KEYS is the same as before.

import math;
import "util/check.mc";
import "util/rig.mc";

// A poly voice: KEYS -> OSC -> LOWPASS -> AMP <- ENV1 (its gate follows
// KEYS) -> OUT.
Engine* poly_rig(i32 voices) {
    Engine* e = rig_new();
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "osc.saw", "lowpass.in1");
    ignore engine_connect(e, "lowpass.out", "amp1.in1");
    ignore engine_connect(e, "env1.env", "amp1.cv1");
    ignore engine_connect(e, "amp1.out", "out.l");
    ignore engine_set(e, "keys.voices", cast(f32, voices));
    ignore engine_set(e, "lowpass.cutoff", 4.0f);
    ignore engine_set(e, "env1.attack", 0.001f);
    ignore engine_set(e, "env1.sustain", 1.0f);
    ignore engine_set(e, "env1.release", 0.01f);
    rig_settle(e);
    return e;
}

i32 channels_of(Engine* e, str ref) { return slot_channels(&e.core, engine_output_ref(e, ref)); }

// Channel v of an output, in volts.
f32 slot_volts(Engine* e, str ref, i32 v) {
    return slot_voice(&e.core, engine_output_ref(e, ref), v);
}

f64 hz(i32 note) { return 440.0 * pow(2.0, cast(f64, note - 69) / 12.0); }

void test_keys() {
    Engine* e = poly_rig(4);
    defer engine_free(e);
    ignore engine_key_on(e, 60);
    ignore engine_key_on(e, 64);
    ignore engine_key_on(e, 67);
    ignore rig_run(e, 480);
    check(channels_of(e, "keys.pitch") == 4 && channels_of(e, "keys.gate") == 4, "four voices: pitch and gate carry four channels");
    i32 gates = 0;
    bool[3] found = { false, false, false };
    i32[3] notes = { 60, 64, 67 };
    for i32 v = 0; v < 4; v++ {
        if slot_volts(e, "keys.gate", v) > 0.5f {
            gates++;
            f32 volts = slot_volts(e, "keys.pitch", v);
            for i32 i = 0; i < 3; i++ { if fabsf(volts - cast(f32, notes[i] - 60) / 12.0f) < 1e-4f { found[i] = true; } }
        }
    }
    check(gates == 3 && found[0] && found[1] && found[2], "three keys, three voices open, each at its own pitch");

    ignore engine_key_off(e, 64);
    ignore rig_run(e, 480);
    gates = 0;
    for i32 v = 0; v < 4; v++ { if slot_volts(e, "keys.gate", v) > 0.5f { gates++; } }
    check(gates == 2, "releasing a key closes its voice only");

    // Two more keys: the free voice first (the released one), then a steal.
    ignore engine_key_on(e, 71);
    ignore engine_key_on(e, 72);
    ignore engine_key_on(e, 74);
    ignore rig_run(e, 480);
    gates = 0;
    bool oldest_gone = true;
    for i32 v = 0; v < 4; v++ {
        if slot_volts(e, "keys.gate", v) > 0.5f {
            gates++;
            if fabsf(slot_volts(e, "keys.pitch", v)) < 1e-4f { oldest_gone = false; }      // C4, held longest
        }
    }
    check(gates == 4 && oldest_gone, "past four keys the one held longest gives up its voice");

    check(channels_of(e, "env1.env") == 4, "ENV1 follows the KEYS gate's voices through its normal");
    check(channels_of(e, "amp1.out") == 4, "the voices reach AMP");
}

void test_chord() {
    // C E G held: each fundamental is in the output. Mono plays only the last.
    for i32 pass = 0; pass < 2; pass++ {
        i32 voices = pass == 0 ? 4 : 1;
        Engine* e = poly_rig(voices);
        defer engine_free(e);
        ignore engine_key_on(e, 48);
        ignore engine_key_on(e, 52);
        ignore engine_key_on(e, 55);
        ignore rig_run(e, 9600);
        i32 n = 48000;
        f32* buf = alloc<f32>(n * 2);
        defer free(buf);
        engine_render(e, buf, n, 2);
        f32* mono = alloc<f32>(n);
        defer free(mono);
        for i32 i = 0; i < n; i++ { mono[i] = buf[i * 2]; }
        f64 c3 = tone_amplitude(mono, n, hz(48), RIG_SR);
        f64 e3 = tone_amplitude(mono, n, hz(52), RIG_SR);
        f64 g3 = tone_amplitude(mono, n, hz(55), RIG_SR);
        print("{} voice(s), C E G held: C3 {}, E3 {}, G3 {}\n", voices, c3, e3, g3);
        if voices == 4 {
            check(c3 > 0.02 && e3 > 0.02 && g3 > 0.02, "four voices: all three notes sound");
            check(c3 / g3 > 0.5 && c3 / g3 < 2.0, "at about the same level");
        } else {
            check(c3 > 0.02 && e3 < 0.1 * c3 && g3 < 0.1 * c3, "one voice: only the lowest key sounds (low-note priority)");
        }
    }
}

void test_mono_into_poly() {
    // A poly pitch into OSC and a mono cutoff CV: every voice gets the CV.
    Engine* e = poly_rig(3);
    defer engine_free(e);
    ignore engine_connect(e, "noise.smooth", "lowpass.cv2");
    ignore engine_key_on(e, 60);
    ignore engine_key_on(e, 67);
    ignore rig_run(e, 480);
    check(channels_of(e, "lowpass.out") == 3, "a mono CV into a poly filter: the filter keeps the voices");
    check(jack_channels(&e.core, engine_input_ref(e, "lowpass.cv2")) == 1, "the CV input itself is mono");
    // A mono module reads voice 0 of a poly cable.
    ignore engine_connect(e, "osc.saw", "band.in");
    ignore rig_run(e, 480);
    check(channels_of(e, "band.bp") == 1, "BAND stays mono and sums the voices at its input");
}

void test_back_to_mono() {
    Engine* e = poly_rig(4);
    defer engine_free(e);
    ignore engine_key_on(e, 60);
    ignore rig_run(e, 480);
    ignore engine_set(e, "keys.voices", 1.0f);
    ignore rig_run(e, 480);
    check(channels_of(e, "keys.pitch") == 1 && channels_of(e, "osc.saw") == 1 && channels_of(e, "amp1.out") == 1,
          "VOICES back to 1: every cable in the chain is mono again");
    check(fabsf(rig_value(e, "keys.pitch")) < 1e-4f && rig_value(e, "keys.gate") > 0.5f, "and KEYS plays the held key");
}

i32 main() {
    test_keys();
    test_chord();
    test_mono_into_poly();
    test_back_to_mono();
    return check_done();
}
