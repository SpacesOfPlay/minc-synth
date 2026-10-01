// test_modules.mc: each P2 module's behaviour, driven through the engine.

import math;
import "util/check.mc";
import "util/rig.mc";

void test_keys() {
    Engine* e = rig_new();
    defer engine_free(e);
    check(param(&e.core, engine_param_ref(e, "keys.priority")) == 1.0f, "KEYS defaults to low-note priority, as the classic keyboards");
    ignore engine_set(e, "keys.priority", 0.0f);
    ignore engine_key_on(e, 60);
    ignore rig_run(e, 480);
    check(rig_value(e, "keys.gate") == 1.0f, "KEYS gate is high while a key is held");
    check(fabsf(rig_value(e, "keys.pitch")) < 1e-5f, "C4 is 0 V");

    ignore engine_key_on(e, 64);
    ignore rig_run(e, 480);
    check(fabsf(rig_value(e, "keys.pitch") - 4.0f / 12.0f) < 1e-4f, "last-note priority plays the newest key");
    ignore engine_set(e, "keys.priority", 1.0f);
    ignore rig_run(e, 480);
    check(fabsf(rig_value(e, "keys.pitch")) < 1e-4f, "low-note priority plays the lowest key");
    ignore engine_set(e, "keys.priority", 2.0f);
    ignore rig_run(e, 480);
    check(fabsf(rig_value(e, "keys.pitch") - 4.0f / 12.0f) < 1e-4f, "high-note priority plays the highest key");

    ignore engine_set(e, "keys.priority", 0.0f);
    ignore engine_key_off(e, 64);
    ignore rig_run(e, 480);
    check(fabsf(rig_value(e, "keys.pitch")) < 1e-4f, "releasing the newest key falls back to the held one");
    ignore engine_key_off(e, 60);
    ignore rig_run(e, 480);
    check(rig_value(e, "keys.gate") == 0.0f, "gate falls when every key is up");

    // A new key fires a 2 ms trigger.
    ignore engine_key_on(e, 67);
    i32 high = 0;
    for i32 i = 0; i < 480; i++ {
        ignore rig_run(e, 1);
        if rig_value(e, "keys.trig") == 1.0f { high++; }
    }
    check(high == cast(i32, TRIG_S * RIG_SR), "trig is a 2 ms pulse");

    // Glide: halfway there well before the glide time is up.
    ignore engine_set(e, "keys.glide", 0.2f);
    ignore rig_run(e, 9600);
    ignore engine_key_on(e, 79);                    // +1 octave from G4
    ignore rig_run(e, 1200);                        // 25 ms
    f32 mid = rig_value(e, "keys.pitch");
    ignore rig_run(e, 24000);
    f32 end = rig_value(e, "keys.pitch");
    check(mid > 7.0f / 12.0f + 0.2f && mid < 19.0f / 12.0f - 0.05f, "glide slews between notes");
    check(fabsf(end - 19.0f / 12.0f) < 1e-3f, "glide arrives");
}

void test_osc() {
    // A4 from KEYS plays 440 Hz.
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_key_on(e, 69);
    ignore rig_run(e, 4800);
    i32 n = 48000;
    f32* buf = alloc<f32>(n);
    defer free(buf);
    for i32 i = 0; i < n; i++ {
        ignore rig_run(e, 1);
        buf[i] = rig_value(e, "osc.sine");
    }
    f64 hz = measure_freq(buf, n, RIG_SR);
    print("OSC from KEYS A4: {} Hz\n", hz);
    check(fabs(cents(hz, 440.0)) < 0.1, "KEYS A4 into OSC plays 440 Hz");

    ignore engine_set(e, "osc.octave", -1.0f);
    ignore rig_run(e, 4800);
    for i32 i = 0; i < n; i++ {
        ignore rig_run(e, 1);
        buf[i] = rig_value(e, "osc.sine");
    }
    check(fabs(cents(measure_freq(buf, n, RIG_SR), 220.0)) < 0.1, "the octave switch drops an octave");
}

