// mod_offsets.mc: OFFSETS, four manual voltages.
//
// Each channel is a coarse (-10..+10 V) and a fine (-0.5..+0.5 V) knob
// added to whatever comes into its input, out as is and inverted. The
// voltages are the same in either profile.

import dsp_math;
import profile;
import engine_core;

const i32 OFFSETS_CH = 4;

// Params: coarse 1..4, then fine 1..4. Outputs: out 1..4, then inv 1..4.
const i32 OFFSETS_P_COARSE1 = 0;
const i32 OFFSETS_P_FINE1 = 4;
const i32 OFFSETS_OUT_OUT1 = 0;
const i32 OFFSETS_OUT_INV1 = 4;

PortDesc[4] OFFSETS_INPUTS = {
    PortDesc{ "in1", CLS_PITCH, 0.0f },
    PortDesc{ "in2", CLS_PITCH, 0.0f },
    PortDesc{ "in3", CLS_PITCH, 0.0f },
    PortDesc{ "in4", CLS_PITCH, 0.0f },
};

PortDesc[8] OFFSETS_OUTPUTS = {
    PortDesc{ "out1", CLS_PITCH, 0.0f },
    PortDesc{ "out2", CLS_PITCH, 0.0f },
    PortDesc{ "out3", CLS_PITCH, 0.0f },
    PortDesc{ "out4", CLS_PITCH, 0.0f },
    PortDesc{ "inv1", CLS_PITCH, 0.0f },
    PortDesc{ "inv2", CLS_PITCH, 0.0f },
    PortDesc{ "inv3", CLS_PITCH, 0.0f },
    PortDesc{ "inv4", CLS_PITCH, 0.0f },
};

ParamDesc[8] OFFSETS_PARAMS = {
    ParamDesc{ "coarse1", 0.0f, -10.0f, 10.0f, TAPER_LIN, 0 },    // volts
    ParamDesc{ "coarse2", 0.0f, -10.0f, 10.0f, TAPER_LIN, 0 },
    ParamDesc{ "coarse3", 0.0f, -10.0f, 10.0f, TAPER_LIN, 0 },
    ParamDesc{ "coarse4", 0.0f, -10.0f, 10.0f, TAPER_LIN, 0 },
    ParamDesc{ "fine1", 0.0f, -0.5f, 0.5f, TAPER_LIN, 0 },
    ParamDesc{ "fine2", 0.0f, -0.5f, 0.5f, TAPER_LIN, 0 },
    ParamDesc{ "fine3", 0.0f, -0.5f, 0.5f, TAPER_LIN, 0 },
    ParamDesc{ "fine4", 0.0f, -0.5f, 0.5f, TAPER_LIN, 0 },
};

ModuleDesc offsets_desc() {
    return ModuleDesc{ "OFFSETS", &OFFSETS_INPUTS[0], 4, &OFFSETS_OUTPUTS[0], 8, &OFFSETS_PARAMS[0], 8 };
}

struct OffsetsMod {
    ModBase base;
}

void offsets_mod_init(OffsetsMod* m, ModBase base) { m.base = base; }

void offsets_mod_tick(Core* c, OffsetsMod* m) {
    ModBase* b = &m.base;
    if !mod_poly(c, b) || mod_begin_voices(c, b, 0, OFFSETS_CH) == 1 {
        for i32 ch = 0; ch < OFFSETS_CH; ch++ {
            f32 v = mod_in(c, b, ch) + mod_param(c, b, OFFSETS_P_COARSE1 + ch) + mod_param(c, b, OFFSETS_P_FINE1 + ch);
            mod_out(c, b, OFFSETS_OUT_OUT1 + ch, v);
            mod_out(c, b, OFFSETS_OUT_INV1 + ch, -v);
        }
        return;
    }
    for i32 ch = 0; ch < OFFSETS_CH; ch++ {
        i32 n = mod_channels(c, b, ch);
        for i32 k = 0; k < n; k++ {
            f32 v = mod_in_ch(c, b, ch, k) + mod_param(c, b, OFFSETS_P_COARSE1 + ch) + mod_param(c, b, OFFSETS_P_FINE1 + ch);
            mod_out_ch(c, b, OFFSETS_OUT_OUT1 + ch, k, v);
            mod_out_ch(c, b, OFFSETS_OUT_INV1 + ch, k, -v);
        }
        mod_set_channels(c, b, OFFSETS_OUT_OUT1 + ch, n);
        mod_set_channels(c, b, OFFSETS_OUT_INV1 + ch, n);
    }
}
