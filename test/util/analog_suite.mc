// analog_suite.mc: digital modules measured against their analog references.
//
// Every comparison returns plain numbers; test_analog.mc pins the
// headline ones and tools/analog_report.mc prints them all. Frequencies
// are sr / P for whole P, so a rectangular DFT over whole periods is
// exact and no window blurs the result.

import math;
import "rig.mc";
import "analog_ref.mc";

const f64 SUITE_SR = 48000.0;

// Test frequencies: 48000 / P for these P, 50 Hz .. 16 kHz.
i32[14] SWEEP_P = { 960, 480, 240, 120, 96, 48, 32, 24, 16, 12, 8, 6, 4, 3 };
const i32 SWEEP_N = 14;

// ---- linear responses ----

// One point of a response comparison: digital over analog.
struct RespPoint {
    f64 f;
    f64 mag_db;             // |H_digital / H_analog| in dB
    f64 phase_deg;          // arg(H_digital / H_analog)
    f64 phase_comp_deg;     // the same with the fitted pure delay removed
}

struct Resp {
    RespPoint[14] p;
    f64 delay_samples;      // pure delay fitted at the lowest frequencies
}

enum LinKind { LIN_LADDER, LIN_HP4, LIN_SVF_LOW, LIN_SVF_BAND, LIN_SVF_HIGH, LIN_LADDER_DIRECT }

private Cx analog_of(i32 kind, f64 f, f64 fc, f64 k) {
    if kind == LIN_LADDER || kind == LIN_LADDER_DIRECT { return ladder_h(f, fc, k); }
    if kind == LIN_HP4 { return hp4_h(f, fc); }
    if kind == LIN_SVF_LOW { return svf_h(f, fc, k, SVF_LOW); }
    if kind == LIN_SVF_BAND { return svf_h(f, fc, k, SVF_BAND); }
    return svf_h(f, fc, k, SVF_HIGH);
}

// Complex gain of a digital module at sr / P: a small sine in, settle,
// then the output's DFT over whole periods over the input's.
// `k` is the ladder feedback, or Q for the SVF.
Cx digital_gain(i32 kind, i32 period, f64 fc, f64 k, f64 sr) {
    f64 f = SUITE_SR / cast(f64, period);
    i32 settle = cast(i32, 2.0 * sr);
    i32 periods = 48000 / period;
    if periods < 8 { periods = 8; }
    i32 n = periods * period * cast(i32, sr / SUITE_SR);
    f64* xin = alloc<f64>(n);
    f64* yout = alloc<f64>(n);
    defer free(xin);
    defer free(yout);
    f64 amp = 1e-4;                             // small: the tanh stages stay linear
    Ladder lad;
    ladder_init(&lad);
    HighPass4 hp;
    Svf sv;
    svf_set(&sv, cast(f32, fc), cast(f32, k), cast(f32, sr));
    f32 g = prewarp(cast(f32, fc), cast(f32, sr));
    for i32 i = 0; i < settle + n; i++ {
        f64 x = amp * sin(TAU_D * f * cast(f64, i) / sr);
        f32 xs = cast(f32, x);
        f32 y = 0.0f;
        if kind == LIN_LADDER { y = ladder_process(&lad, xs, cast(f32, fc), cast(f32, k), cast(f32, sr)); }
        else if kind == LIN_LADDER_DIRECT { y = ladder_process_direct(&lad, xs, cast(f32, fc), cast(f32, k), cast(f32, sr)); }
        else if kind == LIN_HP4 { y = highpass4_process(&hp, xs, g); }
        else {
            SvfOut o = svf_process(&sv, xs);
            if kind == LIN_SVF_LOW { y = o.low; }
            else if kind == LIN_SVF_BAND { y = o.band * sv.k; }
            else { y = o.high; }
        }
        if i >= settle {
            xin[i - settle] = xs;
            yout[i - settle] = y;
        }
    }
    return cx_div(dft_at(yout, n, f, sr), dft_at(xin, n, f, sr));
}

// At the suite rate; compare_linear_at runs a module at another rate (a
// multiple of 48 kHz), the way an oversampled engine does.
Resp compare_linear(i32 kind, f64 fc, f64 k) { return compare_linear_at(kind, fc, k, SUITE_SR); }

