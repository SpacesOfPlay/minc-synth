// dsp_math.mc: numeric building blocks shared by the DSP modules.
//
// Fast approximations with known error bounds (checked in
// test/test_math.mc), a PRNG, one-pole smoothing, and helpers for
// passing f32 values through u32 atomics.

import math;

const f32 PI = 3.14159265f;
const f32 TWO_PI = 6.28318531f;
const f32 C4_HZ = 261.625565f;          // 0 V on a pitch input

// ---- bit casts ----

unsafe_union FloatBits { u32 u; f32 f; }

u32 f32_bits(f32 v) { FloatBits b = FloatBits{ .f = v }; return b.u; }
f32 bits_f32(u32 v) { FloatBits b = FloatBits{ .u = v }; return b.f; }

// ---- small helpers ----

// Strict-compare ternaries: one min/max instruction, no branch, and small
// enough that everything built on them inlines. The library fminf/fmaxf
// also order NaNs and signed zeros, which keeps them a call on every use;
// sample paths never hold either.
f32 minf(f32 a, f32 b) { return a < b ? a : b; }
f32 maxf(f32 a, f32 b) { return a > b ? a : b; }
f32 clampf(f32 x, f32 lo, f32 hi) { return minf(maxf(x, lo), hi); }

i32 clampi(i32 x, i32 lo, i32 hi) {
    if x < lo { return lo; }
    if x > hi { return hi; }
    return x;
}

i32 maxi(i32 a, i32 b) { return a > b ? a : b; }

// IIR states that decay into subnormals slow x64 down; snap them to 0.
f32 flush_denormal(f32 x) {
    if fabsf(x) < 1e-20f { return 0.0f; }
    return x;
}

// ---- exp2 ----

// 2^x. Range-reduced to f in [-0.5, 0.5] and a degree-6 Taylor series
// of e^(f ln 2): relative error below 2e-7, about 0.0003 cent as a pitch.
f32 exp2_fast(f32 x) {
    if x < -126.0f { return 0.0f; }
    f32 xc = x;
    if xc > 127.0f { xc = 127.0f; }
    f32 n = floorf(xc + 0.5f);
    f32 f = xc - n;
    f32 p = 1.0f + f * (0.693147181f + f * (0.240226507f + f * (0.0555041087f
          + f * (0.00961812911f + f * (0.00133335581f + f * 0.000154035304f)))));
    return p * bits_f32(cast(u32, cast(i32, n) + 127) << 23);
}

// Frequency in Hz of a 1 V/oct pitch voltage, 0 V = C4.
f32 volts_to_hz(f32 v) { return C4_HZ * exp2_fast(v); }

// ---- tanh ----

// tanh(x) / x from the [7/6] continued-fraction approximant. Absolute
// error of x * tanh_ratio(x) against tanh is below 2e-4 everywhere. The
// ratio form is what the ladder filter's linearized stages need.
f32 tanh_ratio(f32 x) {
    f32 x2 = x * x;
    if x2 > 24.7f { return 1.0f / fabsf(x); }       // |x| > 4.97: the approximant passes 1
    f32 num = 135135.0f + x2 * (17325.0f + x2 * (378.0f + x2));
    f32 den = 135135.0f + x2 * (62370.0f + x2 * (3150.0f + x2 * 28.0f));
    return num / den;
}

f32 tanh_accurate(f32 x) { return x * tanh_ratio(x); }

// Cheap saturator: odd, monotonic, reaches exactly +-1 at +-3 with zero
// slope. Deviates from tanh by up to 0.025, so it is a shape, not tanh.
f32 tanh_fast(f32 x) {
    // At +-3 the approximant is exactly +-1, so clamping the input gives
    // the flat top without branches (small enough to inline).
    f32 c = clampf(x, -3.0f, 3.0f);
    f32 x2 = c * c;
    // Rounding on the flat top near +-3 can land one ulp past 1.
    return clampf(c * (27.0f + x2) / (27.0f + 9.0f * x2), -1.0f, 1.0f);
}

// ---- sine ----

