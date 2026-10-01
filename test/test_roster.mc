// test_roster.mc: the P4 modules' behaviour, driven through the engine,
// and the whole rack patched in both profiles.

import math;
import "util/check.mc";
import "util/rig.mc";

const i32 SEC = 48000;

f32* g_x;
f32* g_y;

// Renders n frames one at a time, recording two outputs (canonical).
void record2(Engine* e, str a, str b, i32 n) {
    for i32 i = 0; i < n; i++ {
        ignore rig_run(e, 1);
        g_x[i] = rig_value(e, a);
        g_y[i] = rig_value(e, b);
    }
}

// Frames until `ref` goes high, at most `limit`; -1 if it doesn't.
i32 frames_until_high(Engine* e, str ref, i32 limit) {
    for i32 i = 1; i <= limit; i++ {
        ignore rig_run(e, 1);
        if rig_value(e, ref) >= 0.5f { return i; }
    }
    return -1;
}

void set_profile(Engine* e, i32 profile) { ignore engine_send_kind(e, CMD_PROFILE, profile, 0, 0.0f); }

// ---- OSC: through-zero FM ----

void test_osc_fm() {
    Engine* e = rig_new();
    defer engine_free(e);
    // Index 2 from a C3 modulator swings the C4 carrier through 0 Hz and back.
    ignore engine_set(e, "bank1.freq", -1.0f);
    ignore engine_connect(e, "bank1.sine1", "osc.fm");
    ignore engine_set(e, "osc.fm", 2.0f);
    rig_settle(e);
    ignore rig_run(e, 4800);
    f64 last = e.osc[0].v.phase;
    f64 total = 0.0;
    f64 back = 0.0;
    for i32 i = 0; i < SEC; i++ {
        ignore rig_run(e, 1);
        f64 d = e.osc[0].v.phase - last;
        if d > 0.5 { d -= 1.0; }
        if d < -0.5 { d += 1.0; }
        total += d;
        if d < back { back = d; }
        last = e.osc[0].v.phase;
    }
    f64 hz = total * cast(f64, RIG_SR) / cast(f64, SEC);
    print("OSC through-zero FM, index 2: mean {} Hz\n", hz);
    check(back < 0.0, "deep FM runs the phase backwards");
    check(fabs(cents(hz, 261.6256)) < 5.0, "through-zero FM keeps the carrier's pitch centre");
}

// ---- OSC BANK ----

void test_bank() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "bank1.pitch1");
    ignore engine_set(e, "bank1.oct2", 1.0f);
    ignore engine_set(e, "bank1.oct3", -1.0f);
    ignore engine_set(e, "bank1.fine3", 1.0f / 12.0f);
    ignore engine_set(e, "bank1.width", 0.25f);
    ignore engine_key_on(e, 69);
    rig_settle(e);
    ignore rig_run(e, 4800);
    record2(e, "bank1.sine1", "bank1.sine2", SEC);
    f64 f1 = measure_freq(g_x, SEC, RIG_SR);
    f64 f2 = measure_freq(g_y, SEC, RIG_SR);
    record2(e, "bank1.sine3", "bank1.pulse1", SEC);
    f64 f3 = measure_freq(g_x, SEC, RIG_SR);
    f64 duty = mean(g_y, SEC);
    print("BANK from A4: cores {} {} {} Hz, pulse mean {}\n", f1, f2, f3, duty);
    check(fabs(cents(f1, 440.0)) < 0.1, "core 1 plays the driver's pitch");
    check(fabs(cents(f2, 880.0)) < 0.1, "core 2's octave switch adds an octave");
    check(fabs(cents(f3, 220.0 * pow(2.0, 1.0 / 12.0))) < 0.1, "core 3: an octave down and a semitone of fine");
    check(fabs(duty + 0.5) < 0.01, "WIDTH sets every core's pulse");

    // Core 1 of the second bank, synced to OSC: its tone sits on OSC's harmonics.
    ignore engine_connect(e, "osc.saw", "bank2.sync1");
    ignore engine_set(e, "bank2.freq", 0.5f);                  // free: 370 Hz
    rig_settle(e);
    ignore rig_run(e, 4800);
    record2(e, "bank2.saw1", "osc.saw", SEC);
    f64 at_master = tone_amplitude(g_x, SEC, 261.6256, RIG_SR);
    f64 at_free = tone_amplitude(g_x, SEC, 369.9944, RIG_SR);
    print("BANK synced: {} at the master, {} at its own pitch\n", at_master, at_free);
    check(at_master > 0.2 && at_free < 0.01, "a synced core repeats with its master");
}