Resp compare_linear_at(i32 kind, f64 fc, f64 k, f64 sr) {
    Resp r;
    for i32 i = 0; i < SWEEP_N; i++ {
        f64 f = SUITE_SR / cast(f64, SWEEP_P[i]);
        Cx ratio = cx_div(digital_gain(kind, SWEEP_P[i], fc, k, sr), analog_of(kind, f, fc, k));
        r.p[i].f = f;
        r.p[i].mag_db = db_d(cx_abs(ratio));
        r.p[i].phase_deg = deg(cx_arg(ratio));
    }
    // Pure delay from the phase slope over the two lowest frequencies.
    f64 w0 = TAU_D * r.p[0].f;
    f64 w1 = TAU_D * r.p[1].f;
    f64 tau = -(r.p[1].phase_deg - r.p[0].phase_deg) * PI_D / 180.0 / (w1 - w0);
    r.delay_samples = tau * sr;
    for i32 i = 0; i < SWEEP_N; i++ {
        f64 comp = r.p[i].phase_deg * PI_D / 180.0 + TAU_D * r.p[i].f * tau;
        r.p[i].phase_comp_deg = deg(wrap_pi(comp));
    }
    return r;
}

// Worst |magnitude error| and |delay-compensated phase error| up to f_max.
f64 resp_worst_mag(Resp* r, f64 f_max) {
    f64 w = 0.0;
    for i32 i = 0; i < SWEEP_N; i++ { if r.p[i].f <= f_max && fabs(r.p[i].mag_db) > w { w = fabs(r.p[i].mag_db); } }
    return w;
}

f64 resp_worst_phase(Resp* r, f64 f_max) {
    f64 w = 0.0;
    for i32 i = 0; i < SWEEP_N; i++ { if r.p[i].f <= f_max && fabs(r.p[i].phase_comp_deg) > w { w = fabs(r.p[i].phase_comp_deg); } }
    return w;
}

void print_resp(str title, Resp* r) {
    print("{} (fitted delay {} samples)\n", title, r.delay_samples);
    print("      f Hz    mag dB    phase deg   phase-delay deg\n");
    for i32 i = 0; i < SWEEP_N; i++ {
        print("  {}  {}  {}  {}\n", r.p[i].f, r.p[i].mag_db, r.p[i].phase_deg, r.p[i].phase_comp_deg);
    }
}

// ---- oscillator waveforms ----

enum WaveKind { WAVE_SAW, WAVE_PULSE, WAVE_TRI, WAVE_SINE }

struct WaveCmp {
    f64 f0;
    f64 esr_5k;             // harmonic error below 5 kHz over the whole signal, dB
    f64 esr_10k;
    f64 esr_16k;
    f64 esr_all;
    f64 worst_strong_db;    // worst magnitude error of harmonics above -40 dB, below 16 kHz
    f64 alias_db;           // energy away from the harmonics, over the signal
    f64 delay_samples;      // fitted from the fundamental
}

private Cx wave_coef(i32 kind, i32 h, f64 pw) {
    if kind == WAVE_PULSE { return pulse_coef(h, pw); }
    if kind == WAVE_TRI { return tri_coef(h); }
    if kind == WAVE_SINE { return sine_coef(h); }
    return saw_coef(h);
}

