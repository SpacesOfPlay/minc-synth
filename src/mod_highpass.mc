// mod_highpass.mc: HIGHPASS, a 24 dB/oct high-pass without resonance.
//
// The same cutoff controls as LOWPASS: the knob plus the range switch
// plus three 1 V/oct inputs, the first with a depth knob. The input
// saturates gently from about 10 V before the four stages.

import dsp_math;
import dsp_ladder;
import dsp_age;
import profile;
import engine_core;

enum HighpassIn { HP_IN_IN1, HP_IN_IN2, HP_IN_CV1, HP_IN_CV2, HP_IN_CV3 }
enum HighpassOut { HP_OUT_OUT }
enum HighpassParam { HP_P_CUTOFF, HP_P_RANGE, HP_P_CV1_DEPTH }

const f32 HP_SAT = 3.0f;                // saturation scale, canonical: -1.2 dB at 10 V in MODERN

PortDesc[5] HP_INPUTS = {
    PortDesc{ "in1", CLS_AUDIO, 0.0f },
    PortDesc{ "in2", CLS_AUDIO, 0.0f },
    PortDesc{ "cv1", CLS_PITCH, 0.0f },
    PortDesc{ "cv2", CLS_PITCH, 0.0f },
    PortDesc{ "cv3", CLS_PITCH, 0.0f },
};

PortDesc[1] HP_OUTPUTS = {
    PortDesc{ "out", CLS_AUDIO, 0.0f },
};

ParamDesc[3] HP_PARAMS = {
    ParamDesc{ "cutoff", -2.0f, -4.7f, 6.3f, TAPER_LIN, 0 },      // volts from C4: 10 Hz .. 20 kHz
    ParamDesc{ "range", 0.0f, -2.0f, 2.0f, TAPER_LIN, 3 },        // octaves
    ParamDesc{ "cv1_depth", 1.0f, -1.0f, 1.0f, TAPER_LIN, 0 },
};

ModuleDesc highpass_desc() {
    return ModuleDesc{ "HIGHPASS", &HP_INPUTS[0], 5, &HP_OUTPUTS[0], 1, &HP_PARAMS[0], 3 };
}

struct HighpassMod {
    ModBase base;
    HighPass4 v;                // voice 0
    Cutoff cut;
    HighPass4[7] vp;            // voices 1 .. MAX_VOICES - 1
    Cutoff[7] cutp;
    f32 age_offset;             // cutoff tolerance in volts at AGE 1 (dsp_age)
}

void highpass_mod_init(HighpassMod* m, ModBase base, u64 seed) {
    *m = HighpassMod{};
    m.base = base;
    m.age_offset = age_filter_offset(seed);
}

void highpass_mod_reset(HighpassMod* m) {
    m.v = HighPass4{};
    for i32 v = 0; v < MAX_VOICES - 1; v++ { m.vp[v] = HighPass4{}; }
}

private void highpass_voice(Core* c, HighpassMod* m, HighPass4* hp, Cutoff* cut, i32 v) {
    ModBase* b = &m.base;
    f32 x = mod_in_ch(c, b, HP_IN_IN1, v) + mod_in_ch(c, b, HP_IN_IN2, v);
    x = HP_SAT * tanh_fast(x / HP_SAT);
    f32 volts = c.age * m.age_offset + mod_param(c, b, HP_P_CUTOFF) + mod_param(c, b, HP_P_RANGE)
              + mod_in_ch(c, b, HP_IN_CV1, v) * mod_param(c, b, HP_P_CV1_DEPTH)
              + mod_in_ch(c, b, HP_IN_CV2, v) + mod_in_ch(c, b, HP_IN_CV3, v);
    mod_out_ch(c, b, HP_OUT_OUT, v, highpass4_process(hp, x, cutoff_g(cut, volts, c.sample_rate)));
}

// One voice: the direct path, as fast as before voices existed.
private void highpass_mono(Core* c, HighpassMod* m) {
    ModBase* b = &m.base;
    f32 x = mod_in(c, b, HP_IN_IN1) + mod_in(c, b, HP_IN_IN2);
    x = HP_SAT * tanh_fast(x / HP_SAT);
    f32 volts = c.age * m.age_offset + mod_param(c, b, HP_P_CUTOFF) + mod_param(c, b, HP_P_RANGE)
              + mod_in(c, b, HP_IN_CV1) * mod_param(c, b, HP_P_CV1_DEPTH)
              + mod_in(c, b, HP_IN_CV2) + mod_in(c, b, HP_IN_CV3);
    mod_out(c, b, HP_OUT_OUT, highpass4_process(&m.v, x, cutoff_g(&m.cut, volts, c.sample_rate)));
}

void highpass_mod_tick(Core* c, HighpassMod* m) {
    i32 n = 1;
    if mod_poly(c, &m.base) { n = mod_begin_voices(c, &m.base, 0, 5); }
    if n == 1 {
        highpass_mono(c, m);
        return;
    }
    highpass_voice(c, m, &m.v, &m.cut, 0);
    for i32 v = 1; v < n; v++ { highpass_voice(c, m, &m.vp[v - 1], &m.cutp[v - 1], v); }
}