void test_amp() {
    check(amp_gain(0.5f, AMP_LIN) == 0.5f, "LIN gain follows the control");
    check(fabsf(amp_gain(1.0f, AMP_EXP) - 1.0f) < 1e-5f, "EXP gain is unity at full control");
    f32 half = amp_gain(0.5f, AMP_EXP);
    check(fabs(db(cast(f64, half)) + 35.0) < 0.1, "EXP gain is dB-linear: half control is -35 dB");
    check(amp_gain(0.0f, AMP_EXP) == 0.0f, "EXP gain closes at 0");
    check(amp_gain(-1.0f, AMP_LIN) == 0.0f && amp_gain(9.0f, AMP_LIN) == AMP_MAX_GAIN, "control clamps");

    // A gate into the CV input opens the amp: 10 V is full gain in MODERN.
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "amp1.in1");       // +1 V steady: 0.2 audio
    ignore engine_connect(e, "keys.gate", "amp1.cv1");
    ignore engine_key_on(e, 72);
    ignore rig_run(e, 4800);
    check(fabsf(rig_value(e, "amp1.out") - AMP_SAT * tanh_fast(0.2f / AMP_SAT)) < 1e-5f, "the gate opens the amp fully");
    check(rig_value(e, "amp1.inv") == -rig_value(e, "amp1.out"), "INV is the negated output");
}

void test_env_normal() {
    // No gate cable: ENV follows KEYS through the normal.
    Engine* e = rig_new();
    defer engine_free(e);
    ignore rig_run(e, 480);
    check(rig_value(e, "env1.env") == 0.0f, "ENV rests at 0");
    ignore engine_key_on(e, 60);
    ignore rig_run(e, 4800);
    f32 held = rig_value(e, "env1.env");
    check(held > 0.5f, "the KEYS gate reaches ENV through its normal");
    ignore engine_key_off(e, 60);
    ignore rig_run(e, 96000);
    check(rig_value(e, "env1.env") == 0.0f, "ENV returns to 0 after the release");

    // A patched gate overrides the normal.
    ignore engine_connect(e, "noise.stepped", "env2.gate");
    ignore engine_key_on(e, 60);
    ignore rig_run(e, 480);
    check(rig_jack(e, "env2.gate").n_src == 1, "a gate cable replaces the normal");
}

void test_noise() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_set(e, "noise.rate", 10.0f);
    ignore rig_run(e, 4800);
    i32 changes = 0;
    f32 last = rig_value(e, "noise.stepped");
    for i32 i = 0; i < 48000; i++ {
        ignore rig_run(e, 1);
        f32 v = rig_value(e, "noise.stepped");
        if v != last { changes++; }
        last = v;
    }
    print("NOISE S&H at 10 Hz: {} steps in 1 s\n", changes);
    check(changes >= 9 && changes <= 11, "the S&H clock runs at its rate");

    // An external clock takes over: KEYS trig steps it once per key.
    ignore engine_connect(e, "keys.trig", "noise.clock");
    ignore rig_run(e, 4800);
    changes = 0;
    last = rig_value(e, "noise.stepped");
    for i32 k = 0; k < 5; k++ {
        ignore engine_key_on(e, 60 + k);
        for i32 i = 0; i < 2400; i++ {
            ignore rig_run(e, 1);
            f32 v = rig_value(e, "noise.stepped");
            if v != last { changes++; }
            last = v;
        }
    }
    check(changes == 5, "a patched clock steps the S&H on each rising edge");
}

void test_mix_out() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "mix1.in1");
    ignore engine_connect(e, "keys.pitch", "mix1.in3");
    ignore engine_set(e, "mix1.level1", 0.5f);
    ignore engine_set(e, "mix1.level3", 0.25f);
    ignore engine_key_on(e, 72);
    ignore rig_run(e, 48000);
    check(fabsf(rig_value(e, "mix1.out") - 0.2f * 0.75f) < 1e-5f, "MIX sums its inputs by level");

    // OUT: one patched input plays on both sides; loud input stays under full scale.
    ignore engine_connect(e, "osc.saw", "amp1.in1");
    ignore engine_set(e, "amp1.gain", 1.0f);
    ignore engine_connect(e, "amp1.out", "out.r");
    ignore engine_set(e, "out.master", 1.0f);
    ignore engine_set(e, "out.level_r", 1.0f);
    ignore rig_run(e, 4800);
    bool same = true;
    f32 peak = 0.0f;
    for i32 n = 0; n < 20; n++ {
        engine_render(e, &g_rig_frames[0], RIG_BLOCK, 2);
        for i32 i = 0; i < RIG_BLOCK; i++ {
            if g_rig_frames[2 * i] != g_rig_frames[2 * i + 1] { same = false; }
            if fabsf(g_rig_frames[2 * i]) > peak { peak = fabsf(g_rig_frames[2 * i]); }
        }
    }
    check(same, "a single OUT input plays on both channels");
    check(peak > 0.3f && peak <= 1.0f, "OUT stays within full scale");
    check(fabsf(soft_limit(0.5f) - 0.5f) < 1e-6f && soft_limit(10.0f) <= 1.0f, "the limiter is transparent below the knee");
}

i32 main() {
    test_keys();
    test_osc();
    test_amp();
    test_env_normal();
    test_noise();
    test_mix_out();
    return check_done();
}