// ---- SEQUENCER ----

// Row A's value at each of the next `n` clocks.
i32 seq_steps(Engine* e, f32* vals, i32 n, i32 limit) {
    i32 got = 0;
    f32 was = rig_value(e, "seq.clock");
    for i32 i = 0; i < limit && got < n; i++ {
        ignore rig_run(e, 1);
        f32 c = rig_value(e, "seq.clock");
        if c >= 0.5f && was < 0.5f {
            vals[got] = rig_value(e, "seq.a");
            got++;
        }
        was = c;
    }
    return got;
}

// Step numbers (1-based) from row A values set to step / 8.
bool seq_is(f32* vals, i32 n, i32* want) {
    for i32 i = 0; i < n; i++ {
        if fabsf(vals[i] * 8.0f - cast(f32, want[i])) > 1e-4f { return false; }
    }
    return true;
}

Engine* seq_engine() {
    Engine* e = rig_new();
    for i32 s = 0; s < 8; s++ {
        string ref = format("seq.a{}", s + 1);
        ignore engine_set(e, str_from(ref.data, ref.len), cast(f32, s + 1) / 8.0f);
        free(ref);
    }
    ignore engine_set(e, "seq.rate", 50.0f);                   // 960 frames a step
    rig_settle(e);
    return e;
}

void test_seq() {
    f32[16] v;
    Engine* e = seq_engine();
    i32 n = seq_steps(e, &v[0], 10, 20 * SEC);
    i32[10] all = { 1, 2, 3, 4, 5, 6, 7, 8, 1, 2 };
    check(n == 10 && seq_is(&v[0], 10, &all[0]), "the internal clock plays steps 1 to 8 and around");
    check(tele_state(&e.tele, engine_module(e, "seq")) == 1, "telemetry shows the sounding step");

    ignore engine_set(e, "seq.steps", 4.0f);
    ignore engine_set(e, "seq.mode3", 1.0f);                   // skip
    rig_snap_params(e);
    n = seq_steps(e, &v[0], 7, 20 * SEC);
    // From step 2: 4, 1, 2, 4, 1, 2, 4.
    i32[7] short = { 4, 1, 2, 4, 1, 2, 4 };
    check(n == 7 && seq_is(&v[0], 7, &short[0]), "STEPS shortens the sequence; a SKIP step is passed over");
    engine_free(e);

    // A STOP step halts the internal clock; a reset starts over from step 1.
    e = seq_engine();
    ignore engine_set(e, "seq.mode3", 2.0f);
    ignore engine_connect(e, "keys.trig", "seq.reset");
    ignore rig_run(e, 1);
    n = seq_steps(e, &v[0], 4, 5 * 960);
    check(n == 3 && fabsf(v[2] * 8.0f - 3.0f) < 1e-4f, "the sequence halts on a STOP step");
    ignore engine_key_on(e, 60);
    n = seq_steps(e, &v[0], 2, 5 * 960);
    check(n == 2 && fabsf(v[0] * 8.0f - 1.0f) < 1e-4f && fabsf(v[1] * 8.0f - 2.0f) < 1e-4f,
          "a reset clears the halt and the next clock plays step 1");
    engine_free(e);

    // An external clock: one step per KEYS trigger.
    e = seq_engine();
    ignore engine_connect(e, "keys.trig", "seq.clock");
    ignore rig_run(e, 2 * 960);
    f32 before = rig_value(e, "seq.a");
    ignore rig_run(e, 5 * 960);
    check(rig_value(e, "seq.a") == before, "a patched clock stops the internal one");
    i32 moved = 0;
    for i32 k = 0; k < 3; k++ {
        ignore engine_key_on(e, 60 + k);
        ignore rig_run(e, 480);
        moved++;
    }
    check(fabsf(rig_value(e, "seq.a") * 8.0f - 3.0f) < 1e-4f && moved == 3, "each clock edge moves one step");
    engine_free(e);

    // Gate length, step triggers, ranges and the quantizer.
    e = seq_engine();
    ignore engine_set(e, "seq.length", 0.25f);
    ignore engine_set(e, "seq.range_b", 2.0f);                 // 5 V
    ignore engine_set(e, "seq.b1", 1.0f);
    ignore engine_set(e, "seq.range_c", 0.0f);                 // 1 V
    ignore engine_set(e, "seq.c1", 0.49f);
    ignore engine_set(e, "seq.quant_c", 1.0f);
    rig_settle(e);
    ignore seq_steps(e, &v[0], 1, 2 * 960);                    // step 1 just played
    i32 high = 0;
    i32 trig2 = -1;
    for i32 i = 1; i <= 1000; i++ {
        ignore rig_run(e, 1);
        if i <= 960 && rig_value(e, "seq.gate") >= 0.5f { high++; }
        if trig2 < 0 && rig_value(e, "seq.step2") >= 0.5f { trig2 = i; }
    }
    print("SEQUENCER: gate {} of 960 frames; step 2 fired {} frames after step 1\n", high, trig2);
    check(high >= 238 && high <= 242, "GATE lasts LENGTH of the clock period");
    check(trig2 >= 959 && trig2 <= 961, "each step fires its own trigger");
    ignore rig_run(e, 7 * 960);                                // around to step 1
    check(fabsf(rig_volts(e, "seq.b") - 5.0f) < 1e-4f, "a 5 V range gives 5 V at the top of the knob");
    check(fabsf(rig_volts(e, "seq.c") - 0.5f) < 1e-5f, "the quantizer rounds to the nearest semitone");
    engine_free(e);
}

