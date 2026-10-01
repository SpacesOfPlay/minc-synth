// test_osc.mc: pitch, levels, aliasing, sync and stability of dsp_osc.

import math;
import "../src/dsp_math.mc";
import "../src/dsp_osc.mc";
import "util/check.mc";

const f32 SR = 48000.0f;
const i32 N = 96000;                 // 2 s

f32* g_a;
f32* g_b;

void render_sine(f32 volts, i32 n) {
    Osc o;
    osc_init(&o, 0.0);
    f32 dt = osc_dt(volts, SR);
    for i32 i = 0; i < n; i++ {
        osc_tick(&o, dt, 0.5f, 0.0f);
        g_a[i] = o.sine;
    }
}

void test_pitch() {
    f64 worst = 0.0;
    for i32 v = -3; v <= 5; v++ {
        render_sine(cast(f32, v), N);
        f64 want = 261.6255653005986 * pow(2.0, cast(f64, v));
        f64 got = measure_freq(g_a, N, SR);
        f64 c = fabs(cents(got, want));
        if c > worst { worst = c; }
    }
    print("pitch worst error {} cent over -3..+5 V\n", worst);
    check(worst < 0.1, "pitch within 0.1 cent from -3 to +5 V");
}

void test_levels() {
    // 100 Hz: 480 samples per cycle, so 96000 samples are whole cycles.
    Osc o;
    osc_init(&o, 0.0);
    f32 dt = 100.0f / SR;
    for i32 i = 0; i < N; i++ {
        osc_tick(&o, dt, 0.25f, 0.0f);
        g_a[i] = o.saw;
        g_b[i] = o.pulse;
    }
    check(fabs(mean(g_a, N)) < 0.01, "saw has no DC");
    check(peak_abs(g_a, N) < 1.05f && peak_abs(g_a, N) > 0.98f, "saw spans +-1");
    check(fabs(mean(g_b, N) + 0.5) < 0.01, "pulse at 25% width averages -0.5");

    osc_init(&o, 0.0);
    for i32 i = 0; i < N; i++ {
        osc_tick(&o, dt, 0.5f, 0.0f);
        g_a[i] = o.tri;
        g_b[i] = o.sine;
    }
    check(peak_abs(g_a, N) < 1.01f && peak_abs(g_a, N) > 0.99f, "triangle spans +-1");
    check(fabs(tone_amplitude(g_b, N, 100.0, SR) - 1.0) < 0.01, "sine has unit amplitude");
    check(tone_amplitude(g_b, N, 300.0, SR) < 1e-3, "sine has no third harmonic");
}

// Worst alias below max_hz of a saw at f0 relative to its fundamental, in
// dB. 2-point polyBLEP leaves its strongest aliases just under Nyquist,
// where they matter least; the band limit measures the audible part.
// Aliases within 40 Hz of a real harmonic are skipped: the window can't
// split them.
f64 worst_alias_db(f32* buf, i32 n, f64 f0, f64 max_hz) {
    f64 fund = tone_amplitude(buf, n, f0, SR);
    f64 worst = 0.0;
    f64 nyq = SR * 0.5;
    for i32 k = 2; k < 60; k++ {
        f64 f = f0 * cast(f64, k);
        if f < nyq { continue; }
        f64 a = f - floor(f / SR) * SR;          // fold into [0, SR)
        if a > nyq { a = SR - a; }
        if a < 40.0 || a > max_hz { continue; }
        bool near = false;
        for i32 h = 1; cast(f64, h) * f0 < nyq; h++ {
            if fabs(cast(f64, h) * f0 - a) < 40.0 { near = true; }
        }
        if near { continue; }
        f64 amp = tone_amplitude(buf, n, a, SR);
        if amp > worst { worst = amp; }
    }
    return db(worst / fund);
}

void test_aliasing() {
    i32 n = 32768;
    f64 f0 = 4700.0;
    f32 dt = cast(f32, f0 / SR);
    Osc o;
    osc_init(&o, 0.0);
    f64 t = 0.0;
    for i32 i = 0; i < n; i++ {
        osc_tick(&o, dt, 0.5f, 0.0f);
        g_a[i] = o.saw;
        g_b[i] = cast(f32, 2.0 * t - 1.0);      // naive saw, for comparison
        t += dt;
        if t >= 1.0 { t -= 1.0; }
    }
    f64 full = worst_alias_db(g_a, n, f0, 24000.0);
    f64 blep = worst_alias_db(g_a, n, f0, 8000.0);
    f64 naive = worst_alias_db(g_b, n, f0, 8000.0);
    print("saw 4700 Hz worst alias: full band {} dB; below 8 kHz polyblep {} dB, naive {} dB\n",
          full, blep, naive);
    check(blep < naive - 20.0, "polyBLEP beats naive by 20 dB below 8 kHz at 4.7 kHz");
    check(blep < -50.0, "polyBLEP saw aliases below -50 dB under 8 kHz at 4.7 kHz");

    f64 f1 = 1234.5;
    osc_init(&o, 0.0);
    for i32 i = 0; i < n; i++ {
        osc_tick(&o, cast(f32, f1 / SR), 0.5f, 0.0f);
        g_a[i] = o.saw;
    }
    f64 low = worst_alias_db(g_a, n, f1, 8000.0);
    print("saw 1234.5 Hz worst alias below 8 kHz: {} dB\n", low);
    check(low < -55.0, "polyBLEP saw aliases below -55 dB under 8 kHz at 1.2 kHz");
}

