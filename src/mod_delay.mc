// mod_delay.mc: TRIG DELAY, two trigger delays.
//
// A rising edge on a channel's input, or its FIRE button, starts that
// channel's timer; when the time is up the output fires a trigger. A new
// edge while waiting starts the wait again.

import dsp_math;
import profile;
import engine_core;

enum DelayIn { DELAY_IN_IN1, DELAY_IN_IN2 }
enum DelayOut { DELAY_OUT_OUT1, DELAY_OUT_OUT2 }
enum DelayParam { DELAY_P_TIME1, DELAY_P_TIME2, DELAY_P_FIRE1, DELAY_P_FIRE2 }

PortDesc[2] DELAY_INPUTS = {
    PortDesc{ "in1", CLS_TRIG, 0.0f },
    PortDesc{ "in2", CLS_TRIG, 0.0f },
};

PortDesc[2] DELAY_OUTPUTS = {
    PortDesc{ "out1", CLS_TRIG, 0.0f },
    PortDesc{ "out2", CLS_TRIG, 0.0f },
};

ParamDesc[4] DELAY_PARAMS = {
    ParamDesc{ "time1", 0.1f, 0.001f, 10.0f, TAPER_EXP, 0 },      // seconds
    ParamDesc{ "time2", 0.1f, 0.001f, 10.0f, TAPER_EXP, 0 },
    ParamDesc{ "fire1", 0.0f, 0.0f, 1.0f, TAPER_LIN, 1 },         // buttons
    ParamDesc{ "fire2", 0.0f, 0.0f, 1.0f, TAPER_LIN, 1 },
};

ModuleDesc delay_desc() {
    return ModuleDesc{ "TRIG DELAY", &DELAY_INPUTS[0], 2, &DELAY_OUTPUTS[0], 2, &DELAY_PARAMS[0], 4 };
}

struct DelayMod {
    ModBase base;
    Schmitt[2] edge;
    i32[2] left;                // samples until the output fires; 0 while idle
    TrigOut[2] out;
}

void delay_mod_init(DelayMod* m, ModBase base) {
    *m = DelayMod{};
    m.base = base;
}

void delay_mod_reset(DelayMod* m) {
    ModBase b = m.base;
    delay_mod_init(m, b);
}

void delay_mod_tick(Core* c, DelayMod* m) {
    ModBase* b = &m.base;
    for i32 ch = 0; ch < 2; ch++ {
        bool was = m.edge[ch].high;
        f32 in = maxf(mod_in(c, b, DELAY_IN_IN1 + ch), mod_param(c, b, DELAY_P_FIRE1 + ch));
        if schmitt(&m.edge[ch], in) && !was {
            m.left[ch] = cast(i32, mod_param(c, b, DELAY_P_TIME1 + ch) * c.sample_rate) + 1;
        }
        if m.left[ch] > 0 {
            m.left[ch]--;
            if m.left[ch] == 0 { trig_fire(c, &m.out[ch]); }
        }
        mod_out(c, b, DELAY_OUT_OUT1 + ch, trig_tick(&m.out[ch]));
    }
}