// ---- HIGHPASS, BAND, SPECTRUM ----

// Gain of `out` against `in` at hz, in dB, after settling.
f64 gain_db(Engine* e, str in, str out, f64 hz) {
    ignore rig_run(e, 9600);
    i32 n = SEC / 2;
    record2(e, in, out, n);
    return db(tone_amplitude(g_y, n, hz, RIG_SR) / tone_amplitude(g_x, n, hz, RIG_SR));
}

void test_highpass() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "osc.sine", "highpass.in1");
    ignore engine_key_on(e, 69);
    ignore engine_set(e, "highpass.cutoff", -4.7f);
    rig_settle(e);
    f64 pass = gain_db(e, "osc.sine", "highpass.out", 440.0);
    ignore engine_set(e, "highpass.cutoff", 0.75f);            // A4
    f64 at = gain_db(e, "osc.sine", "highpass.out", 440.0) - pass;
    ignore engine_set(e, "highpass.cutoff", 1.75f);            // an octave above
    f64 below = gain_db(e, "osc.sine", "highpass.out", 440.0) - pass;
    print("HIGHPASS: {} dB at the cutoff, {} dB an octave below it\n", at, below);
    check(fabs(at + 12.04) < 0.1, "four poles: -12 dB at the cutoff");
    check(fabs(below + 27.96) < 0.3, "an octave below: -28 dB");
}

void test_band() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "osc.sine", "atten.in1");
    ignore engine_set(e, "atten.gain1", 0.2f);                 // well under the saturation
    ignore engine_connect(e, "atten.out1", "band.in");
    ignore engine_key_on(e, 69);
    ignore engine_set(e, "band.center", 0.75f);
    ignore engine_set(e, "band.width", 1.0f);
    rig_settle(e);
    f64 bp = gain_db(e, "atten.out1", "band.bp", 440.0);
    f64 br = gain_db(e, "atten.out1", "band.br", 440.0);
    ignore engine_set(e, "band.center", 3.75f);                // three octaves up
    f64 br_far = gain_db(e, "atten.out1", "band.br", 440.0);
    f64 bp_far = gain_db(e, "atten.out1", "band.bp", 440.0);
    print("BAND at the centre: BP {} dB, BR {} dB; 3 octaves off: BP {} dB, BR {} dB\n", bp, br, bp_far, br_far);
    check(fabs(bp) < 0.3, "BP passes its centre at unity");
    check(fabs(br + 15.25) < 0.5, "BR notches its centre (-15 dB at one octave wide)");
    // BR there is the low-pass 2.5 octaves under its corner: -40 log10(1 + 2^-5) dB.
    check(bp_far < -40.0 && fabs(br_far + 0.534) < 0.05, "far from the centre BP rejects and BR passes");
}

