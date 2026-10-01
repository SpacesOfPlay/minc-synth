// mod_mult.mc: MULT, two groups of four jacks: one input copied to three
// outputs. Outputs already take any number of cables; MULT is for the
// classic way of patching, and costs the one tick every cable does.

import profile;
import engine_core;

PortDesc[2] MULT_INPUTS = {
    PortDesc{ "in1", CLS_AUDIO, 0.0f },
    PortDesc{ "in2", CLS_AUDIO, 0.0f },
};

PortDesc[6] MULT_OUTPUTS = {
    PortDesc{ "a1", CLS_AUDIO, 0.0f },
    PortDesc{ "a2", CLS_AUDIO, 0.0f },
    PortDesc{ "a3", CLS_AUDIO, 0.0f },
    PortDesc{ "b1", CLS_AUDIO, 0.0f },
    PortDesc{ "b2", CLS_AUDIO, 0.0f },
    PortDesc{ "b3", CLS_AUDIO, 0.0f },
};

ModuleDesc mult_desc() {
    return ModuleDesc{ "MULT", &MULT_INPUTS[0], 2, &MULT_OUTPUTS[0], 6, null, 0 };
}

struct MultMod {
    ModBase base;
}

void mult_mod_init(MultMod* m, ModBase base) { m.base = base; }

void mult_mod_tick(Core* c, MultMod* m) {
    ModBase* b = &m.base;
    if !mod_poly(c, b) || mod_begin_voices(c, b, 0, 2) == 1 {
        for i32 g = 0; g < 2; g++ {
            f32 v = mod_in(c, b, g);
            for i32 k = 0; k < 3; k++ { mod_out(c, b, 3 * g + k, v); }
        }
        return;
    }
    for i32 g = 0; g < 2; g++ {
        i32 n = mod_channels(c, b, g);
        for i32 v = 0; v < n; v++ {
            f32 x = mod_in_ch(c, b, g, v);
            for i32 k = 0; k < 3; k++ { mod_out_ch(c, b, 3 * g + k, v, x); }
        }
        for i32 k = 0; k < 3; k++ { mod_set_channels(c, b, 3 * g + k, n); }
    }
}
