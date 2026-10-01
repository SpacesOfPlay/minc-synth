// mod_spectrum.mc: SPECTRUM, a fixed filter bank of 14 bands.
//
// A low band (2-pole low-pass near 93 Hz), twelve band-passes at
// half-octave spacing from 125 Hz to 5.6 kHz, and a high band (2-pole
// high-pass near 7.6 kHz), each with a level knob. Each band-pass is two
// identical state-variable band-passes in series, and neighbouring bands
// have opposite polarity, so with every level up the sum stays within
// about +-1.3 dB from 30 Hz to 16 kHz while one band turned down still
// cuts about 18 dB. (Single 2-pole band-passes at this spacing can't sum
// flatter than about 4.4 dB.)

import dsp_math;
import dsp_svf;
import profile;
import engine_core;

const i32 SPECTRUM_BANDS = 14;
const f32 SPECTRUM_Q = 1.4829f;
const f32 SPECTRUM_LOW_HZ = 92.73f;
const f32 SPECTRUM_HIGH_HZ = 7625.0f;
const f32 SPECTRUM_EDGE_Q = 0.5f;
const f32 SPECTRUM_MAKEUP = 1.065f;     // centres the ripple on 0 dB

PortDesc[1] SPECTRUM_INPUTS = {
    PortDesc{ "in", CLS_AUDIO, 0.0f },
};

PortDesc[1] SPECTRUM_OUTPUTS = {
    PortDesc{ "out", CLS_AUDIO, 0.0f },
};

ParamDesc[14] SPECTRUM_PARAMS = {
    ParamDesc{ "low", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "125", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "177", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "250", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "354", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "500", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "707", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "1k", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "1.4k", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "2k", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "2.8k", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "4k", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "5.6k", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "high", 1.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
};

ModuleDesc spectrum_desc() {
    return ModuleDesc{ "SPECTRUM", &SPECTRUM_INPUTS[0], 1, &SPECTRUM_OUTPUTS[0], 1, &SPECTRUM_PARAMS[0], 14 };
}

// Centre of band-pass k (0..11).
f32 spectrum_centre(i32 k) { return 125.0f * exp2_fast(0.5f * cast(f32, k)); }

struct SpectrumMod {
    ModBase base;
    Svf low;
    Svf high;
    Svf[12] bp1;                // the two halves of each band-pass
    Svf[12] bp2;
    f32 rate;                   // sample rate the filters were set for
}

private void spectrum_set(SpectrumMod* m, f32 sample_rate) {
    m.rate = sample_rate;
    svf_set(&m.low, SPECTRUM_LOW_HZ, SPECTRUM_EDGE_Q, sample_rate);
    svf_set(&m.high, SPECTRUM_HIGH_HZ, SPECTRUM_EDGE_Q, sample_rate);
    for i32 k = 0; k < 12; k++ {
        svf_set(&m.bp1[k], spectrum_centre(k), SPECTRUM_Q, sample_rate);
        svf_set(&m.bp2[k], spectrum_centre(k), SPECTRUM_Q, sample_rate);
    }
}

void spectrum_mod_init(SpectrumMod* m, ModBase base, f32 sample_rate) {
    *m = SpectrumMod{};
    m.base = base;
    spectrum_set(m, sample_rate);
}

void spectrum_mod_reset(SpectrumMod* m) {
    ModBase b = m.base;
    spectrum_mod_init(m, b, m.rate);
}

void spectrum_mod_tick(Core* c, SpectrumMod* m) {
    ModBase* b = &m.base;
    f32 x = mod_in_sum(c, b, 0);                    // a poly cable's voices, summed
    f32 y = -mod_param(c, b, 0) * svf_process(&m.low, x).low
          + mod_param(c, b, 13) * svf_process(&m.high, x).high;
    f32 sign = 1.0f;
    for i32 k = 0; k < 12; k++ {
        // The unity-peak band output: band * k.
        f32 v = svf_process(&m.bp1[k], x).band * m.bp1[k].k;
        v = svf_process(&m.bp2[k], v).band * m.bp2[k].k;
        y += sign * mod_param(c, b, 1 + k) * v;
        sign = -sign;
    }
    mod_out(c, b, 0, y * SPECTRUM_MAKEUP);
}