void test_spectrum() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "offsets.out1", "osc.pitch1");
    ignore engine_connect(e, "osc.sine", "spectrum.in");
    rig_settle(e);
    f64 lo = 1e9;
    f64 hi = -1e9;
    i32 points = 24;
    for i32 i = 0; i < points; i++ {
        f64 hz = 40.0 * pow(12000.0 / 40.0, cast(f64, i) / cast(f64, points - 1));
        f64 volts = log(hz / 261.6255653005986) / log(2.0);
        ignore engine_set(e, "offsets.coarse1", cast(f32, volts));
        ignore rig_run(e, 1);
        e.core.params[engine_param_ref(e, "offsets.coarse1")].norm = e.core.params[engine_param_ref(e, "offsets.coarse1")].target;
        e.core.params[engine_param_ref(e, "offsets.coarse1")].value = cast(f32, volts);
        f64 g = gain_db(e, "osc.sine", "spectrum.out", hz);
        if g < lo { lo = g; }
        if g > hi { hi = g; }
    }
    print("SPECTRUM, every band up, 40 Hz..12 kHz: {} .. {} dB\n", lo, hi);
    check(hi - lo < 2.9 && lo > -1.6 && hi < 1.6, "the bands sum flat within +-1.5 dB");

    // The 1 kHz band down: a deep dip there.
    ignore engine_set(e, "offsets.coarse1", cast(f32, log(1000.0 / 261.6255653005986) / log(2.0)));
    rig_settle(e);
    f64 up = gain_db(e, "osc.sine", "spectrum.out", 1000.0);
    ignore engine_set(e, "spectrum.1k", 0.0f);
    rig_settle(e);
    f64 cut = gain_db(e, "osc.sine", "spectrum.out", 1000.0) - up;
    print("SPECTRUM, the 1 kHz band down: {} dB there\n", cut);
    check(cut < -12.0, "one band down cuts deep at its centre");
}

// ---- TRIG DELAY, STEP SWITCH, GATES ----

void test_delay() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.trig", "delay.in1");
    ignore engine_set(e, "delay.time1", 0.1f);
    ignore engine_set(e, "delay.time2", 0.05f);
    rig_settle(e);
    ignore engine_key_on(e, 60);
    i32 t = frames_until_high(e, "delay.out1", SEC);
    print("TRIG DELAY: 0.1 s came after {} frames\n", t);
    check(t >= 4800 && t <= 4803, "a trigger comes out TIME after the input's edge");
    ignore engine_set(e, "delay.fire2", 1.0f);
    t = frames_until_high(e, "delay.out2", SEC);
    ignore engine_set(e, "delay.fire2", 0.0f);
    check(t >= 2400 && t <= 2403, "the FIRE button starts the wait too");
}

