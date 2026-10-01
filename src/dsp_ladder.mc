// dsp_ladder.mc: transistor-ladder style filters and the 2x oversampler.
//
// Ladder: four one-pole stages with tanh saturation and global negative
// feedback, discretized with the trapezoidal (TPT) integrator. Each tanh
// is linearized per sample as tanh(x)/x taken at the previous sample's
// signal ("cheap" nonlinear zero-delay feedback), which leaves a linear
// loop that is solved exactly. It runs at twice the sample rate through
// a polyphase IIR half-band pair, so the saturation aliases less.
//
// HighPass4 and LowPass4: four linear TPT one-pole stages, 24 dB/oct.

import math;
import dsp_math;

// ---- half-band oversampler ----
//
// Polyphase IIR half-band (Valenzuela-Constantinides), the structure of
// Laurent de Soras' HIIR: two chains of first-order allpass sections,
// one per polyphase branch. Coefficients come from the elliptic design.

const i32 HB_COEFS = 8;
const f64 HB_TRANSITION = 0.1;      // transition width relative to the oversampled rate

struct Halfband {
    f32[HB_COEFS] x;                // allpass section inputs, one sample back
    f32[HB_COEFS] y;                // allpass section outputs, one sample back
}

f32[HB_COEFS] g_hb_coef;
bool g_hb_ready = false;

private {
    f64 hb_acc_num(f64 q, i32 order, i32 c) {
        f64 result = 0.0;
        f64 sign = 1.0;
        for i32 i = 0; i < 40; i++ {
            f64 acc = pow(q, cast(f64, i * (i + 1))) * sin(cast(f64, (i * 2 + 1) * c) * 3.141592653589793 / cast(f64, order)) * sign;
            result += acc;
            sign = -sign;
            if fabs(acc) < 1e-100 { break; }
        }
        return result;
    }

    f64 hb_acc_den(f64 q, i32 order, i32 c) {
        f64 result = 0.0;
        f64 sign = -1.0;
        for i32 i = 1; i < 40; i++ {
            f64 acc = pow(q, cast(f64, i * i)) * cos(cast(f64, i * 2 * c) * 3.141592653589793 / cast(f64, order)) * sign;
            result += acc;
            sign = -sign;
            if fabs(acc) < 1e-100 { break; }
        }
        return result;
    }

    // One section: first-order allpass (c + z^-1) / (1 + c z^-1).
    f32 hb_section(Halfband* h, i32 i, f32 v) {
        f32 out = (v - h.y[i]) * g_hb_coef[i] + h.x[i];
        h.x[i] = v;
        h.y[i] = out;
        return out;
    }
}

// Designs the shared coefficients once; later calls return at once.
void halfband_design() {
    if g_hb_ready { return; }
    f64 k = tan((1.0 - HB_TRANSITION * 2.0) * 3.141592653589793 / 4.0);
    k *= k;
    f64 kksqrt = pow(1.0 - k * k, 0.25);
    f64 e = 0.5 * (1.0 - kksqrt) / (1.0 + kksqrt);
    f64 e2 = e * e;
    f64 e4 = e2 * e2;
    f64 q = e * (1.0 + e4 * (2.0 + e4 * (15.0 + 150.0 * e4)));
    i32 order = HB_COEFS * 2 + 1;
    for i32 index = 0; index < HB_COEFS; index++ {
        i32 c = index + 1;
        f64 num = hb_acc_num(q, order, c) * pow(q, 0.25);
        f64 den = hb_acc_den(q, order, c) + 0.5;
        f64 ww = num / den;
        f64 wwsq = ww * ww;
        f64 x = sqrt((1.0 - wwsq * k) * (1.0 - wwsq / k)) / (1.0 + wwsq);
        g_hb_coef[index] = cast(f32, (1.0 - x) / (1.0 + x));
    }
    g_hb_ready = true;
}

// Even-index sections form branch 0, odd-index sections branch 1.
void halfband_branches(Halfband* h, f32* b0, f32* b1) {
    for i32 i = 0; i < HB_COEFS; i += 2 {
        *b0 = hb_section(h, i, *b0);
        *b1 = hb_section(h, i + 1, *b1);
    }
}

// One input sample in, two output samples at twice the rate.
void halfband_up(Halfband* h, f32 input, f32* out0, f32* out1) {
    f32 b0 = input;
    f32 b1 = input;
    halfband_branches(h, &b0, &b1);
    *out0 = b0;
    *out1 = b1;
}

// Two input samples at twice the rate in, one output sample.
f32 halfband_down(Halfband* h, f32 in0, f32 in1) {
    f32 b0 = in1;
    f32 b1 = in0;
    halfband_branches(h, &b0, &b1);
    return 0.5f * (b0 + b1);
}

// ---- ladder low-pass ----

struct Ladder {
    f32[4] s;                       // integrator states
    f32[4] y;                       // stage outputs, one oversampled step back
    f32 x1;                         // first-stage input, one step back
    Halfband up;
    Halfband down;
}

void ladder_init(Ladder* l) {
    halfband_design();
    *l = Ladder{};
}

// Solver passes per step. The first linearizes the tanh stages at the
// previous step's signals; the second re-linearizes at the first pass's
// result. One pass lags enough to detune self-oscillation by an amount
// that changes with pitch; two make the offset independent of pitch,
// and a third changes nothing measurable.
const i32 LADDER_PASSES = 2;