void test_sync() {
    // Master at 480 Hz (100 samples per cycle) syncs a 700 Hz slave, so
    // the slave repeats every 100 samples.
    Osc master;
    Osc slave;
    osc_init(&master, 0.0);
    osc_init(&slave, 0.3);
    f32 dm = 480.0f / SR;
    f32 ds = 700.0f / SR;
    i32 n = 4000;
    for i32 i = 0; i < n; i++ {
        osc_tick(&master, dm, 0.5f, 0.0f);
        osc_tick(&slave, ds, 0.5f, master.saw);
        g_a[i] = slave.saw;
    }
    f32 worst = 0.0f;
    for i32 i = 1000; i < n - 100; i++ {
        f32 d = fabsf(g_a[i] - g_a[i + 100]);
        if d > worst { worst = d; }
    }
    print("sync periodicity error {}\n", cast(f64, worst));
    check(worst < 1e-3f, "synced slave repeats with the master period");
    check(peak_abs(g_a, n) < 1.3f, "synced saw stays bounded");
}

void test_stress() {
    // Random frequency, width and sync every sample.
    Rng r;
    rng_seed(&r, 7, 1);
    Osc o;
    osc_init(&o, 0.0);
    bool ok = true;
    f32 worst = 0.0f;
    for i32 i = 0; i < 200000; i++ {
        f32 dt = (rng_uniform(&r) + 1.0f) * 0.5f * OSC_MAX_DT;
        f32 pw = 0.05f + (rng_uniform(&r) + 1.0f) * 0.45f;
        osc_tick(&o, dt, pw, rng_uniform(&r));
        f32 m = fabsf(o.saw);
        if fabsf(o.pulse) > m { m = fabsf(o.pulse); }
        if fabsf(o.tri) > m { m = fabsf(o.tri); }
        if m > worst { worst = m; }
        if o.saw != o.saw || o.pulse != o.pulse || o.tri != o.tri || o.sine != o.sine { ok = false; }
    }
    print("stress peak {}\n", cast(f64, worst));
    check(ok, "outputs stay finite under random modulation");
    check(worst < 2.5f, "outputs stay bounded under random modulation");
    check(o.phase >= 0.0 && o.phase < 1.0, "phase stays in [0, 1)");
}

// Through-zero FM runs the phase backwards. Backwards from 1 - p is the
// mirror of forwards from p: the saw and a 50 % pulse come out negated
// and the triangle the same, every correction included.
void test_reverse() {
    f32[4] rates = { 0.0021f, 0.0137f, 0.093f, 0.41f };
    f32 worst = 0.0f;
    for i32 k = 0; k < 4; k++ {
        Osc fwd;
        Osc rev;
        osc_init(&fwd, 0.3);
        osc_init(&rev, 0.7);
        for i32 i = 0; i < 20000; i++ {
            osc_tick(&fwd, rates[k], 0.5f, 0.0f);
            osc_tick(&rev, -rates[k], 0.5f, 0.0f);
            f32 d = fabsf(fwd.saw + rev.saw);
            if fabsf(fwd.pulse + rev.pulse) > d { d = fabsf(fwd.pulse + rev.pulse); }
            if fabsf(fwd.tri - rev.tri) > d { d = fabsf(fwd.tri - rev.tri); }
            if d > worst { worst = d; }
        }
    }
    print("reverse mirror error {}\n", cast(f64, worst));
    check(worst < 1e-4f, "backwards is the mirror of forwards, corrections included");

    // Swept through zero and back, at every width: finite and bounded.
    Osc o;
    osc_init(&o, 0.0);
    f32 most = 0.0f;
    bool finite = true;
    for i32 i = 0; i < 200000; i++ {
        f32 dt = 0.2f * sinf(cast(f32, i) * 0.0007f) + 0.02f;
        f32 pw = 0.5f + 0.45f * sinf(cast(f32, i) * 0.00013f);
        osc_tick(&o, dt, pw, 0.0f);
        f32 m = fmaxf(fabsf(o.saw), fmaxf(fabsf(o.pulse), fabsf(o.tri)));
        if m > most { most = m; }
        if o.saw != o.saw || o.pulse != o.pulse || o.tri != o.tri { finite = false; }
    }
    print("through-zero sweep peak {}\n", cast(f64, most));
    check(finite && most < 1.3f, "sweeping through zero stays finite and bounded");
    check(o.phase >= 0.0 && o.phase < 1.0, "phase stays in [0, 1) through zero");
}

i32 main() {
    g_a = alloc<f32>(N);
    g_b = alloc<f32>(N);
    defer free(g_a);
    defer free(g_b);
    test_pitch();
    test_levels();
    test_aliasing();
    test_sync();
    test_stress();
    test_reverse();
    return check_done();
}