// A digital waveform at f0 Hz against the ideal band-limited one, over
// one second. With f0 a whole number of Hz sharing no factor with 48000,
// harmonics and aliases fall on separate frequencies.
WaveCmp compare_wave(i32 kind, f64 f0) {
    f64 sr = SUITE_SR;
    f64 pw = 0.3;
    i32 n = 48000;
    f64* d = alloc<f64>(n);
    defer free(d);
    Osc o;
    osc_init(&o, 0.0);
    f32 dt = cast(f32, f0 / sr);
    f64 fa = cast(f64, dt) * sr;                // the frequency the oscillator really runs at
    i32 lead = 64;
    for i32 i = 0; i < lead + n; i++ {
        osc_tick(&o, dt, cast(f32, pw), 0.0f);
        if i >= lead {
            f64 v = o.saw;
            if kind == WAVE_PULSE { v = o.pulse; }
            else if kind == WAVE_TRI { v = o.tri; }
            else if kind == WAVE_SINE { v = o.sine; }
            d[i - lead] = v;
        }
    }
    // Tick i outputs the waveform at phase i * dt, so the window starts at
    // phase lead * dt.
    f64 phase0 = cast(f64, dt) * cast(f64, lead);

    WaveCmp w;
    w.f0 = f0;
    i32 nh = cast(i32, (sr * 0.5 - 1.0) / fa);
    Cx* dh = alloc<Cx>(nh);
    Cx* ah = alloc<Cx>(nh);
    defer free(dh);
    defer free(ah);
    f64 signal = 0.0;
    f64 harm = 0.0;
    for i32 h = 1; h <= nh; h++ {
        f64 f = fa * cast(f64, h);
        dh[h - 1] = dft_at(d, n, f, sr);
        ah[h - 1] = cx_mul(wave_coef(kind, h, pw), cx_expj(TAU_D * cast(f64, h) * phase0));
        signal += 0.5 * cx_abs(ah[h - 1]) * cx_abs(ah[h - 1]);
        harm += 0.5 * cx_abs(dh[h - 1]) * cx_abs(dh[h - 1]);
    }
    f64 dc = 0.0;
    for i32 i = 0; i < n; i++ { dc += d[i]; }
    dc /= cast(f64, n);

    f64 tau = -cx_arg(cx_div(dh[0], ah[0])) / (TAU_D * fa);
    w.delay_samples = tau * sr;
    f64 e5 = 0.0;
    f64 e10 = 0.0;
    f64 e16 = 0.0;
    f64 eall = 0.0;
    f64 fund = cx_abs(ah[0]);
    for i32 h = 1; h <= nh; h++ {
        f64 f = fa * cast(f64, h);
        Cx dc_h = cx_mul(dh[h - 1], cx_expj(TAU_D * f * tau));
        Cx e = cx_sub(dc_h, ah[h - 1]);
        f64 ee = 0.5 * (e.re * e.re + e.im * e.im);
        if f <= 5000.0 { e5 += ee; }
        if f <= 10000.0 { e10 += ee; }
        if f <= 16000.0 { e16 += ee; }
        eall += ee;
        if f <= 16000.0 && cx_abs(ah[h - 1]) > 0.01 * fund {
            f64 m = fabs(db_d(cx_abs(dc_h) / cx_abs(ah[h - 1])));
            if m > w.worst_strong_db { w.worst_strong_db = m; }
        }
    }
    f64 lg = log(10.0);
    w.esr_5k = 10.0 * log(e5 / signal + 1e-30) / lg;
    w.esr_10k = 10.0 * log(e10 / signal + 1e-30) / lg;
    w.esr_16k = 10.0 * log(e16 / signal + 1e-30) / lg;
    w.esr_all = 10.0 * log(eall / signal + 1e-30) / lg;
    f64 off = energy(d, n) - harm - dc * dc;
    if kind == WAVE_PULSE { off = energy(d, n) - harm - dc * dc; }
    w.alias_db = 10.0 * log(fabs(off) / signal + 1e-30) / lg;
    return w;
}

void print_wave(str name, WaveCmp* w) {
    print("  {} {} Hz: error <5k {} dB, <10k {} dB, <16k {} dB, all {} dB; strong harmonics within {} dB; aliases {} dB; delay {} samples\n",
          name, w.f0, w.esr_5k, w.esr_10k, w.esr_16k, w.esr_all, w.worst_strong_db, w.alias_db, w.delay_samples);
}

// ---- envelope ----

struct EnvCmp {
    f64 attack_s;
    f64 max_err;            // worst |digital - analog| over attack and decay, canonical
    f64 corner_err_samples; // when the digital attack ends, relative to the analog corner
}

