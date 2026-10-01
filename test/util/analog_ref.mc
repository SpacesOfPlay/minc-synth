// analog_ref.mc: analog references and measurements (plan.md section 8a).
//
// All f64, and apart from the product code: exact transfer functions of
// the analog prototypes, the ladder's equations solved with RK4 at a
// high rate, ideal band-limited waveforms, exact RC envelope curves, the
// analog model of a feedback patch, and the tools to compare them with
// digital output.

import math;

const f64 PI_D = 3.141592653589793;
const f64 TAU_D = 6.283185307179586;
const f64 C4_HZ_D = 261.6255653005986;

// ---- complex numbers ----

struct Cx {
    f64 re;
    f64 im;
}

Cx cx_add(Cx a, Cx b) { return Cx{ a.re + b.re, a.im + b.im }; }
Cx cx_sub(Cx a, Cx b) { return Cx{ a.re - b.re, a.im - b.im }; }
Cx cx_mul(Cx a, Cx b) { return Cx{ a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re }; }
Cx cx_scale(Cx a, f64 s) { return Cx{ a.re * s, a.im * s }; }
Cx cx_div(Cx a, Cx b) {
    f64 d = b.re * b.re + b.im * b.im;
    return Cx{ (a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d };
}
f64 cx_abs(Cx a) { return sqrt(a.re * a.re + a.im * a.im); }
f64 cx_arg(Cx a) { return atan2(a.im, a.re); }
Cx cx_expj(f64 th) { return Cx{ cos(th), sin(th) }; }

f64 db_d(f64 ratio) { return 20.0 * log(ratio) / log(10.0); }
f64 deg(f64 rad) { return rad * 180.0 / PI_D; }

// Wraps a phase difference into (-pi, pi].
f64 wrap_pi(f64 a) {
    f64 x = fmod(a + PI_D, TAU_D);
    if x < 0.0 { x += TAU_D; }
    return x - PI_D;
}

// ---- analog transfer functions, s = j 2 pi f ----

Cx onepole_lp_h(f64 f, f64 fc) {
    f64 w = TAU_D * f;
    f64 wc = TAU_D * fc;
    return cx_div(Cx{ wc, 0.0 }, Cx{ wc, w });
}

// Ladder, small signal: G^4 / (1 + k G^4), G the one-pole low-pass.
Cx ladder_h(f64 f, f64 fc, f64 k) {
    Cx g = onepole_lp_h(f, fc);
    Cx g4 = cx_mul(cx_mul(g, g), cx_mul(g, g));
    return cx_div(g4, cx_add(Cx{ 1.0, 0.0 }, cx_scale(g4, k)));
}

Cx hp4_h(f64 f, f64 fc) {
    f64 w = TAU_D * f;
    f64 wc = TAU_D * fc;
    Cx h = cx_div(Cx{ 0.0, w }, Cx{ wc, w });
    return cx_mul(cx_mul(h, h), cx_mul(h, h));
}

enum SvfOutput { SVF_LOW, SVF_BAND, SVF_HIGH }

// 2-pole state-variable responses; the band output has unity peak.
Cx svf_h(f64 f, f64 fc, f64 q, i32 which) {
    f64 w = TAU_D * f;
    f64 wc = TAU_D * fc;
    Cx den = Cx{ wc * wc - w * w, w * wc / q };
    if which == SVF_LOW { return cx_div(Cx{ wc * wc, 0.0 }, den); }
    if which == SVF_BAND { return cx_div(Cx{ 0.0, w * wc / q }, den); }
    return cx_div(Cx{ -w * w, 0.0 }, den);
}

// ---- measurement ----

// Complex amplitude of the component at f in x[0..n): A e^(j theta) for
// A cos(2 pi f t + theta). Exact when the window holds whole periods.
Cx dft_at(f64* x, i32 n, f64 f, f64 sr) {
    f64 w = TAU_D * f / sr;
    f64 c = cos(w);
    f64 s = sin(w);
    f64 re = 0.0;
    f64 im = 0.0;
    f64 cr = 1.0;
    f64 ci = 0.0;
    for i32 i = 0; i < n; i++ {
        // The rotation drifts; restart it from the exact angle now and then.
        if (i & 255) == 0 {
            cr = cos(w * cast(f64, i));
            ci = sin(w * cast(f64, i));
        }
        re += x[i] * cr;
        im -= x[i] * ci;
        f64 t = cr * c - ci * s;
        ci = ci * c + cr * s;
        cr = t;
    }
    return Cx{ re * 2.0 / cast(f64, n), im * 2.0 / cast(f64, n) };
}

// Fourier coefficients of the ideal waveforms at harmonic h, in the
// dft_at convention (A e^(j theta) for A cos(h 2 pi phase + theta)).
Cx saw_coef(i32 h) { return Cx{ 0.0, 2.0 / (PI_D * cast(f64, h)) }; }

Cx pulse_coef(i32 h, f64 pw) {
    f64 hf = cast(f64, h);
    return cx_scale(cx_expj(-PI_D * hf * pw), 4.0 / (PI_D * hf) * sin(PI_D * hf * pw));
}

Cx tri_coef(i32 h) {
    if h % 2 == 0 { return Cx{ 0.0, 0.0 }; }
    f64 hf = cast(f64, h);
    return Cx{ -8.0 / (PI_D * PI_D * hf * hf), 0.0 };
}

Cx sine_coef(i32 h) {
    if h == 1 { return Cx{ -1.0, 0.0 }; }
    return Cx{ 0.0, 0.0 };
}

f64 energy(f64* x, i32 n) {
    f64 s = 0.0;
    for i32 i = 0; i < n; i++ { s += x[i] * x[i]; }
    return s / cast(f64, n);
}

// Error-to-signal ratio of two sets of complex amplitudes, in dB.
f64 esr_db(Cx* got, Cx* want, i32 n) {
    f64 e = 0.0;
    f64 s = 0.0;
    for i32 i = 0; i < n; i++ {
        Cx d = cx_sub(got[i], want[i]);
        e += d.re * d.re + d.im * d.im;
        s += want[i].re * want[i].re + want[i].im * want[i].im;
    }
    return 10.0 * log(e / s) / log(10.0);
}

// Frequency from rising zero crossings with linear interpolation.
f64 freq_of(f64* x, i32 n, f64 sr) {
    f64 first = -1.0;
    f64 last = -1.0;
    i32 count = 0;
    for i32 i = 1; i < n; i++ {
        if x[i - 1] < 0.0 && x[i] >= 0.0 {
            f64 t = cast(f64, i - 1) - x[i - 1] / (x[i] - x[i - 1]);
            if count == 0 { first = t; }
            last = t;
            count++;
        }
    }
    if count < 2 { return 0.0; }
    return cast(f64, count - 1) * sr / (last - first);
}

f64 peak_of(f64* x, i32 n) {
    f64 p = 0.0;
    for i32 i = 0; i < n; i++ { if fabs(x[i]) > p { p = fabs(x[i]); } }
    return p;
}

// ---- ladder, nonlinear, RK4 ----
//
// Stage i: y_i' = wc (tanh(x_i) - tanh(y_i)), x_1 = u - k y_4, x_i = y_(i-1).

struct LadderRef {
    f64[4] y;
    f64 wc;
    f64 k;
}

void ladder_ref_init(LadderRef* r, f64 fc, f64 k) {
    *r = LadderRef{};
    r.wc = TAU_D * fc;
    r.k = k;
}

void ladder_ref_deriv(LadderRef* r, f64 u, f64* y, f64* dy) {
    f64 t0 = tanh(u - r.k * y[3]);
    f64 t1 = tanh(y[0]);
    f64 t2 = tanh(y[1]);
    f64 t3 = tanh(y[2]);
    f64 t4 = tanh(y[3]);
    dy[0] = r.wc * (t0 - t1);
    dy[1] = r.wc * (t1 - t2);
    dy[2] = r.wc * (t2 - t3);
    dy[3] = r.wc * (t3 - t4);
}

// One RK4 step of length h; u0, um, u1 are the input at the start,
// middle and end of the step.
void ladder_ref_step(LadderRef* r, f64 u0, f64 um, f64 u1, f64 h) {
    f64[4] k1;
    f64[4] k2;
    f64[4] k3;
    f64[4] k4;
    f64[4] t;
    ladder_ref_deriv(r, u0, &r.y[0], &k1[0]);
    for i32 i = 0; i < 4; i++ { t[i] = r.y[i] + 0.5 * h * k1[i]; }
    ladder_ref_deriv(r, um, &t[0], &k2[0]);
    for i32 i = 0; i < 4; i++ { t[i] = r.y[i] + 0.5 * h * k2[i]; }
    ladder_ref_deriv(r, um, &t[0], &k3[0]);
    for i32 i = 0; i < 4; i++ { t[i] = r.y[i] + h * k3[i]; }
    ladder_ref_deriv(r, u1, &t[0], &k4[0]);
    for i32 i = 0; i < 4; i++ { r.y[i] += h / 6.0 * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i]); }
}

