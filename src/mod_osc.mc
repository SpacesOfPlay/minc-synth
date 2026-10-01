// mod_osc.mc: OSC, the standalone oscillator.
//
// Pitch is the sum of three 1 V/oct inputs, the octave switch and the
// fine knob. Width sets the pulse, and PWM adds to it. Linear FM scales
// the frequency by (1 + depth * fm); past 0 Hz the phase runs backwards
// (through-zero FM), so deep FM keeps its pitch centre.
//
// Polyphonic: one oscillator per channel of its inputs, each with its own
// phase and its own aging (dsp_age), as separate circuits would have.

import dsp_math;
import dsp_osc;
import dsp_age;
import profile;
import engine_core;

enum OscIn { OSC_IN_PITCH1, OSC_IN_PITCH2, OSC_IN_PITCH3, OSC_IN_PWM, OSC_IN_SYNC, OSC_IN_FM }
enum OscOut { OSC_OUT_SINE, OSC_OUT_TRI, OSC_OUT_SAW, OSC_OUT_PULSE }
enum OscParam { OSC_P_OCTAVE, OSC_P_FINE, OSC_P_WIDTH, OSC_P_FM }

PortDesc[6] OSC_INPUTS = {
    PortDesc{ "pitch1", CLS_PITCH, 0.0f },
    PortDesc{ "pitch2", CLS_PITCH, 0.0f },
    PortDesc{ "pitch3", CLS_PITCH, 0.0f },
    PortDesc{ "pwm", CLS_CV_BI, 0.0f },
    PortDesc{ "sync", CLS_AUDIO, 0.0f },
    PortDesc{ "fm", CLS_AUDIO, 0.0f },
};

PortDesc[4] OSC_OUTPUTS = {
    PortDesc{ "sine", CLS_AUDIO, 0.0f },
    PortDesc{ "tri", CLS_AUDIO, 0.0f },
    PortDesc{ "saw", CLS_AUDIO, 0.0f },
    PortDesc{ "pulse", CLS_AUDIO, 0.0f },
};

ParamDesc[4] OSC_PARAMS = {
    ParamDesc{ "octave", 0.0f, -3.0f, 3.0f, TAPER_LIN, 7 },
    ParamDesc{ "fine", 0.0f, -0.583333f, 0.583333f, TAPER_LIN, 0 },   // +-7 semitones, in volts
    ParamDesc{ "width", 0.5f, 0.05f, 0.95f, TAPER_LIN, 0 },
    ParamDesc{ "fm", 0.0f, 0.0f, 3.0f, TAPER_LIN, 0 },           // index: 1 swings to 0 Hz
};

ModuleDesc osc_desc() {
    return ModuleDesc{ "OSC", &OSC_INPUTS[0], 6, &OSC_OUTPUTS[0], 4, &OSC_PARAMS[0], 4 };
}

struct OscMod {
    ModBase base;
    Osc v;                      // voice 0
    Drift drift;                // its tolerances and wander, scaled by AGE
    Osc[7] vp;                  // voices 1 .. MAX_VOICES - 1
    Drift[7] driftp;
}

void osc_mod_init(OscMod* o, ModBase base, f64 phase, u64 seed, f32 sample_rate) {
    o.base = base;
    osc_init(&o.v, phase);
    drift_init(&o.drift, seed, sample_rate);
    // Further voices start spread over the cycle, like free-running circuits.
    for i32 v = 0; v < MAX_VOICES - 1; v++ {
        f64 p = phase + 0.382 * cast(f64, v + 1);
        osc_init(&o.vp[v], p - floor(p));
        drift_init(&o.driftp[v], seed * 7 + cast(u64, v + 1), sample_rate);
    }
}

void osc_mod_reset(OscMod* o) {
    osc_init(&o.v, o.v.phase);
    for i32 v = 0; v < MAX_VOICES - 1; v++ { osc_init(&o.vp[v], o.vp[v].phase); }
}

private void osc_voice(Core* c, ModBase* b, Osc* osc, Drift* drift, i32 v) {
    f32 volts = mod_in_ch(c, b, OSC_IN_PITCH1, v) + mod_in_ch(c, b, OSC_IN_PITCH2, v) + mod_in_ch(c, b, OSC_IN_PITCH3, v)
              + mod_param(c, b, OSC_P_OCTAVE) + mod_param(c, b, OSC_P_FINE);
    volts = aged_volts(drift, volts, c.age);
    f32 hz = volts_to_hz(volts) * (1.0f + mod_param(c, b, OSC_P_FM) * mod_in_ch(c, b, OSC_IN_FM, v));
    f32 dt = clampf(hz / c.sample_rate, -OSC_MAX_DT, OSC_MAX_DT);
    f32 pw = clampf(mod_param(c, b, OSC_P_WIDTH) + 0.45f * mod_in_ch(c, b, OSC_IN_PWM, v), 0.05f, 0.95f);
    osc_tick(osc, dt, pw, mod_in_ch(c, b, OSC_IN_SYNC, v));
    mod_out_ch(c, b, OSC_OUT_SINE, v, osc.sine);
    mod_out_ch(c, b, OSC_OUT_TRI, v, osc.tri);
    mod_out_ch(c, b, OSC_OUT_SAW, v, osc.saw);
    mod_out_ch(c, b, OSC_OUT_PULSE, v, osc.pulse);
}

// One voice: the direct path, as fast as before voices existed.
private void osc_mono(Core* c, OscMod* o) {
    ModBase* b = &o.base;
    f32 volts = mod_in(c, b, OSC_IN_PITCH1) + mod_in(c, b, OSC_IN_PITCH2) + mod_in(c, b, OSC_IN_PITCH3)
              + mod_param(c, b, OSC_P_OCTAVE) + mod_param(c, b, OSC_P_FINE);
    volts = aged_volts(&o.drift, volts, c.age);
    f32 hz = volts_to_hz(volts) * (1.0f + mod_param(c, b, OSC_P_FM) * mod_in(c, b, OSC_IN_FM));
    f32 dt = clampf(hz / c.sample_rate, -OSC_MAX_DT, OSC_MAX_DT);
    f32 pw = clampf(mod_param(c, b, OSC_P_WIDTH) + 0.45f * mod_in(c, b, OSC_IN_PWM), 0.05f, 0.95f);
    osc_tick(&o.v, dt, pw, mod_in(c, b, OSC_IN_SYNC));
    mod_out(c, b, OSC_OUT_SINE, o.v.sine);
    mod_out(c, b, OSC_OUT_TRI, o.v.tri);
    mod_out(c, b, OSC_OUT_SAW, o.v.saw);
    mod_out(c, b, OSC_OUT_PULSE, o.v.pulse);
}

void osc_mod_tick(Core* c, OscMod* o) {
    ModBase* b = &o.base;
    i32 n = 1;
    if mod_poly(c, b) { n = mod_begin_voices(c, b, 0, 6); }
    if n == 1 {
        osc_mono(c, o);
        return;
    }
    osc_voice(c, b, &o.v, &o.drift, 0);
    for i32 v = 1; v < n; v++ { osc_voice(c, b, &o.vp[v - 1], &o.driftp[v - 1], v); }
}