EnvCmp compare_env(f64 attack, f64 decay, f64 sustain) {
    f64 sr = SUITE_SR;
    Env e;
    env_set(&e, cast(f32, attack), cast(f32, decay), cast(f32, sustain), 0.1f, cast(f32, sr));
    EnvCmp c;
    c.attack_s = attack;
    i32 corner = -1;
    i32 n = cast(i32, (attack + 2.0 * decay) * sr);
    for i32 i = 0; i < n; i++ {
        f64 v = env_tick(&e, true, false);
        if corner < 0 && e.stage == ENV_DECAY { corner = i; }
        f64 t = cast(f64, i + 1) / sr;           // tick i lands 1 / sr after the gate edge
        f64 err = fabs(v - env_ref_ad(t, attack, decay, sustain));
        if err > c.max_err { c.max_err = err; }
    }
    c.corner_err_samples = cast(f64, corner + 1) - attack * sr;
    return c;
}

// ---- ladder, nonlinear, against RK4 ----

const i32 REF_OS = 16;                  // RK4 steps per audio sample

struct DrivenCmp {
    f64 amp;
    f64 k;
    f64 esr_raw_db;         // harmonics 1..20, as is
    f64 esr_comp_db;        // the same with the fitted pure delay removed
    f64 delay_samples;
    f64 h3_digital_db;      // third harmonic over the fundamental
    f64 h3_analog_db;
}

// A sine of `amp` (internal units: 1 is where tanh bends) at f0 into the
// ladder, digital against RK4. f0 whole Hz; half a second is analysed
// after a quarter second to settle.
DrivenCmp compare_ladder_driven(f64 fc, f64 k, f64 amp, f64 f0) {
    f64 sr = SUITE_SR;
    i32 settle = 12000;
    i32 n = 24000;
    f64* d = alloc<f64>(n);
    f64* a = alloc<f64>(n);
    defer free(d);
    defer free(a);
    Ladder lad;
    ladder_init(&lad);
    LadderRef ref;
    ladder_ref_init(&ref, fc, k);
    f64 h = 1.0 / (sr * cast(f64, REF_OS));
    f64 w = TAU_D * f0;
    for i32 i = 0; i < settle + n; i++ {
        f64 t = cast(f64, i) / sr;
        f32 y = ladder_process(&lad, cast(f32, amp * sin(w * t)), cast(f32, fc), cast(f32, k), cast(f32, sr));
        if i >= settle {
            d[i - settle] = y;
            a[i - settle] = ref.y[3];               // the analog output at this sample's time
        }
        for i32 s = 0; s < REF_OS; s++ {
            f64 t0 = t + cast(f64, s) * h;
            ladder_ref_step(&ref, amp * sin(w * t0), amp * sin(w * (t0 + 0.5 * h)), amp * sin(w * (t0 + h)), h);
        }
    }
    Cx[20] dh;
    Cx[20] ah;
    for i32 k2 = 0; k2 < 20; k2++ {
        dh[k2] = dft_at(d, n, f0 * cast(f64, k2 + 1), sr);
        ah[k2] = dft_at(a, n, f0 * cast(f64, k2 + 1), sr);
    }
    DrivenCmp c;
    c.amp = amp;
    c.k = k;
    c.esr_raw_db = esr_db(&dh[0], &ah[0], 20);
    f64 tau = -cx_arg(cx_div(dh[0], ah[0])) / (TAU_D * f0);
    c.delay_samples = tau * sr;
    for i32 k2 = 0; k2 < 20; k2++ { dh[k2] = cx_mul(dh[k2], cx_expj(TAU_D * f0 * cast(f64, k2 + 1) * tau)); }
    c.esr_comp_db = esr_db(&dh[0], &ah[0], 20);
    c.h3_digital_db = db_d(cx_abs(dh[2]) / cx_abs(dh[0]));
    c.h3_analog_db = db_d(cx_abs(ah[2]) / cx_abs(ah[0]));
    return c;
}

struct SelfOscCmp {
    f64 fc;
    f64 k;
    f64 cents_digital;      // self-oscillation pitch against the nominal cutoff
    f64 cents_analog;
    f64 amp_digital;
    f64 amp_analog;
}

