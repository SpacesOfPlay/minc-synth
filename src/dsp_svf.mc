// dsp_svf.mc: trapezoidal (TPT) state-variable filter.
//
// One structure gives low-pass, band-pass and high-pass together
// (Zavalishin; Simper's formulation). The SPECTRUM bank and BAND module
// build on it.

import dsp_math;

struct Svf {
    f32 ic1;            // integrator states
    f32 ic2;
    f32 a1;
    f32 a2;
    f32 a3;
    f32 k;              // 1 / Q
}

// `band` peaks at Q at the cutoff; band * k is the unity-peak band-pass.
struct SvfOut {
    f32 low;
    f32 band;
    f32 high;
}

void svf_set(Svf* s, f32 fc, f32 q, f32 sample_rate) {
    f32 g = prewarp(fc, sample_rate);
    s.k = 1.0f / q;
    s.a1 = 1.0f / (1.0f + g * (g + s.k));
    s.a2 = g * s.a1;
    s.a3 = g * s.a2;
}

SvfOut svf_process(Svf* s, f32 v0) {
    f32 v3 = v0 - s.ic2;
    f32 v1 = s.a1 * s.ic1 + s.a2 * v3;
    f32 v2 = s.ic2 + s.a2 * s.ic1 + s.a3 * v3;
    s.ic1 = flush_denormal(2.0f * v1 - s.ic1);
    s.ic2 = flush_denormal(2.0f * v2 - s.ic2);
    return SvfOut{ v2, v1, v0 - s.k * v1 - v2 };
}
