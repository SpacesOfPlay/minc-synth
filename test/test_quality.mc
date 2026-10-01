// test_quality.mc: the engine at 2x and 4x the device rate.

import math;
import "util/check.mc";
import "util/rig.mc";

const i32 DEVICE_SR = 48000;

// Device-rate left channel of `seconds` of the engine's output.
f32* render_left(Engine* e, f64 seconds, i32* count) {
    i32 n = cast(i32, seconds * cast(f64, DEVICE_SR));
    f32* buf = alloc<f32>(n);
    i32 done = 0;
    while done < n {
        i32 k = RIG_BLOCK;
        if n - done < k { k = n - done; }
        engine_render(e, &g_rig_frames[0], k, 2);
        for i32 i = 0; i < k; i++ { buf[done + i] = g_rig_frames[2 * i]; }
        done += k;
    }
    *count = n;
    return buf;
}

// OSC sine straight to OUT, at a note plus octaves.
Engine* tone_engine(i32 os, i32 note, f32 octave) {
    Engine* e = engine_new_os(cast(f32, DEVICE_SR), os);
    rack_build(e);
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "osc.sine", "out.l");
    ignore engine_set(e, "osc.octave", octave);
    ignore engine_key_on(e, note);
    rig_settle(e);
    ignore engine_key_on(e, note);
    return e;
}

void test_tone() {
    // A5 at 1x, 2x and 4x: the same pitch and level at the device.
    f64[3] level;
    f64[3] hz;
    i32[3] oss = { 1, 2, 4 };
    for i32 k = 0; k < 3; k++ {
        Engine* e = tone_engine(oss[k], 81, 0.0f);
        i32 n = 0;
        f32* skip = render_left(e, 0.1, &n);
        free(skip);
        f32* buf = render_left(e, 1.0, &n);
        hz[k] = measure_freq(buf, n, cast(f64, DEVICE_SR));
        level[k] = rms(buf, n);
        free(buf);
        engine_free(e);
    }
    print("A5 at 1x / 2x / 4x: {} / {} / {} Hz, RMS {} / {} / {}\n", hz[0], hz[1], hz[2], level[0], level[1], level[2]);
    for i32 k = 0; k < 3; k++ {
        check(fabs(cents(hz[k], 880.0)) < 0.1, "A5 plays 880 Hz at every engine rate");
        check(fabs(db(level[k] / level[0])) < 0.05, "the level doesn't depend on the engine rate");
    }
}

// A pure tone at the engine rate through the output decimator; returns
// the device-rate amplitude at `want` Hz (where it lands, folded or not).
f64 through_decimator(i32 os, f64 hz, f64 want) {
    Halfband[2] d;
    halfband_design();
    f64 rate = cast(f64, DEVICE_SR * os);
    i32 n = DEVICE_SR;
    f32* out = alloc<f32>(n);
    defer free(out);
    f32[4] x;
    for i32 i = 0; i < n; i++ {
        for i32 s = 0; s < os; s++ {
            f64 t = cast(f64, i * os + s) / rate;
            x[s] = cast(f32, sin(2.0 * 3.141592653589793 * hz * t));
        }
        out[i] = engine_decimate(&d[0], os, &x[0]);
    }
    return tone_amplitude(&out[4800], n - 4800, want, cast(f64, DEVICE_SR));
}

void test_decimation() {
    for i32 os = 2; os <= 4; os += 2 {
        f64 pass = through_decimator(os, 1000.0, 1000.0);
        f64 top = through_decimator(os, 18000.0, 18000.0);
        f64 folded = through_decimator(os, 30000.0, 18000.0);     // 30 kHz folds to 18 kHz
        print("{}x decimator: 1 kHz {} dB, 18 kHz {} dB, 30 kHz folds in at {} dB\n",
              os, db(pass), db(top), db(folded));
        check(fabs(db(pass)) < 0.01 && fabs(db(top)) < 0.01, "the decimator passes the audio band flat");
        check(db(folded) < -100.0, "the decimator stops ultrasonic content folding back");
    }
}

void test_default_patch() {
    for i32 os = 2; os <= 4; os += 2 {
        Engine* e = engine_new_os(cast(f32, DEVICE_SR), os);
        rack_build(e);
        rack_default_patch(e);
        ignore engine_key_on(e, 48);
        f32 peak = rig_run(e, 24000);
        check(e.core.sample_rate == cast(f32, DEVICE_SR * os), "the engine runs at the device rate times os");
        check(peak > 0.05f && peak <= 1.0f && peak == peak, "the default patch plays at 2x and 4x");
        engine_free(e);
    }
}

void test_copy_patch() {
    Engine* a = rig_new();
    defer engine_free(a);
    rack_default_patch(a);
    ignore engine_set(a, "lowpass.res", 0.83f);
    ignore engine_send_kind(a, CMD_PROFILE, PROFILE_VINTAGE, 0, 0.0f);
    ignore engine_key_on(a, 55);
    ignore rig_run(a, 4800);
    ignore engine_send_kind(a, CMD_LOAD_BEGIN, 0, 0, 0.0f);
    ignore rig_run(a, 2048);
    check(a.tele.silent == 1, "LOAD_BEGIN holds the old engine at silence");

    Engine* b = engine_new_os(48000.0f, 4);
    defer engine_free(b);
    rack_build(b);
    engine_copy_patch(b, a);
    i32 res = engine_param_ref(b, "lowpass.res");
    check(fabsf(param(&b.core, res) - 0.83f) < 1e-5f, "copy carries knob values");
    check(rig_jack(b, "amp1.cv1").n_src == 1, "copy carries cables");
    check(b.core.profile == PROFILE_VINTAGE, "copy carries the profile");
    check(b.keys[0].n_held == 1 && b.keys[0].note == 55, "copy carries held keys");
    check(rig_run(b, 9600) > 0.05f, "the copy plays at its new rate");
}

i32 main() {
    test_tone();
    test_decimation();
    test_default_patch();
    test_copy_patch();
    return check_done();
}