// One step at the oversampled rate. g: prewarped gain, k: feedback.
f32 ladder_step(Ladder* l, f32 input, f32 g, f32 k) {
    // Signals the tanh stages are linearized at: last step's to start.
    f32 e0 = l.x1;
    f32 e1 = l.y[0];
    f32 e2 = l.y[1];
    f32 e3 = l.y[2];
    f32 e4 = l.y[3];
    f32 x1 = 0.0f;
    f32 y1 = 0.0f;
    f32 y2 = 0.0f;
    f32 y3 = 0.0f;
    f32 y4 = 0.0f;
    for i32 pass = 0; pass < LADDER_PASSES; pass++ {
        // tanh(v)/v: r0 for the input, r1..r4 per stage.
        f32 r0 = tanh_ratio(e0);
        f32 r1 = tanh_ratio(e1);
        f32 r2 = tanh_ratio(e2);
        f32 r3 = tanh_ratio(e3);
        f32 r4 = tanh_ratio(e4);

        // Stage i: y = a * x + b, from y = s + g * (r_in * x - r_out * y).
        f32 d1 = 1.0f / (1.0f + g * r1);
        f32 d2 = 1.0f / (1.0f + g * r2);
        f32 d3 = 1.0f / (1.0f + g * r3);
        f32 d4 = 1.0f / (1.0f + g * r4);
        f32 a1 = g * r0 * d1;
        f32 a2 = g * r1 * d2;
        f32 a3 = g * r2 * d3;
        f32 a4 = g * r3 * d4;
        f32 b1 = l.s[0] * d1;
        f32 b2 = l.s[1] * d2;
        f32 b3 = l.s[2] * d3;
        f32 b4 = l.s[3] * d4;

        // Close the feedback loop: y4 = A * (input - k * y4) + B.
        f32 A = a1 * a2 * a3 * a4;
        f32 B = b4 + a4 * (b3 + a3 * (b2 + a2 * b1));
        y4 = (A * input + B) / (1.0f + k * A);

        x1 = input - k * y4;
        y1 = a1 * x1 + b1;
        y2 = a2 * y1 + b2;
        y3 = a3 * y2 + b3;
        y4 = a4 * y3 + b4;
        e0 = x1;
        e1 = y1;
        e2 = y2;
        e3 = y3;
        e4 = y4;
    }

    l.s[0] = flush_denormal(2.0f * y1 - l.s[0]);
    l.s[1] = flush_denormal(2.0f * y2 - l.s[1]);
    l.s[2] = flush_denormal(2.0f * y3 - l.s[2]);
    l.s[3] = flush_denormal(2.0f * y4 - l.s[3]);
    l.x1 = x1;
    l.y[0] = y1;
    l.y[1] = y2;
    l.y[2] = y3;
    l.y[3] = y4;
    return y4;
}

// One sample with no oversampling of its own, for an engine that already
// runs at twice the audio rate or more. The same filter as
// ladder_process, without the half-band pair's 3.8-sample latency.
f32 ladder_process_direct(Ladder* l, f32 input, f32 fc, f32 k, f32 sample_rate) {
    return ladder_step(l, input, prewarp(fc, sample_rate), k);
}

// One sample at the base rate. fc in Hz; k is the feedback amount:
// 0 is none, about 4 starts self-oscillation. The passband gain is
// 1 / (1 + k), as in the analog circuit: resonance thins the bass.
f32 ladder_process(Ladder* l, f32 input, f32 fc, f32 k, f32 sample_rate) {
    f32 g = prewarp(fc, 2.0f * sample_rate);
    return ladder_process_g(l, input, g, k);
}

// ladder_process with the gain given: g = prewarp(fc, 2 * sample_rate).
f32 ladder_process_g(Ladder* l, f32 input, f32 g, f32 k) {
    f32 u0 = 0.0f;
    f32 u1 = 0.0f;
    halfband_up(&l.up, input, &u0, &u1);
    f32 v0 = ladder_step(l, u0, g, k);
    f32 v1 = ladder_step(l, u1, g, k);
    return halfband_down(&l.down, v0, v1);
}

// ---- 4-pole high-pass ----

struct HighPass4 {
    f32[4] s;
}

// One sample. g: prewarp(fc, sample_rate).
f32 highpass4_process(HighPass4* h, f32 input, f32 g) {
    f32 G = g / (1.0f + g);
    f32 x = input;
    for i32 i = 0; i < 4; i++ {
        f32 v = (x - h.s[i]) * G;
        f32 lp = v + h.s[i];
        h.s[i] = flush_denormal(lp + v);
        x = x - lp;
    }
    return x;
}

// ---- 4-pole low-pass, linear ----

// The high-pass's sibling, for the BAND pair.
struct LowPass4 {
    f32[4] s;
}

// One sample. g: prewarp(fc, sample_rate).
f32 lowpass4_process(LowPass4* h, f32 input, f32 g) {
    f32 G = g / (1.0f + g);
    f32 x = input;
    for i32 i = 0; i < 4; i++ {
        f32 v = (x - h.s[i]) * G;
        f32 lp = v + h.s[i];
        h.s[i] = flush_denormal(lp + v);
        x = lp;
    }
    return x;
}