// Self-oscillation after a small kick, measured over the last half second.
SelfOscCmp compare_self_osc(f64 fc, f64 k, f64 seconds) {
    f64 sr = SUITE_SR;
    i32 total = cast(i32, seconds * sr);
    i32 n = 24000;
    f64* d = alloc<f64>(n);
    f64* a = alloc<f64>(n);
    defer free(d);
    defer free(a);
    Ladder lad;
    ladder_init(&lad);
    LadderRef ref;
    ladder_ref_init(&ref, fc, k);
    ref.y[0] = 0.05;                            // the kick, as a state
    f64 h = 1.0 / (sr * cast(f64, REF_OS));
    for i32 i = 0; i < total; i++ {
        f32 kick = 0.0f;
        if i == 0 { kick = 0.05f; }
        f32 y = ladder_process(&lad, kick, cast(f32, fc), cast(f32, k), cast(f32, sr));
        if i >= total - n {
            d[i - (total - n)] = y;
            a[i - (total - n)] = ref.y[3];
        }
        for i32 s = 0; s < REF_OS; s++ { ladder_ref_step(&ref, 0.0, 0.0, 0.0, h); }
    }
    SelfOscCmp c;
    c.fc = fc;
    c.k = k;
    c.cents_digital = 1200.0 * log2(freq_of(d, n, sr) / fc);
    c.cents_analog = 1200.0 * log2(freq_of(a, n, sr) / fc);
    c.amp_digital = peak_of(d, n);
    c.amp_analog = peak_of(a, n);
    return c;
}

// ---- patch level: a feedback loop through cables ----

struct LoopCmp {
    f64 sr;
    RespPoint[14] p;        // closed-loop response, digital over analog
    f64 worst_mag_4k;       // worst |magnitude error| up to 4 kHz, dB
    f64 worst_phase_4k;     // worst |phase error| up to 4 kHz, degrees
    f64 residual_db;        // worst error up to 4 kHz left after modelling the delays
}

// The ladder's oversampler delay, in samples of the engine rate
// (measured by compare_linear). From LP_DIRECT_RATE up the ladder runs
// without its oversampler and adds none.
const f64 LADDER_DELAY_SAMPLES = 3.815;

f64 ladder_latency(f64 sr) {
    if sr >= cast(f64, LP_DIRECT_RATE) { return 0.0; }
    return LADDER_DELAY_SAMPLES;
}

// LOWPASS (fc, k) with its output fed back inverted through MIX at level
// m: two cables, so two samples of delay plus the filter's own
// oversampler, against the analog loop H / (1 + m H) with no delay. The
// test signal enters through LOWPASS in1's normal value, so it has no
// cable delay of its own.
LoopCmp compare_loop(f64 sr, f64 fc, f64 k, f64 m) {
    Engine* e = engine_new(cast(f32, sr));
    defer engine_free(e);
    rack_build(e);
    ignore engine_connect(e, "lowpass.out", "mix1.in1");
    ignore engine_connect(e, "mix1.inv", "lowpass.in2");
    ignore engine_set(e, "mix1.level1", cast(f32, m));
    ignore engine_set(e, "lowpass.cutoff", cast(f32, log2(fc / C4_HZ_D)));
    ignore engine_set(e, "lowpass.res", cast(f32, k / 4.2));
    ignore engine_set(e, "lowpass.comp", 0.0f);
    i32 in1 = engine_input_ref(e, "lowpass.in1");

    LoopCmp c;
    c.sr = sr;
    i32 settle = cast(i32, 0.5 * sr);
    i32 n = cast(i32, sr);                      // one second: whole periods of any whole-Hz tone
    f64* xin = alloc<f64>(n);
    f64* yout = alloc<f64>(n);
    defer free(xin);
    defer free(yout);
    for i32 pi = 0; pi < SWEEP_N; pi++ {
        f64 f = SUITE_SR / cast(f64, SWEEP_P[pi]);
        for i32 i = 0; i < settle + n; i++ {
            f64 x = 1e-3 * sin(TAU_D * f * cast(f64, i) / sr);
            core_set_normal(&e.core, in1, cast(f32, x));
            engine_render(e, &g_rig_frames[0], 1, 2);
            if i >= settle {
                xin[i - settle] = x;
                yout[i - settle] = rig_value(e, "lowpass.out");
            }
        }
        Cx hd = cx_div(dft_at(yout, n, f, sr), dft_at(xin, n, f, sr));
        Cx h = ladder_h(f, fc, k);
        Cx ha = cx_div(h, cx_add(Cx{ 1.0, 0.0 }, cx_scale(h, m)));
        Cx ratio = cx_div(hd, ha);
        c.p[pi].f = f;
        c.p[pi].mag_db = db_d(cx_abs(ratio));
        c.p[pi].phase_deg = deg(cx_arg(ratio));

        // The same analog loop with only the digital delays put in: the
        // filter's own in the forward path, plus two cables in the loop.
        f64 w = TAU_D * f;
        f64 th = ladder_latency(sr) / sr;
        f64 tc = 2.0 / sr;
        Cx hf = cx_mul(h, cx_expj(-w * th));
        Cx hm = cx_div(hf, cx_add(Cx{ 1.0, 0.0 }, cx_scale(cx_mul(hf, cx_expj(-w * tc)), m)));
        Cx resid = cx_div(hd, hm);
        f64 r_err = cx_abs(cx_sub(resid, Cx{ 1.0, 0.0 }));
        if f <= 4000.0 {
            if fabs(c.p[pi].mag_db) > c.worst_mag_4k { c.worst_mag_4k = fabs(c.p[pi].mag_db); }
            if fabs(c.p[pi].phase_deg) > c.worst_phase_4k { c.worst_phase_4k = fabs(c.p[pi].phase_deg); }
            if r_err > c.residual_db { c.residual_db = r_err; }
        }
    }
    c.residual_db = db_d(c.residual_db + 1e-30);
    return c;
}