// sin(2 pi t) for a phase t in cycles. Folded to a quarter wave and a
// degree-9 Taylor series: absolute error below 4e-6.
f32 sin_cycle(f32 t) {
    f32 u = t - floorf(t + 0.5f);                   // [-0.5, 0.5)
    if u > 0.25f { u = 0.5f - u; }
    else if u < -0.25f { u = -0.5f - u; }
    f32 x = u * TWO_PI;                             // [-pi/2, pi/2]
    f32 x2 = x * x;
    return x * (1.0f + x2 * (-0.166666667f + x2 * (0.00833333333f
          + x2 * (-0.000198412698f + x2 * 0.00000275573192f))));
}

// ---- PRNG ----

// PCG32 (O'Neill). Every noise source owns one, seeded, so renders repeat.
struct Rng {
    u64 state;
    u64 inc;
}

u32 rng_next(Rng* r) {
    u64 old = r.state;
    r.state = old * 6364136223846793005 + r.inc;
    u32 xorshifted = cast(u32, ((old >> 18) ^ old) >> 27);
    u32 rot = cast(u32, old >> 59);
    return (xorshifted >> rot) | (xorshifted << ((32 - rot) & 31));
}

void rng_seed(Rng* r, u64 seed, u64 stream) {
    r.state = 0;
    r.inc = (stream << 1) | 1;
    ignore rng_next(r);
    r.state += seed;
    ignore rng_next(r);
}

// Uniform in [-1, 1).
f32 rng_uniform(Rng* r) {
    return cast(f32, cast(i32, rng_next(r))) * (1.0f / 2147483648.0f);
}

// ---- filters ----

// tan(x) for 0 <= x < pi/2 as sine over cosine, each from its Taylor
// series: relative error about 1e-7. The library tan also reduces huge
// arguments, a path that is always a call and so keeps every caller from
// inlining; cutoffs never need it.
f32 tan_quadrant(f32 x) {
    f32 x2 = x * x;
    f32 s = x * (1.0f + x2 * (-1.6666667e-1f + x2 * (8.3333333e-3f + x2 * (-1.9841270e-4f
          + x2 * (2.7557319e-6f + x2 * -2.5052108e-8f)))));
    f32 c = 1.0f + x2 * (-0.5f + x2 * (4.1666667e-2f + x2 * (-1.3888889e-3f + x2 * (2.4801587e-5f
          + x2 * (-2.7557319e-7f + x2 * 2.0876757e-9f)))));
    return s / c;
}

// Trapezoidal integrator gain for a cutoff in Hz, clamped below Nyquist.
f32 prewarp(f32 fc, f32 sample_rate) {
    f32 f = clampf(fc, 1.0f, 0.49f * sample_rate);
    return tan_quadrant(PI * f / sample_rate);
}

// A cutoff's prewarped gain from its 1 V/oct voltage, worked out again
// only when the voltage or the rate changes: most cutoffs sit still
// between knob moves.
struct Cutoff {
    f32 volts;
    f32 rate;
    f32 g;
}

f32 cutoff_g(Cutoff* c, f32 volts, f32 sample_rate) {
    if volts != c.volts || sample_rate != c.rate {
        c.volts = volts;
        c.rate = sample_rate;
        c.g = prewarp(volts_to_hz(volts), sample_rate);
    }
    return c.g;
}

// ---- smoothing ----

// Per-sample coefficient of a one-pole lowpass with time constant tau.
f32 onepole_coef(f32 tau_s, f32 sample_rate) {
    if tau_s <= 0.0f { return 1.0f; }
    return 1.0f - exp(-1.0f / (tau_s * sample_rate));
}

// One-pole smoother for parameters and slews.
struct Smooth {
    f32 y;
    f32 a;
}

void smooth_init(Smooth* s, f32 tau_s, f32 sample_rate, f32 value) {
    s.a = onepole_coef(tau_s, sample_rate);
    s.y = value;
}

f32 smooth_step(Smooth* s, f32 target) {
    s.y += s.a * (target - s.y);
    return s.y;
}
