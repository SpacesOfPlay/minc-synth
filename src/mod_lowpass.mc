// mod_lowpass.mc: LOWPASS, the 24 dB/oct ladder filter.
//
// Cutoff is the knob plus the range switch plus three 1 V/oct inputs;
// the first has a depth knob so an envelope can go straight in. Drive
// sets how hard the ladder's tanh stages are pushed; the output is
// divided by it again, so drive changes the character, not the level.
// Comp restores some of the bass that resonance takes away.

import dsp_math;
import dsp_ladder;
import dsp_age;
import profile;
import engine_core;

enum LowpassIn { LP_IN_IN1, LP_IN_IN2, LP_IN_CV1, LP_IN_CV2, LP_IN_CV3 }
enum LowpassOut { LP_OUT_OUT }
enum LowpassParam { LP_P_CUTOFF, LP_P_RANGE, LP_P_RES, LP_P_DRIVE, LP_P_CV1_DEPTH, LP_P_COMP }

const f32 LP_MAX_K = 4.2f;              // resonance 1: self-oscillation

// From this engine rate up the ladder runs directly: the engine's rate
// already gives it the headroom its own 2x oversampler would.
const f32 LP_DIRECT_RATE = 88000.0f;

PortDesc[5] LP_INPUTS = {
    PortDesc{ "in1", CLS_AUDIO, 0.0f },
    PortDesc{ "in2", CLS_AUDIO, 0.0f },
    PortDesc{ "cv1", CLS_PITCH, 0.0f },
    PortDesc{ "cv2", CLS_PITCH, 0.0f },
    PortDesc{ "cv3", CLS_PITCH, 0.0f },
};

PortDesc[1] LP_OUTPUTS = {
    PortDesc{ "out", CLS_AUDIO, 0.0f },
};

ParamDesc[6] LP_PARAMS = {
    ParamDesc{ "cutoff", 2.0f, -4.7f, 6.3f, TAPER_LIN, 0 },       // volts from C4: 10 Hz .. 20 kHz
    ParamDesc{ "range", 0.0f, -2.0f, 2.0f, TAPER_LIN, 3 },        // octaves
    ParamDesc{ "res", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "drive", 1.0f, 0.25f, 4.0f, TAPER_EXP, 0 },
    ParamDesc{ "cv1_depth", 1.0f, -1.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "comp", 0.5f, 0.0f, 1.0f, TAPER_LIN, 0 },
};

ModuleDesc lowpass_desc() {
    return ModuleDesc{ "LOWPASS", &LP_INPUTS[0], 5, &LP_OUTPUTS[0], 1, &LP_PARAMS[0], 6 };
}

struct LowpassMod {
    ModBase base;
    Ladder v;                   // voice 0
    Cutoff cut;
    f32 age_offset;             // cutoff tolerance in volts at AGE 1 (dsp_age)
    Ladder[7] vp;               // voices 1 .. MAX_VOICES - 1
    Cutoff[7] cutp;
}

void lowpass_mod_init(LowpassMod* m, ModBase base, u64 seed) {
    m.base = base;
    ladder_init(&m.v);
    m.age_offset = age_filter_offset(seed);
    for i32 v = 0; v < MAX_VOICES - 1; v++ { ladder_init(&m.vp[v]); }
}

void lowpass_mod_reset(LowpassMod* m) {
    ladder_init(&m.v);
    for i32 v = 0; v < MAX_VOICES - 1; v++ { ladder_init(&m.vp[v]); }
}

private void lowpass_voice(Core* c, LowpassMod* m, Ladder* lad, Cutoff* cut, i32 v) {
    ModBase* b = &m.base;
    f32 drive = mod_param(c, b, LP_P_DRIVE);
    f32 x = (mod_in_ch(c, b, LP_IN_IN1, v) + mod_in_ch(c, b, LP_IN_IN2, v)) * drive;
    f32 volts = c.age * m.age_offset + mod_param(c, b, LP_P_CUTOFF) + mod_param(c, b, LP_P_RANGE)
              + mod_in_ch(c, b, LP_IN_CV1, v) * mod_param(c, b, LP_P_CV1_DEPTH)
              + mod_in_ch(c, b, LP_IN_CV2, v) + mod_in_ch(c, b, LP_IN_CV3, v);
    f32 k = mod_param(c, b, LP_P_RES) * LP_MAX_K;
    f32 y = 0.0f;
    if c.sample_rate >= LP_DIRECT_RATE {
        y = ladder_step(lad, x, cutoff_g(cut, volts, c.sample_rate), k);
    } else {
        y = ladder_process_g(lad, x, cutoff_g(cut, volts, 2.0f * c.sample_rate), k);
    }
    mod_out_ch(c, b, LP_OUT_OUT, v, y / drive * (1.0f + mod_param(c, b, LP_P_COMP) * k));
}

// One ladder per channel of its inputs.
// One voice: the direct path, as fast as before voices existed.
private void lowpass_mono(Core* c, LowpassMod* m) {
    ModBase* b = &m.base;
    f32 drive = mod_param(c, b, LP_P_DRIVE);
    f32 x = (mod_in(c, b, LP_IN_IN1) + mod_in(c, b, LP_IN_IN2)) * drive;
    f32 volts = c.age * m.age_offset + mod_param(c, b, LP_P_CUTOFF) + mod_param(c, b, LP_P_RANGE)
              + mod_in(c, b, LP_IN_CV1) * mod_param(c, b, LP_P_CV1_DEPTH)
              + mod_in(c, b, LP_IN_CV2) + mod_in(c, b, LP_IN_CV3);
    f32 k = mod_param(c, b, LP_P_RES) * LP_MAX_K;
    f32 y = 0.0f;
    if c.sample_rate >= LP_DIRECT_RATE {
        y = ladder_step(&m.v, x, cutoff_g(&m.cut, volts, c.sample_rate), k);
    } else {
        y = ladder_process_g(&m.v, x, cutoff_g(&m.cut, volts, 2.0f * c.sample_rate), k);
    }
    mod_out(c, b, LP_OUT_OUT, y / drive * (1.0f + mod_param(c, b, LP_P_COMP) * k));
}

void lowpass_mod_tick(Core* c, LowpassMod* m) {
    i32 n = 1;
    if mod_poly(c, &m.base) { n = mod_begin_voices(c, &m.base, 0, 5); }
    if n == 1 {
        lowpass_mono(c, m);
        return;
    }
    lowpass_voice(c, m, &m.v, &m.cut, 0);
    for i32 v = 1; v < n; v++ { lowpass_voice(c, m, &m.vp[v - 1], &m.cutp[v - 1], v); }
}