// ---- ideal band-limited waveforms, phase in cycles, H harmonics ----

f64 saw_bl(f64 phi, i32 harmonics) {
    f64 s = 0.0;
    for i32 h = 1; h <= harmonics; h++ { s += sin(TAU_D * cast(f64, h) * phi) / cast(f64, h); }
    return -2.0 / PI_D * s;
}

f64 tri_bl(f64 phi, i32 harmonics) {
    f64 s = 0.0;
    for i32 h = 1; h <= harmonics; h += 2 { s += cos(TAU_D * cast(f64, h) * phi) / cast(f64, h * h); }
    return -8.0 / (PI_D * PI_D) * s;
}

f64 pulse_bl(f64 phi, f64 pw, i32 harmonics) {
    f64 s = 2.0 * pw - 1.0;
    for i32 h = 1; h <= harmonics; h++ {
        f64 hf = cast(f64, h);
        s += 4.0 / (PI_D * hf) * sin(PI_D * hf * pw) * cos(TAU_D * hf * (phi - 0.5 * pw));
    }
    return s;
}

// ---- envelope, exact RC curves ----

// Level t seconds after the gate rises from silence, gate held: the RC
// charge toward 1.5 reaches full level at exactly `attack`, then decays
// toward `sustain`, covering 99 % of the way in `decay`.
f64 env_ref_ad(f64 t, f64 attack, f64 decay, f64 sustain) {
    if t < attack { return 1.5 * (1.0 - exp(-t * log(3.0) / attack)); }
    return sustain + (1.0 - sustain) * exp(-(t - attack) * log(100.0) / decay);
}