void test_stepsw() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_set(e, "offsets.coarse1", 1.0f);
    ignore engine_set(e, "offsets.coarse2", 2.0f);
    ignore engine_set(e, "offsets.coarse3", 3.0f);
    ignore engine_set(e, "offsets.coarse4", 4.0f);
    ignore engine_connect(e, "offsets.out1", "stepsw.a");
    ignore engine_connect(e, "offsets.out2", "stepsw.b");
    ignore engine_connect(e, "offsets.out3", "stepsw.c");
    ignore engine_connect(e, "offsets.out4", "stepsw.in");
    ignore engine_connect(e, "keys.trig", "stepsw.shift");
    ignore engine_connect(e, "gates.b1", "stepsw.reset");
    rig_settle(e);
    ignore rig_run(e, 480);
    i32 m = engine_module(e, "stepsw");
    bool ok = fabsf(rig_volts(e, "stepsw.out") - 1.0f) < 1e-5f && fabsf(rig_volts(e, "stepsw.a") - 4.0f) < 1e-5f
           && rig_volts(e, "stepsw.b") == 0.0f;
    f32[3] want = { 2.0f, 3.0f, 1.0f };
    for i32 k = 0; k < 3; k++ {
        ignore engine_key_on(e, 60 + k);
        ignore rig_run(e, 480);
        if fabsf(rig_volts(e, "stepsw.out") - want[k]) > 1e-5f { ok = false; }
    }
    check(ok, "each SHIFT moves the switch on a stage, around after the third");
    ignore engine_key_on(e, 70);
    ignore rig_run(e, 480);
    check(tele_state(&e.tele, m) == 1 && fabsf(rig_volts(e, "stepsw.b") - 4.0f) < 1e-5f && rig_volts(e, "stepsw.a") == 0.0f,
          "IN goes to the current stage's output only");
    ignore engine_set(e, "gates.button1", 1.0f);
    ignore rig_run(e, 480);
    ignore engine_set(e, "gates.button1", 0.0f);
    check(fabsf(rig_volts(e, "stepsw.out") - 1.0f) < 1e-5f, "RESET returns to the first stage");
    ignore engine_set(e, "stepsw.stages", 2.0f);
    ignore engine_key_on(e, 71);
    ignore rig_run(e, 480);
    ignore engine_key_on(e, 72);
    ignore rig_run(e, 480);
    check(fabsf(rig_volts(e, "stepsw.out") - 1.0f) < 1e-5f, "with two stages it goes around after the second");
}

void test_gates() {
    for i32 profile = 0; profile < PROFILE_COUNT; profile++ {
        Engine* e = rig_new();
        set_profile(e, profile);
        // A 32.7 Hz sine through the comparator.
        ignore engine_set(e, "osc.octave", -3.0f);
        ignore engine_connect(e, "osc.sine", "gates.sig1");
        ignore engine_set(e, "gates.length1", 0.01f);
        ignore engine_connect(e, "keys.gate", "gates.or1");
        ignore engine_connect(e, "keys.gate", "gates.trig2");
        rig_settle(e);
        i32 edges = 0;
        i32 pulse = 0;
        f32 v_high = 0.0f;
        bool v_ok = true;
        f32 was = rig_value(e, "gates.gate1");
        for i32 i = 0; i < SEC; i++ {
            ignore rig_run(e, 1);
            f32 g = rig_value(e, "gates.gate1");
            if g >= 0.5f && was < 0.5f { edges++; }
            was = g;
            if edges == 3 && rig_value(e, "gates.pulse1") >= 0.5f { pulse++; }
            f32 v = rig_volts(e, "gates.v1");
            if v > 0.0f { v_high = v; }
            if v != 0.0f && fabsf(v - 3.0f) > 1e-5f { v_ok = false; }
        }
        print("GATES ({}): {} gate edges in 1 s, pulse {} frames, V {} V\n", profile, edges, pulse, cast(f64, v_high));
        check(edges >= 32 && edges <= 34, "SIG over the threshold makes a gate");
        check(pulse >= 478 && pulse <= 482, "each gate edge makes a PULSE of LENGTH");
        check(v_ok && v_high == 3.0f, "V is +3 V while the trigger is high, in either profile");
        ignore engine_key_on(e, 60);
        ignore rig_run(e, 480);
        check(rig_value(e, "gates.or") == 1.0f && fabsf(rig_volts(e, "gates.v2") - 3.0f) < 1e-5f,
              "OR follows its inputs; a trigger line becomes +3 V");
        ignore engine_set(e, "gates.button2", 1.0f);
        ignore rig_run(e, 48);
        check(rig_value(e, "gates.b2") == 1.0f, "a button is high while held");
        engine_free(e);
    }

    // VINTAGE: signals and triggers meet only through GATES.
    check(!profile_can_connect(PROFILE_VINTAGE, CLS_AUDIO, CLS_TRIG), "VINTAGE: audio can't go into a trigger input");
    check(profile_can_connect(PROFILE_VINTAGE, CLS_AUDIO, CLS_CV_BI) && profile_can_connect(PROFILE_VINTAGE, CLS_TRIG, CLS_TRIG)
          && profile_can_connect(PROFILE_VINTAGE, CLS_CV_UNI, CLS_CV_UNI),
          "VINTAGE: audio into SIG, GATE into a trigger input, V into a signal input");
    // An audio-rate LFO clocks the sequencer in VINTAGE through GATES.
    Engine* e = rig_new();
    defer engine_free(e);
    set_profile(e, PROFILE_VINTAGE);
    ignore engine_set(e, "osc.octave", -3.0f);
    ignore engine_connect(e, "osc.sine", "gates.sig1");
    ignore engine_connect(e, "gates.gate1", "seq.clock");
    ignore engine_connect(e, "osc.sine", "seq.clock");             // refused
    rig_settle(e);
    check(rig_jack(e, "seq.clock").n_src == 1, "VINTAGE refuses audio straight into a clock");
    i32 clocks = 0;
    f32 was = 0.0f;
    for i32 i = 0; i < SEC; i++ {
        ignore rig_run(e, 1);
        f32 c = rig_value(e, "seq.clock");
        if c >= 0.5f && was < 0.5f { clocks++; }
        was = c;
    }
    check(clocks >= 32 && clocks <= 34, "through GATES, an oscillator clocks the sequencer");
}

