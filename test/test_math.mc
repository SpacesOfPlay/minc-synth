// test_math.mc: error bounds of the fast math in dsp_math.mc.

import math;
import "../src/dsp_math.mc";
import "util/check.mc";

void test_exp2() {
    // Pitch range and beyond: -12..+12 octaves, relative error as cents.
    f64 worst = 0.0;
    for i32 i = -24000; i <= 24000; i++ {
        f32 x = cast(f32, i) * 0.0005f;
        f64 want = exp(cast(f64, x) * 0.6931471805599453);
        f64 got = exp2_fast(x);
        f64 c = fabs(cents(got, want));
        if c > worst { worst = c; }
    }
    print("exp2_fast worst error {} cent\n", worst);
    check(worst < 0.001, "exp2_fast within 0.001 cent over -12..+12");
    check(exp2_fast(0.0f) == 1.0f, "exp2_fast(0) is exactly 1");
    check(exp2_fast(-200.0f) == 0.0f, "exp2_fast underflows to 0");
    check(fabs(cents(volts_to_hz(1.0f), 523.2511306011972)) < 0.001, "1 V is C5");
}

void test_tanh() {
    f64 worst_acc = 0.0;
    f64 worst_fast = 0.0;
    bool monotonic = true;
    bool bounded = true;
    f32 prev = -2.0f;
    for i32 i = -8000; i <= 8000; i++ {
        f32 x = cast(f32, i) * 0.001f;
        f64 want = tanh(cast(f64, x));
        f64 ea = fabs(cast(f64, tanh_accurate(x)) - want);
        f64 ef = fabs(cast(f64, tanh_fast(x)) - want);
        if ea > worst_acc { worst_acc = ea; }
        if ef > worst_fast { worst_fast = ef; }
        // Non-decreasing up to f32 rounding on the flat top.
        f32 y = tanh_fast(x);
        if y < prev - 1e-6f { monotonic = false; }
        if fabsf(y) > 1.0f { bounded = false; }
        prev = y;
    }
    print("tanh_accurate worst {}, tanh_fast worst {}\n", worst_acc, worst_fast);
    check(worst_acc < 2e-4, "tanh_accurate within 2e-4");
    check(worst_fast < 0.03, "tanh_fast within 0.03");
    check(monotonic, "tanh_fast is monotonic");
    check(bounded, "tanh_fast stays within +-1");
    check(tanh_fast(0.5f) == -tanh_fast(-0.5f), "tanh_fast is odd");
    check(fabsf(tanh_ratio(20.0f) - 0.05f) < 1e-6f, "tanh_ratio falls back to 1/|x|");
}

void test_sin() {
    f64 worst = 0.0;
    for i32 i = -20000; i <= 20000; i++ {
        f32 t = cast(f32, i) * 0.0001f;             // -2..+2 cycles
        f64 want = sin(2.0 * 3.141592653589793 * cast(f64, t));
        f64 e = fabs(cast(f64, sin_cycle(t)) - want);
        if e > worst { worst = e; }
    }
    print("sin_cycle worst {}\n", worst);
    check(worst < 1e-5, "sin_cycle within 1e-5");
}

// The cutoff prewarp's tan, against f64 tan up to 0.49 pi (the highest
// cutoff below Nyquist). What a filter hears is the cutoff the gain
// implies, atan(g); near pi/2 that is far less sensitive than g itself.
void test_tan() {
    f64 worst = 0.0;
    f64 worst_cents = 0.0;
    for i32 i = 1; i <= 49000; i++ {
        f32 x = cast(f32, i) * (0.49f * PI / 49000.0f);
        f64 g = tan_quadrant(x);
        f64 e = fabs(g / tan(cast(f64, x)) - 1.0);
        if e > worst { worst = e; }
        f64 c = fabs(1200.0 * log(atan(g) / cast(f64, x)) / log(2.0));
        if c > worst_cents { worst_cents = c; }
    }
    print("tan_quadrant worst: {} relative, {} cent in the cutoff\n", worst, worst_cents);
    check(worst < 5e-6, "tan_quadrant within 5e-6, relative, up to 0.49 pi");
    check(worst_cents < 0.001, "the prewarped cutoff within 0.001 cent");
}

void test_rng() {
    // The PCG32 reference sequence (pcg-c-basic demo, seed 42, stream 54).
    Rng ref;
    rng_seed(&ref, 42, 54);
    u32[6] want = { 0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b, 0xcbed606e };
    bool match = true;
    for i32 i = 0; i < 6; i++ {
        u32 v = rng_next(&ref);
        if v != want[i] { match = false; }
    }
    check(match, "PCG32 matches the reference sequence");

    Rng r;
    rng_seed(&r, 42, 7);
    f64 sum = 0.0;
    f32 lo = 1.0f;
    f32 hi = -1.0f;
    i32 n = 1000000;
    for i32 i = 0; i < n; i++ {
        f32 u = rng_uniform(&r);
        sum += u;
        if u < lo { lo = u; }
        if u > hi { hi = u; }
    }
    check(lo >= -1.0f && hi < 1.0f, "rng_uniform stays in [-1, 1)");
    check(lo < -0.999f && hi > 0.999f, "rng_uniform covers the range");
    check(fabs(sum / cast(f64, n)) < 0.005, "rng_uniform mean near 0");

    Rng a;
    Rng b;
    rng_seed(&a, 1234, 1);
    rng_seed(&b, 1234, 1);
    bool same = true;
    for i32 i = 0; i < 1000; i++ {
        if rng_next(&a) != rng_next(&b) { same = false; }
    }
    check(same, "same seed, same sequence");
}

void test_smooth() {
    // After one time constant a step has covered 1 - 1/e of the distance.
    Smooth s;
    smooth_init(&s, 0.01f, 48000.0f, 0.0f);
    for i32 i = 0; i < 480; i++ { ignore smooth_step(&s, 1.0f); }
    check(fabsf(s.y - 0.632f) < 0.005f, "smoother reaches 63% after one tau");
    check(flush_denormal(1e-30f) == 0.0f, "flush_denormal snaps tiny values");
    check(flush_denormal(0.5f) == 0.5f, "flush_denormal keeps normal values");
}

i32 main() {
    test_exp2();
    test_tanh();
    test_sin();
    test_tan();
    test_rng();
    test_smooth();
    return check_done();
}
