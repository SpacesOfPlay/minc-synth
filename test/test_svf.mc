// test_svf.mc: responses and stability of the state-variable filter.

import math;
import "../src/dsp_math.mc";
import "../src/dsp_svf.mc";
import "util/check.mc";

const f32 SR = 48000.0f;
const i32 N = 48000;

f32* g_low;
f32* g_band;
f32* g_high;

void run(f32 fc, f32 q, f64 hz) {
    Svf s;
    svf_set(&s, fc, q, SR);
    for i32 i = 0; i < N; i++ {
        f32 x = cast(f32, sin(2.0 * 3.141592653589793 * hz * cast(f64, i) / SR));
        SvfOut o = svf_process(&s, x);
        g_low[i] = o.low;
        g_band[i] = o.band * s.k;
        g_high[i] = o.high;
    }
}

f64 gain_db(f32* buf, f64 hz) { return db(tone_amplitude(&buf[N / 2], N / 2, hz, SR)); }

i32 main() {
    g_low = alloc<f32>(N);
    g_band = alloc<f32>(N);
    g_high = alloc<f32>(N);
    defer free(g_low);
    defer free(g_band);
    defer free(g_high);

    // Butterworth Q: low and high are -3 dB at the cutoff, band peaks at 0 dB.
    run(1000.0f, 0.70710678f, 1000.0);
    f64 lo_fc = gain_db(g_low, 1000.0);
    f64 hi_fc = gain_db(g_high, 1000.0);
    f64 bp_fc = gain_db(g_band, 1000.0);
    print("svf at fc: low {} dB, high {} dB, band {} dB\n", lo_fc, hi_fc, bp_fc);
    check(fabs(lo_fc + 3.01) < 0.1, "low-pass is -3 dB at the cutoff");
    check(fabs(hi_fc + 3.01) < 0.1, "high-pass is -3 dB at the cutoff");
    check(fabs(bp_fc) < 0.1, "normalized band-pass peaks at 0 dB");

    // A decade up: the 2-pole Butterworth response at the prewarped
    // frequency ratio, which the trapezoidal filter matches exactly.
    run(1000.0f, 0.70710678f, 10000.0);
    f64 lo_10 = gain_db(g_low, 10000.0);
    f64 w = tan(3.141592653589793 * 10000.0 / 48000.0) / tan(3.141592653589793 * 1000.0 / 48000.0);
    f64 want = -10.0 * log(1.0 + w * w * w * w) / log(10.0);
    print("svf low-pass a decade up: {} dB (prewarped Butterworth {} dB)\n", lo_10, want);
    check(fabs(lo_10 - want) < 0.1, "low-pass matches the prewarped 2-pole Butterworth");

    // High Q: the band-pass narrows but still peaks at 0 dB.
    run(2000.0f, 8.0f, 2000.0);
    f64 bp_q8 = gain_db(g_band, 2000.0);
    run(2000.0f, 8.0f, 2500.0);
    f64 bp_off = gain_db(g_band, 2500.0);
    print("svf band Q 8: peak {} dB, 2.5 kHz {} dB\n", bp_q8, bp_off);
    check(fabs(bp_q8) < 0.1, "Q 8 band-pass peaks at 0 dB");
    check(bp_off < -10.0, "Q 8 band-pass is narrow");

    // Random cutoff and Q every 32 samples, loud noise in.
    Rng r;
    rng_seed(&r, 5, 5);
    Svf s;
    svf_set(&s, 1000.0f, 1.0f, SR);
    bool finite = true;
    f32 worst = 0.0f;
    for i32 i = 0; i < 10 * 48000; i++ {
        if i % 32 == 0 {
            f32 fc = 20.0f * exp2_fast((rng_uniform(&r) + 1.0f) * 5.0f);
            f32 q = 0.5f + (rng_uniform(&r) + 1.0f) * 10.0f;
            svf_set(&s, fc, q, SR);
        }
        SvfOut o = svf_process(&s, rng_uniform(&r) * 5.0f);
        f32 band = o.band * s.k;
        if o.low != o.low || band != band || o.high != o.high { finite = false; }
        if fabsf(o.low) > worst { worst = fabsf(o.low); }
    }
    print("svf stress peak {}\n", cast(f64, worst));
    check(finite, "svf stays finite under random modulation");
    check(worst < 100.0f, "svf stays bounded under random modulation");
    return check_done();
}