// ---- OFFSETS, ATTEN, MULT ----

void test_utilities() {
    for i32 profile = 0; profile < PROFILE_COUNT; profile++ {
        Engine* e = rig_new();
        set_profile(e, profile);
        ignore engine_set(e, "offsets.coarse1", 2.5f);
        ignore engine_set(e, "offsets.fine1", 0.25f);
        ignore engine_connect(e, "keys.pitch", "offsets.in2");
        ignore engine_key_on(e, 72);
        rig_settle(e);
        ignore rig_run(e, 48);
        check(fabsf(rig_volts(e, "offsets.out1") - 2.75f) < 1e-5f && fabsf(rig_volts(e, "offsets.inv1") + 2.75f) < 1e-5f,
              "OFFSETS: coarse plus fine, and inverted, in volts in either profile");
        check(fabsf(rig_volts(e, "offsets.out2") - 1.0f) < 1e-5f, "OFFSETS adds its input");
        engine_free(e);
    }

    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_set(e, "atten.gain1", 2.0f);
    ignore engine_set(e, "atten.gain2", -0.5f);
    ignore engine_connect(e, "osc.saw", "atten.in2");
    ignore engine_connect(e, "osc.saw", "mult.in1");
    rig_settle(e);
    ignore rig_run(e, 480);
    check(fabsf(rig_value(e, "atten.out1") - 2.0f) < 1e-5f, "ATTEN: an unpatched input reads full scale, up to twice the gain");
    f32 saw = rig_value(e, "osc.saw");
    ignore rig_run(e, 1);
    check(fabsf(rig_value(e, "atten.out2") + 0.5f * saw) < 1e-6f, "ATTEN inverts and scales, one tick behind");
    check(rig_value(e, "mult.a1") == saw && rig_value(e, "mult.a2") == saw && rig_value(e, "mult.a3") == saw,
          "MULT copies its input to three outputs");
}

// ---- SCOPE ----