void print_loop(LoopCmp* c) {
    print("  engine at {} Hz: worst up to 4 kHz {} dB, {} deg; with the delays modelled, {} dB left\n",
          c.sr, c.worst_mag_4k, c.worst_phase_4k, c.residual_db);
    for i32 i = 0; i < SWEEP_N; i++ {
        print("    {} Hz  {} dB  {} deg\n", c.p[i].f, c.p[i].mag_db, c.p[i].phase_deg);
    }
}

// ---- chaos: the FM feedback patch ----

struct FmParams {
    f64 pitch;              // OSC volts from C4
    f64 depth;              // MIX level on the loop
    f64 cutoff_v;           // LOWPASS cutoff, volts from C4
    f64 res;                // LOWPASS res, 0..1
}

// The patch in the engine at rate sr, settled and at rest with phase 0,
// the same starting state as the analog model.
Engine* fm_engine(f64 sr, FmParams p) {
    Engine* e = engine_new(cast(f32, sr));
    rack_build(e);
    ignore engine_connect(e, "osc.sine", "lowpass.in1");
    ignore engine_connect(e, "lowpass.out", "mix1.in1");
    // MIX tops out at unity, so deeper loops go into several OSC pitch
    // inputs, which sum: depth 2 is level 1 into pitch1 and pitch2.
    i32 inputs = cast(i32, ceil(p.depth - 1e-9));
    if inputs < 1 { inputs = 1; }
    if inputs > 3 { inputs = 3; }
    ignore engine_connect(e, "mix1.out", "osc.pitch1");
    if inputs >= 2 { ignore engine_connect(e, "mix1.out", "osc.pitch2"); }
    if inputs >= 3 { ignore engine_connect(e, "mix1.out", "osc.pitch3"); }
    f64 oct = floor(p.pitch + 0.5);
    ignore engine_set(e, "osc.octave", cast(f32, oct));
    ignore engine_set(e, "osc.fine", cast(f32, p.pitch - oct));
    ignore engine_set(e, "mix1.level1", cast(f32, p.depth / cast(f64, inputs)));
    ignore engine_set(e, "lowpass.cutoff", cast(f32, p.cutoff_v));
    ignore engine_set(e, "lowpass.res", cast(f32, p.res));
    ignore engine_set(e, "lowpass.comp", 0.0f);
    ignore engine_set(e, "lowpass.drive", 1.0f);
    rig_settle(e);
    osc_init(&e.osc[0].v, 0.0);
    return e;
}

f64 fm_digital_out(Engine* e) {
    engine_render(e, &g_rig_frames[0], 1, 2);
    return rig_value(e, "lowpass.out");
}

