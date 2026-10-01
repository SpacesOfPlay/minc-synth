// test_ladder.mc: half-band oversampler, ladder low-pass and 4-pole high-pass.

import math;
import "../src/dsp_math.mc";
import "../src/dsp_ladder.mc";
import "util/check.mc";

const f32 SR = 48000.0f;
const i32 N = 96000;

f32* g_a;
f32* g_b;

f64 sine_at(i32 i, f64 hz, f64 sr) { return sin(2.0 * 3.141592653589793 * hz * cast(f64, i) / sr); }

void test_halfband() {
    halfband_design();
    print("half-band coefs:");
    for i32 i = 0; i < HB_COEFS; i++ { print(" {}", cast(f64, g_hb_coef[i])); }
    print("\n");

    // Round trip up -> down keeps passband sines at unit gain.
    f64[3] freqs = { 1000.0, 10000.0, 18000.0 };
    f64 worst_pass = 0.0;
    for i32 f = 0; f < 3; f++ {
        Halfband up;
        Halfband down;
        for i32 i = 0; i < N; i++ {
            f32 u0 = 0.0f;
            f32 u1 = 0.0f;
            halfband_up(&up, cast(f32, sine_at(i, freqs[f], SR)), &u0, &u1);
            g_a[i] = halfband_down(&down, u0, u1);
        }
        f64 d = fabs(db(tone_amplitude(&g_a[4800], N - 4800, freqs[f], SR)));
        if d > worst_pass { worst_pass = d; }
    }
    print("half-band round trip worst passband deviation {} dB\n", worst_pass);
    check(worst_pass < 0.05, "round trip is flat within 0.05 dB to 18 kHz");

    // Upsampling a 5 kHz sine: the image at 43 kHz in the 96 kHz stream.
    Halfband up2;
    for i32 i = 0; i < N / 2; i++ {
        f32 u0 = 0.0f;
        f32 u1 = 0.0f;
        halfband_up(&up2, cast(f32, sine_at(i, 5000.0, SR)), &u0, &u1);
        g_b[2 * i] = u0;
        g_b[2 * i + 1] = u1;
    }
    f64 wanted = tone_amplitude(&g_b[4800], N - 4800, 5000.0, 2.0 * SR);
    f64 image = tone_amplitude(&g_b[4800], N - 4800, 43000.0, 2.0 * SR);
    print("upsample: 5 kHz at {}, image at 43 kHz {} dB\n", wanted, db(image / wanted));
    check(fabs(wanted - 1.0) < 0.01, "upsampled 5 kHz keeps unit amplitude");
    check(db(image / wanted) < -70.0, "upsampling image below -70 dB");

    // Downsampling a 30 kHz tone from the 96 kHz stream: it must not
    // fold back to 18 kHz.
    Halfband down2;
    for i32 i = 0; i < N / 2; i++ {
        f32 s0 = cast(f32, sine_at(2 * i, 30000.0, 2.0 * SR));
        f32 s1 = cast(f32, sine_at(2 * i + 1, 30000.0, 2.0 * SR));
        g_a[i] = halfband_down(&down2, s0, s1);
    }
    f64 folded = tone_amplitude(&g_a[2400], N / 2 - 2400, 18000.0, SR);
    print("downsample: 30 kHz folds to 18 kHz at {} dB\n", db(folded));
    check(db(folded) < -70.0, "downsampling rejects 30 kHz by 70 dB");
}

// Gain of the ladder at hz, with a small input so the tanh stages stay linear.
f64 ladder_gain(f32 fc, f32 k, f64 hz) {
    Ladder l;
    ladder_init(&l);
    f64 amp = 0.001;
    for i32 i = 0; i < N; i++ {
        g_a[i] = ladder_process(&l, cast(f32, amp * sine_at(i, hz, SR)), fc, k, SR);
    }
    return tone_amplitude(&g_a[N / 2], N / 2, hz, SR) / amp;
}

void test_ladder_response() {
    f32 fc = 1000.0f;
    f64 at_fc = db(ladder_gain(fc, 0.0f, 1000.0));
    f64 at_2fc = db(ladder_gain(fc, 0.0f, 2000.0));
    f64 at_8fc = db(ladder_gain(fc, 0.0f, 8000.0));
    f64 at_16fc = db(ladder_gain(fc, 0.0f, 16000.0));
    f64 low = db(ladder_gain(fc, 0.0f, 50.0));
    print("ladder res 0, fc 1 kHz: 50 Hz {} dB, fc {} dB, 2fc {} dB, 8fc {} dB, 16fc {} dB\n",
          low, at_fc, at_2fc, at_8fc, at_16fc);
    check(fabs(low) < 0.1, "passband is flat at res 0");
    check(fabs(at_fc + 12.04) < 0.5, "-12 dB at the cutoff");
    check(fabs(at_2fc + 27.96) < 1.0, "-28 dB one octave above");
    check(fabs(at_8fc - at_16fc - 24.0) < 3.0, "24 dB per octave above the cutoff");

    // Passband gain 1 / (1 + k): resonance thins the bass.
    f64 bass = ladder_gain(fc, 2.0f, 50.0);
    check(fabs(bass - 1.0 / 3.0) < 0.01, "bass gain is 1 / (1 + k)");
}