// ---- statistics ----

// Total variation distance between the amplitude histograms of a and b
// over [lo, hi): 0 for identical distributions, 1 for disjoint ones.
f64 hist_distance(f64* a, i32 na, f64* b, i32 nb, f64 lo, f64 hi) {
    i32 bins = 40;
    f64[40] ha;
    f64[40] hb;
    for i32 i = 0; i < na; i++ {
        i32 k = cast(i32, (a[i] - lo) / (hi - lo) * cast(f64, bins));
        if k < 0 { k = 0; }
        if k >= bins { k = bins - 1; }
        ha[k] += 1.0 / cast(f64, na);
    }
    for i32 i = 0; i < nb; i++ {
        i32 k = cast(i32, (b[i] - lo) / (hi - lo) * cast(f64, bins));
        if k < 0 { k = 0; }
        if k >= bins { k = bins - 1; }
        hb[k] += 1.0 / cast(f64, nb);
    }
    f64 d = 0.0;
    for i32 k = 0; k < bins; k++ { d += fabs(ha[k] - hb[k]); }
    return 0.5 * d;
}

// Energy in octave bands centred at 62.5 Hz * 2^i, through a one-octave
// f64 state-variable band-pass, in dB.
void octave_bands(f64* x, i32 n, f64 sr, f64* out_db, i32 bands) {
    for i32 b = 0; b < bands; b++ {
        f64 fc = 62.5 * pow(2.0, cast(f64, b));
        f64 g = tan(PI_D * fc / sr);
        f64 k = 1.0 / 1.41421356;
        f64 a1 = 1.0 / (1.0 + g * (g + k));
        f64 a2 = g * a1;
        f64 a3 = g * a2;
        f64 ic1 = 0.0;
        f64 ic2 = 0.0;
        f64 sum = 0.0;
        for i32 i = 0; i < n; i++ {
            f64 v3 = x[i] - ic2;
            f64 v1 = a1 * ic1 + a2 * v3;
            f64 v2 = ic2 + a2 * ic1 + a3 * v3;
            ic1 = 2.0 * v1 - ic1;
            ic2 = 2.0 * v2 - ic2;
            f64 bp = v1 * k;
            sum += bp * bp;
        }
        out_db[b] = 10.0 * log(sum / cast(f64, n) + 1e-30) / log(10.0);
    }
}