// Growth rate of a small difference, from ln(max |difference|) per
// millisecond block while it grows from 1e-5 to 1e-2. Returns 0 when it
// never grows through that range.
private f64 growth_rate(f64* ln_diff, i32 blocks) {
    f64[512] xs;
    f64[512] ys;
    i32 n = 0;
    f64 lo = log(1e-5);
    f64 hi = log(1e-2);
    for i32 b = 0; b < blocks && n < 512; b++ {
        if ln_diff[b] >= hi { break; }
        if ln_diff[b] >= lo {
            xs[n] = cast(f64, b) * 0.001;
            ys[n] = ln_diff[b];
            n++;
        }
    }
    if n < 5 { return 0.0; }
    return slope(&xs[0], &ys[0], n);
}

const i32 LYAP_STARTS = 4;
const f64 LYAP_RUN_S = 0.1;
const f64 PERTURB = 1e-6;

// Largest Lyapunov exponent of the analog model, per second: a 1e-6 phase
// perturbation from several points on the attractor, averaged.
f64 fm_lyapunov_analog(FmParams p) {
    f64 sr = SUITE_SR;
    f64 h = 1.0 / (sr * cast(f64, REF_OS));
    FmLoopRef a;
    fm_ref_init(&a, p.pitch, p.depth, p.cutoff_v, p.res);
    for i32 i = 0; i < cast(i32, 0.5 * sr) * REF_OS; i++ { fm_ref_step(&a, h); }
    f64 sum = 0.0;
    i32 per_block = cast(i32, sr * 0.001);
    i32 blocks = cast(i32, LYAP_RUN_S * 1000.0);
    f64* ln_diff = alloc<f64>(blocks);
    defer free(ln_diff);
    for i32 st = 0; st < LYAP_STARTS; st++ {
        FmLoopRef b = a;
        b.s[0] += PERTURB;
        for i32 bl = 0; bl < blocks; bl++ {
            f64 m = 1e-30;
            for i32 i = 0; i < per_block; i++ {
                for i32 k = 0; k < REF_OS; k++ {
                    fm_ref_step(&a, h);
                    fm_ref_step(&b, h);
                }
                f64 d = fabs(a.s[4] - b.s[4]);
                if d > m { m = d; }
            }
            ln_diff[bl] = log(m);
        }
        sum += growth_rate(ln_diff, blocks);
    }
    return sum / cast(f64, LYAP_STARTS);
}

// The same measurement on the engine at rate sr, with cloned engines.
f64 fm_lyapunov_digital(FmParams p, f64 sr) {
    Engine* a = fm_engine(sr, p);
    defer engine_free(a);
    for i32 i = 0; i < cast(i32, 0.5 * sr); i++ { ignore fm_digital_out(a); }
    f64 sum = 0.0;
    i32 per_block = cast(i32, sr * 0.001);
    i32 blocks = cast(i32, LYAP_RUN_S * 1000.0);
    f64* ln_diff = alloc<f64>(blocks);
    defer free(ln_diff);
    for i32 st = 0; st < LYAP_STARTS; st++ {
        Engine* b = rig_clone(a);
        b.osc[0].v.phase += PERTURB;
        for i32 bl = 0; bl < blocks; bl++ {
            f64 m = 1e-30;
            for i32 i = 0; i < per_block; i++ {
                f64 d = fabs(fm_digital_out(a) - fm_digital_out(b));
                if d > m { m = d; }
            }
            ln_diff[bl] = log(m);
        }
        engine_free(b);
        sum += growth_rate(ln_diff, blocks);
    }
    return sum / cast(f64, LYAP_STARTS);
}

struct ChaosCmp {
    f64 sr;
    f64 lyap_digital;
    f64 lag_samples;        // constant lag that best lines the digital output up with the analog
    f64 diverge_s;          // at that lag, digital leaves the analog trajectory (10 % of its RMS)
    f64 initial_err;        // at that lag, worst difference over the first 2 ms
    f64 hist_distance;      // amplitude distributions, 0 same .. 1 disjoint
    f64 band_worst_db;      // worst octave-band level difference, 62.5 Hz .. 8 kHz
    f64 rms_digital;
    f64 rms_analog;
}