// Self-oscillation frequency at k after a small kick. Low notes build up
// slowly, so this runs 5 s and measures the last second.
f64 self_osc_freq(f32 fc, f32 k, f32* peak) {
    Ladder l;
    ladder_init(&l);
    f32 last = 0.0f;
    for i32 i = 0; i < 5 * 48000; i++ {
        f32 kick = 0.0f;
        if i == 0 { kick = 0.05f; }
        f32 y = ladder_process(&l, kick, fc, k, SR);
        if i >= 4 * 48000 {
            g_a[i - 4 * 48000] = y;
            if fabsf(y) > last { last = fabsf(y); }
        }
    }
    *peak = last;
    return measure_freq(g_a, 48000, SR);
}

// The tanh stages lower the self-oscillation pitch by an amount set by the
// feedback, the same at every cutoff: the filter tracks 1 V/oct with a
// fixed offset, which the LOWPASS module can calibrate out.
void test_ladder_tracking() {
    f64 lo = 1e9;
    f64 hi = -1e9;
    f32 amp_lo = 10.0f;
    for i32 oct = 1; oct <= 7; oct++ {
        f32 fc = cast(f32, 32.703195662574829 * pow(2.0, cast(f64, oct - 1)));
        f32 amp = 0.0f;
        f64 c = cents(self_osc_freq(fc, 4.2f, &amp), fc);
        print("  C{}: offset {} cent, peak {}\n", oct, c, cast(f64, amp));
        if c < lo { lo = c; }
        if c > hi { hi = c; }
        if amp < amp_lo { amp_lo = amp; }
    }
    print("self-oscillation offset at k 4.2: {} .. {} cent\n", lo, hi);
    check(hi - lo < 1.0, "self-oscillation tracks 1 V/oct: same offset C1 to C7 within 1 cent");
    check(lo > -25.0 && hi < -15.0, "offset at k 4.2 stays near -20 cent");
    check(amp_lo > 0.05f, "self-oscillation is sustained at every octave");
}

void test_ladder_stress() {
    Rng r;
    rng_seed(&r, 99, 3);
    Ladder l;
    ladder_init(&l);
    f32 fc = 1000.0f;
    f32 k = 0.0f;
    f32 worst = 0.0f;
    bool finite = true;
    for i32 i = 0; i < 20 * 48000; i++ {
        if i % 64 == 0 {
            fc = 20.0f * exp2_fast((rng_uniform(&r) + 1.0f) * 5.0f);       // 20 Hz .. 20 kHz
            k = (rng_uniform(&r) + 1.0f) * 2.3f;                           // 0 .. 4.6
        }
        f32 y = ladder_process(&l, rng_uniform(&r) * 10.0f, fc, k, SR);
        if y != y { finite = false; }
        if fabsf(y) > worst { worst = fabsf(y); }
    }
    print("ladder stress peak {}\n", cast(f64, worst));
    check(finite, "ladder stays finite under random modulation and overdrive");
    check(worst < 10.0f, "ladder stays bounded under random modulation and overdrive");
}

f64 highpass_gain(f32 fc, f64 hz) {
    HighPass4 h;
    f32 g = prewarp(fc, SR);
    for i32 i = 0; i < N; i++ {
        g_a[i] = highpass4_process(&h, cast(f32, sine_at(i, hz, SR)), g);
    }
    return tone_amplitude(&g_a[N / 2], N / 2, hz, SR);
}

void test_highpass() {
    f64 at_fc = db(highpass_gain(1000.0f, 1000.0));
    f64 below = db(highpass_gain(1000.0f, 500.0));
    f64 above = db(highpass_gain(1000.0f, 4000.0));
    print("highpass fc 1 kHz: fc/2 {} dB, fc {} dB, 4fc {} dB\n", below, at_fc, above);
    check(fabs(at_fc + 12.04) < 0.5, "high-pass is -12 dB at the cutoff");
    check(fabs(below + 27.96) < 1.0, "high-pass is -28 dB one octave below");
    check(fabs(above + 1.05) < 0.5, "high-pass passes two octaves above");
}

i32 main() {
    g_a = alloc<f32>(N);
    g_b = alloc<f32>(N);
    defer free(g_a);
    defer free(g_b);
    test_halfband();
    test_ladder_response();
    test_ladder_tracking();
    test_ladder_stress();
    test_highpass();
    return check_done();
}