// Least-squares slope of y against x.
f64 slope(f64* x, f64* y, i32 n) {
    f64 mx = 0.0;
    f64 my = 0.0;
    for i32 i = 0; i < n; i++ {
        mx += x[i];
        my += y[i];
    }
    mx /= cast(f64, n);
    my /= cast(f64, n);
    f64 sxy = 0.0;
    f64 sxx = 0.0;
    for i32 i = 0; i < n; i++ {
        sxy += (x[i] - mx) * (y[i] - my);
        sxx += (x[i] - mx) * (x[i] - mx);
    }
    return sxy / sxx;
}

// ---- the FM feedback patch: OSC.sine -> LOWPASS -> MIX -> OSC.pitch1 ----
//
// phase' = C4 * 2^(pitch + 5 depth y4)    MIX out is audio, 5 V per unit
// ladder as above, driven by the OSC sine -cos(2 pi phase)
// LOWPASS out is y4 with drive 1 and comp 0. State: phase, y1..y4.

struct FmLoopRef {
    f64[5] s;               // phase in cycles, then the four ladder stages
    f64 pitch;              // OSC octave + fine, volts
    f64 depth;              // MIX level on the loop
    f64 wc;
    f64 k;
    f64 max_hz;             // highest oscillator frequency reached
}

void fm_ref_init(FmLoopRef* r, f64 pitch, f64 depth, f64 cutoff_v, f64 res) {
    *r = FmLoopRef{};
    r.pitch = pitch;
    r.depth = depth;
    r.wc = TAU_D * C4_HZ_D * pow(2.0, cutoff_v);
    r.k = res * 4.2;
}

void fm_ref_deriv(FmLoopRef* r, f64* s, f64* ds) {
    f64 hz = C4_HZ_D * pow(2.0, r.pitch + 5.0 * r.depth * s[4]);
    if hz > r.max_hz { r.max_hz = hz; }
    ds[0] = hz;
    f64 u = -cos(TAU_D * s[0]);
    f64 t0 = tanh(u - r.k * s[4]);
    f64 t1 = tanh(s[1]);
    f64 t2 = tanh(s[2]);
    f64 t3 = tanh(s[3]);
    f64 t4 = tanh(s[4]);
    ds[1] = r.wc * (t0 - t1);
    ds[2] = r.wc * (t1 - t2);
    ds[3] = r.wc * (t2 - t3);
    ds[4] = r.wc * (t3 - t4);
}

void fm_ref_step(FmLoopRef* r, f64 h) {
    f64[5] k1;
    f64[5] k2;
    f64[5] k3;
    f64[5] k4;
    f64[5] t;
    fm_ref_deriv(r, &r.s[0], &k1[0]);
    for i32 i = 0; i < 5; i++ { t[i] = r.s[i] + 0.5 * h * k1[i]; }
    fm_ref_deriv(r, &t[0], &k2[0]);
    for i32 i = 0; i < 5; i++ { t[i] = r.s[i] + 0.5 * h * k2[i]; }
    fm_ref_deriv(r, &t[0], &k3[0]);
    for i32 i = 0; i < 5; i++ { t[i] = r.s[i] + h * k3[i]; }
    fm_ref_deriv(r, &t[0], &k4[0]);
    for i32 i = 0; i < 5; i++ { r.s[i] += h / 6.0 * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i]); }
    r.s[0] -= floor(r.s[0]);                     // keep the phase in [0, 1)
}
