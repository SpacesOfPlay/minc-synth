// mod_band.mc: BAND, a coupled low-pass/high-pass pair.
//
// CENTER (1 V/oct, plus two CV inputs) and WIDTH (octaves, plus a CV
// input: 5 V adds two octaves in MODERN) place two 24 dB/oct corners
// width/2 either side of the centre. BP runs the low-pass above the
// centre into the high-pass below it, gained so the centre passes at
// unity. BR adds the low-pass below the centre to the high-pass above it,
// so the band between them cancels.

import dsp_math;
import dsp_ladder;
import profile;
import engine_core;

enum BandIn { BAND_IN_IN, BAND_IN_CV1, BAND_IN_CV2, BAND_IN_WIDTH }
enum BandOut { BAND_OUT_BP, BAND_OUT_BR }
enum BandParam { BAND_P_CENTER, BAND_P_WIDTH }

const f32 BAND_SAT = 3.0f;              // saturation scale, canonical: -1.2 dB at 10 V in MODERN
const f32 BAND_MIN_WIDTH = 0.1f;        // octaves

PortDesc[4] BAND_INPUTS = {
    PortDesc{ "in", CLS_AUDIO, 0.0f },
    PortDesc{ "cv1", CLS_PITCH, 0.0f },
    PortDesc{ "cv2", CLS_PITCH, 0.0f },
    PortDesc{ "width", CLS_CV_BI, 0.0f },
};

PortDesc[2] BAND_OUTPUTS = {
    PortDesc{ "bp", CLS_AUDIO, 0.0f },
    PortDesc{ "br", CLS_AUDIO, 0.0f },
};

ParamDesc[2] BAND_PARAMS = {
    ParamDesc{ "center", 1.0f, -4.7f, 6.3f, TAPER_LIN, 0 },       // volts from C4
    ParamDesc{ "width", 1.0f, 0.1f, 4.0f, TAPER_EXP, 0 },         // octaves
};

ModuleDesc band_desc() {
    return ModuleDesc{ "BAND", &BAND_INPUTS[0], 4, &BAND_OUTPUTS[0], 2, &BAND_PARAMS[0], 2 };
}

struct BandMod {
    ModBase base;
    LowPass4 lp_hi;             // band-pass: low-pass above the centre,
    HighPass4 hp_lo;            // then high-pass below it
    LowPass4 lp_lo;             // band-reject: low-pass below the centre,
    HighPass4 hp_hi;            // plus high-pass above it
    Cutoff cut_hi;
    Cutoff cut_lo;
}

void band_mod_init(BandMod* m, ModBase base) {
    *m = BandMod{};
    m.base = base;
}

void band_mod_reset(BandMod* m) {
    ModBase b = m.base;
    band_mod_init(m, b);
}

// Band-pass gain at the centre for corners w octaves apart, inverted:
// each 4-pole corner sits w/2 octaves from the centre.
f32 band_makeup(f32 w) {
    f32 a = 1.0f + exp2_fast(-w);
    return a * a * a * a;
}

void band_mod_tick(Core* c, BandMod* m) {
    ModBase* b = &m.base;
    f32 x = mod_in_sum(c, b, BAND_IN_IN);           // a poly cable's voices, summed
    x = BAND_SAT * tanh_fast(x / BAND_SAT);
    f32 center = mod_param(c, b, BAND_P_CENTER) + mod_in(c, b, BAND_IN_CV1) + mod_in(c, b, BAND_IN_CV2);
    f32 w = maxf(mod_param(c, b, BAND_P_WIDTH) + 2.0f * mod_in(c, b, BAND_IN_WIDTH), BAND_MIN_WIDTH);
    f32 g_hi = cutoff_g(&m.cut_hi, center + 0.5f * w, c.sample_rate);
    f32 g_lo = cutoff_g(&m.cut_lo, center - 0.5f * w, c.sample_rate);
    f32 bp = highpass4_process(&m.hp_lo, lowpass4_process(&m.lp_hi, x, g_hi), g_lo) * band_makeup(w);
    f32 br = lowpass4_process(&m.lp_lo, x, g_lo) + highpass4_process(&m.hp_hi, x, g_hi);
    mod_out(c, b, BAND_OUT_BP, bp);
    mod_out(c, b, BAND_OUT_BR, br);
}