// From the same resting state: how long the engine at rate sr follows
// the analog trajectory, and how its long-run statistics compare. The
// loop's forward latency makes the digital output trail the analog one;
// that constant lag is fitted over the first 20 ms and taken out, so
// only a real parting of the trajectories counts as divergence.
ChaosCmp compare_chaos(FmParams p, f64 sr) {
    ChaosCmp c;
    c.sr = sr;
    c.lyap_digital = fm_lyapunov_digital(p, sr);
    Engine* e = fm_engine(sr, p);
    defer engine_free(e);
    FmLoopRef a;
    fm_ref_init(&a, p.pitch, p.depth, p.cutoff_v, p.res);
    i32 os = REF_OS;
    if sr > SUITE_SR { os = REF_OS / cast(i32, sr / SUITE_SR); }
    if os < 4 { os = 4; }
    f64 h = 1.0 / (sr * cast(f64, os));
    i32 settle = cast(i32, 0.5 * sr);
    i32 n = cast(i32, 2.0 * sr);
    i32 total = settle + n;
    f64* dg = alloc<f64>(total);
    f64* an = alloc<f64>(total);
    defer free(dg);
    defer free(an);
    for i32 i = 0; i < total; i++ {
        an[i] = a.s[4];
        dg[i] = fm_digital_out(e);
        for i32 k = 0; k < os; k++ { fm_ref_step(&a, h); }
    }

    // Lag: the digital output shifted back by L lines up best early on.
    i32 fit = cast(i32, 0.02 * sr);
    i32 max_lag = cast(i32, 16.0 * sr / SUITE_SR);
    i32 lag = 0;
    f64 best = 1e30;
    for i32 L = 0; L <= max_lag; L++ {
        f64 s = 0.0;
        for i32 i = 0; i < fit; i++ {
            f64 d = dg[i + L] - an[i];
            s += d * d;
        }
        if s < best {
            best = s;
            lag = L;
        }
    }
    c.lag_samples = cast(f64, lag) * SUITE_SR / sr;

    i32 per_block = cast(i32, sr * 0.001);
    f64 rms = sqrt(energy(&an[settle], n));
    c.diverge_s = -1.0;
    for i32 b = 0; (b + 1) * per_block + lag < total; b++ {
        f64 m = 0.0;
        for i32 i = b * per_block; i < (b + 1) * per_block; i++ {
            f64 d = fabs(dg[i + lag] - an[i]);
            if d > m { m = d; }
        }
        if b < 2 && m > c.initial_err { c.initial_err = m; }
        if b >= 2 && m > 0.1 * rms {
            c.diverge_s = cast(f64, b) * 0.001;
            break;
        }
    }

    c.rms_digital = sqrt(energy(&dg[settle], n));
    c.rms_analog = rms;
    f64 lim = 1.2 * peak_of(&an[settle], n);
    c.hist_distance = hist_distance(&dg[settle], n, &an[settle], n, -lim, lim);
    f64[8] bd;
    f64[8] ba;
    octave_bands(&dg[settle], n, sr, &bd[0], 8);
    octave_bands(&an[settle], n, sr, &ba[0], 8);
    for i32 b = 0; b < 8; b++ {
        if fabs(bd[b] - ba[b]) > c.band_worst_db { c.band_worst_db = fabs(bd[b] - ba[b]); }
    }
    return c;
}

void print_chaos(ChaosCmp* c, f64 lyap_analog) {
    f64 predicted = -1.0;
    if lyap_analog > 0.0 && c.initial_err > 0.0 {
        predicted = log(0.1 * c.rms_analog / c.initial_err) / lyap_analog;
    }
    print("  engine at {} Hz: Lyapunov {} /s (analog {} /s)\n", c.sr, c.lyap_digital, lyap_analog);
    print("    lag {} samples at 48 kHz; follows the analog trajectory for {} s (a {} start error predicts {} s)\n",
          c.lag_samples, c.diverge_s, c.initial_err, predicted);
    print("    amplitude-distribution distance {}; octave bands within {} dB; RMS {} vs {}\n",
          c.hist_distance, c.band_worst_db, c.rms_digital, c.rms_analog);
}
