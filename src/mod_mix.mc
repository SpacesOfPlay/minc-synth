// mod_mix.mc: MIX, a four-channel mixer with a normal and an inverted output.

import profile;
import engine_core;

enum MixIn { MIX_IN_1, MIX_IN_2, MIX_IN_3, MIX_IN_4 }
enum MixOut { MIX_OUT_OUT, MIX_OUT_INV }
enum MixParam { MIX_P_LEVEL1, MIX_P_LEVEL2, MIX_P_LEVEL3, MIX_P_LEVEL4 }

PortDesc[4] MIX_INPUTS = {
    PortDesc{ "in1", CLS_AUDIO, 0.0f },
    PortDesc{ "in2", CLS_AUDIO, 0.0f },
    PortDesc{ "in3", CLS_AUDIO, 0.0f },
    PortDesc{ "in4", CLS_AUDIO, 0.0f },
};

PortDesc[2] MIX_OUTPUTS = {
    PortDesc{ "out", CLS_AUDIO, 0.0f },
    PortDesc{ "inv", CLS_AUDIO, 0.0f },
};

ParamDesc[4] MIX_PARAMS = {
    ParamDesc{ "level1", 0.8f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "level2", 0.8f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "level3", 0.8f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "level4", 0.8f, 0.0f, 1.0f, TAPER_LIN, 0 },
};

ModuleDesc mix_desc() {
    return ModuleDesc{ "MIX", &MIX_INPUTS[0], 4, &MIX_OUTPUTS[0], 2, &MIX_PARAMS[0], 4 };
}

struct MixMod {
    ModBase base;
}

void mix_mod_init(MixMod* m, ModBase base) { m.base = base; }

// Mixes channel by channel: four poly cables give a poly mix.
void mix_mod_tick(Core* c, MixMod* m) {
    ModBase* b = &m.base;
    i32 n = 1;
    if mod_poly(c, b) { n = mod_begin_voices(c, b, 0, 4); }
    if n == 1 {
        f32 sum = 0.0f;
        for i32 i = 0; i < 4; i++ { sum += mod_in(c, b, MIX_IN_1 + i) * mod_param(c, b, MIX_P_LEVEL1 + i); }
        mod_out(c, b, MIX_OUT_OUT, sum);
        mod_out(c, b, MIX_OUT_INV, -sum);
        return;
    }
    for i32 v = 0; v < n; v++ {
        f32 sum = 0.0f;
        for i32 i = 0; i < 4; i++ { sum += mod_in_ch(c, b, MIX_IN_1 + i, v) * mod_param(c, b, MIX_P_LEVEL1 + i); }
        mod_out_ch(c, b, MIX_OUT_OUT, v, sum);
        mod_out_ch(c, b, MIX_OUT_INV, v, -sum);
    }
}
