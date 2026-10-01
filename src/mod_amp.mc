// mod_amp.mc: AMP, the voltage-controlled amplifier.
//
// Gain is the knob plus two CV inputs (10 V opens it fully in MODERN).
// LIN maps that straight to gain; EXP maps it dB-linearly over 70 dB
// with a short knee into silence. CV is not smoothed, so audio-rate
// amplitude and ring modulation work. The output saturates softly past
// about 8 V.

import dsp_math;
import profile;
import engine_core;

enum AmpIn { AMP_IN_IN1, AMP_IN_IN2, AMP_IN_CV1, AMP_IN_CV2 }
enum AmpOut { AMP_OUT_OUT, AMP_OUT_INV }
enum AmpParam { AMP_P_GAIN, AMP_P_MODE }
enum AmpMode { AMP_LIN, AMP_EXP }

const f32 AMP_MAX_GAIN = 1.2f;
const f32 AMP_EXP_RANGE_DB = 70.0f;
const f32 AMP_EXP_KNEE = 0.05f;
const f32 AMP_SAT = 1.6f;               // canonical level where saturation takes over

PortDesc[4] AMP_INPUTS = {
    PortDesc{ "in1", CLS_AUDIO, 0.0f },
    PortDesc{ "in2", CLS_AUDIO, 0.0f },
    PortDesc{ "cv1", CLS_CV_UNI, 0.0f },
    PortDesc{ "cv2", CLS_CV_UNI, 0.0f },
};

PortDesc[2] AMP_OUTPUTS = {
    PortDesc{ "out", CLS_AUDIO, 0.0f },
    PortDesc{ "inv", CLS_AUDIO, 0.0f },
};

ParamDesc[2] AMP_PARAMS = {
    ParamDesc{ "gain", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "mode", 0.0f, 0.0f, 1.0f, TAPER_LIN, 2 },      // AmpMode
};

ModuleDesc amp_desc() {
    return ModuleDesc{ "AMP", &AMP_INPUTS[0], 4, &AMP_OUTPUTS[0], 2, &AMP_PARAMS[0], 2 };
}

struct AmpMod {
    ModBase base;
}

void amp_mod_init(AmpMod* m, ModBase base) { m.base = base; }

// Control value 0..AMP_MAX_GAIN to gain, per mode.
f32 amp_gain(f32 control, i32 mode) {
    f32 g = clampf(control, 0.0f, AMP_MAX_GAIN);
    if mode == AMP_LIN { return g; }
    f32 lin = exp2_fast((g - 1.0f) * AMP_EXP_RANGE_DB / 6.0206f);
    if g < AMP_EXP_KNEE { lin *= g / AMP_EXP_KNEE; }
    return lin;
}

// One gain per channel of its inputs; one voice takes the direct path.
void amp_mod_tick(Core* c, AmpMod* m) {
    ModBase* b = &m.base;
    i32 n = 1;
    if mod_poly(c, b) { n = mod_begin_voices(c, b, 0, 4); }
    if n == 1 {
        f32 control = mod_param(c, b, AMP_P_GAIN) + mod_in(c, b, AMP_IN_CV1) + mod_in(c, b, AMP_IN_CV2);
        f32 g = amp_gain(control, cast(i32, mod_param(c, b, AMP_P_MODE)));
        f32 y = (mod_in(c, b, AMP_IN_IN1) + mod_in(c, b, AMP_IN_IN2)) * g;
        y = AMP_SAT * tanh_fast(y / AMP_SAT);
        mod_out(c, b, AMP_OUT_OUT, y);
        mod_out(c, b, AMP_OUT_INV, -y);
        return;
    }
    i32 mode = cast(i32, mod_param(c, b, AMP_P_MODE));
    for i32 v = 0; v < n; v++ {
        f32 control = mod_param(c, b, AMP_P_GAIN) + mod_in_ch(c, b, AMP_IN_CV1, v) + mod_in_ch(c, b, AMP_IN_CV2, v);
        f32 g = amp_gain(control, mode);
        f32 y = (mod_in_ch(c, b, AMP_IN_IN1, v) + mod_in_ch(c, b, AMP_IN_IN2, v)) * g;
        y = AMP_SAT * tanh_fast(y / AMP_SAT);
        mod_out_ch(c, b, AMP_OUT_OUT, v, y);
        mod_out_ch(c, b, AMP_OUT_INV, v, -y);
    }
}