void test_scope() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "osc.saw", "scope.a");
    ignore engine_set(e, "scope.time", 0.1f);
    rig_settle(e);
    u32 w0 = e.tele.scope_w;
    ignore rig_run(e, SEC);
    u32 written = e.tele.scope_w - w0;
    check(e.tele.scope_decim == 5, "the scope keeps one frame in five for a 0.1 s screen");
    check(written >= 9599 && written <= 9601, "and records a screen's worth of frames per 0.1 s");
    f32 lo = 0.0f;
    f32 hi = 0.0f;
    bool quiet = true;
    for i32 i = 0; i < SCOPE_SCREEN; i++ {
        u32 at = (e.tele.scope_w - 1 - cast(u32, i)) & SCOPE_MASK;
        lo = fminf(lo, e.tele.scope[0][at]);
        hi = fmaxf(hi, e.tele.scope[0][at]);
        if e.tele.scope[1][at] != 0.0f { quiet = false; }
    }
    check(lo < -4.5f && hi > 4.5f && hi < 5.5f, "channel A records the saw in volts");
    check(quiet, "an unpatched channel records 0 V");

    // Unpatched, A shows the output: the default patch playing.
    Engine* d = rig_new();
    defer engine_free(d);
    rack_default_patch(d);
    ignore engine_key_on(d, 48);
    ignore rig_run(d, SEC / 2 - SCOPE_SCREEN);
    f32 out_peak = rig_run(d, SCOPE_SCREEN);                   // the window the scope holds
    f32 most = 0.0f;
    for i32 i = 0; i < SCOPE_SCREEN; i++ {
        most = fmaxf(most, fabsf(d.tele.scope[0][(d.tele.scope_w - 1 - cast(u32, i)) & SCOPE_MASK]));
    }
    print("SCOPE A unpatched: {} V for an output peak of {}\n", cast(f64, most), cast(f64, out_peak));
    check(out_peak > 0.0f && fabsf(most / out_peak - 5.0f / OUT_HALF_SCALE) < 0.05f, "unpatched, channel A shows the output in volts (full scale = 5 V)");
}

// ---- the whole rack ----

// Every input takes a cable in either profile: patch them all at once,
// play, and nothing breaks.
void test_whole_rack() {
    str[5] sources = { "osc.saw", "keys.gate", "noise.smooth", "env1.env", "seq.gate" };
    for i32 profile = 0; profile < PROFILE_COUNT; profile++ {
        Engine* e = rig_new();
        set_profile(e, profile);
        ignore rig_run(e, 1);
        bool every_in = true;
        i32 cables = 0;
        for i32 j = 0; j < e.core.n_jacks; j++ {
            bool done = false;
            for i32 k = 0; k < 5 && !done; k++ {
                i32 s = engine_output_ref(e, sources[k]);
                if e.core.slot_module[s] == e.core.jacks[j].module { continue; }
                if profile_can_connect(profile, e.core.slot_cls[s], e.core.jacks[j].cls) {
                    ignore engine_send_kind(e, CMD_CONNECT, s, j, 0.0f);
                    cables++;
                    done = true;
                }
            }
            if !done { every_in = false; }
        }
        bool every_out = true;
        for i32 s = 0; s < e.core.n_slots; s++ {
            bool any = false;
            for i32 j = 0; j < e.core.n_jacks && !any; j++ {
                if profile_can_connect(profile, e.core.slot_cls[s], e.core.jacks[j].cls) { any = true; }
            }
            if !any { every_out = false; }
        }
        ignore engine_set(e, "osc.fm", 3.0f);
        ignore engine_set(e, "lowpass.res", 1.0f);
        ignore engine_key_on(e, 48);
        ignore rig_run(e, SEC);
        bool finite = true;
        for i32 s = 0; s < e.core.n_slots; s++ {
            f32 v = slot_value(&e.core, s);
            if v != v || v > 1e6f || v < -1e6f { finite = false; }
        }
        print("whole rack ({}): {} modules, {} cables, {} guard resets\n", profile, e.n_modules, cables, e.tele.nan_resets);
        check(every_in && every_out, "every input and output can be patched");
        check(finite && e.tele.nan_resets == 0, "every input patched at once plays without breaking");
        engine_free(e);
    }
}

i32 main() {
    g_x = alloc<f32>(SEC);
    g_y = alloc<f32>(SEC);
    defer free(g_x);
    defer free(g_y);
    test_osc_fm();
    test_bank();
    test_seq();
    test_highpass();
    test_band();
    test_spectrum();
    test_delay();
    test_stepsw();
    test_gates();
    test_utilities();
    test_scope();
    test_whole_rack();
    return check_done();
}
