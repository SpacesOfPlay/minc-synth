// mod_atten.mc: ATTEN, three attenuverters.
//
// Each channel scales its input by -2..+2: turned down, off at the
// centre, inverted, or with up to twice the gain, which deep feedback
// patches need. An unpatched input reads a steady full-scale level, so a
// channel doubles as a manual voltage.

import dsp_math;
import profile;
import engine_core;

const i32 ATTEN_CH = 3;

PortDesc[3] ATTEN_INPUTS = {
    PortDesc{ "in1", CLS_AUDIO, 1.0f },
    PortDesc{ "in2", CLS_AUDIO, 1.0f },
    PortDesc{ "in3", CLS_AUDIO, 1.0f },
};

PortDesc[3] ATTEN_OUTPUTS = {
    PortDesc{ "out1", CLS_AUDIO, 0.0f },
    PortDesc{ "out2", CLS_AUDIO, 0.0f },
    PortDesc{ "out3", CLS_AUDIO, 0.0f },
};

ParamDesc[3] ATTEN_PARAMS = {
    ParamDesc{ "gain1", 0.0f, -2.0f, 2.0f, TAPER_LIN, 0 },
    ParamDesc{ "gain2", 0.0f, -2.0f, 2.0f, TAPER_LIN, 0 },
    ParamDesc{ "gain3", 0.0f, -2.0f, 2.0f, TAPER_LIN, 0 },
};

ModuleDesc atten_desc() {
    return ModuleDesc{ "ATTEN", &ATTEN_INPUTS[0], 3, &ATTEN_OUTPUTS[0], 3, &ATTEN_PARAMS[0], 3 };
}

struct AttenMod {
    ModBase base;
}

void atten_mod_init(AttenMod* m, ModBase base) { m.base = base; }

void atten_mod_tick(Core* c, AttenMod* m) {
    ModBase* b = &m.base;
    if !mod_poly(c, b) || mod_begin_voices(c, b, 0, ATTEN_CH) == 1 {
        for i32 ch = 0; ch < ATTEN_CH; ch++ { mod_out(c, b, ch, mod_in(c, b, ch) * mod_param(c, b, ch)); }
        return;
    }
    for i32 ch = 0; ch < ATTEN_CH; ch++ {
        i32 n = mod_channels(c, b, ch);                // each strip passes its cable's voices
        for i32 v = 0; v < n; v++ { mod_out_ch(c, b, ch, v, mod_in_ch(c, b, ch, v) * mod_param(c, b, ch)); }
        mod_set_channels(c, b, ch, n);
    }
}
