// mod_stepsw.mc: STEP SWITCH, a sequential switch of two or three stages.
//
// A rising edge on SHIFT moves to the next stage (after the last, back to
// the first); RESET returns to the first. The switch works both ways at
// once: OUT carries the input of the current stage (A, B or C), and IN
// goes to the current stage's output while the others hold 0 V.

import dsp_math;
import profile;
import engine_core;

enum StepswIn { STEPSW_IN_A, STEPSW_IN_B, STEPSW_IN_C, STEPSW_IN_SHIFT, STEPSW_IN_RESET, STEPSW_IN_IN }
enum StepswOut { STEPSW_OUT_A, STEPSW_OUT_B, STEPSW_OUT_C, STEPSW_OUT_OUT }
enum StepswParam { STEPSW_P_STAGES }

PortDesc[6] STEPSW_INPUTS = {
    PortDesc{ "a", CLS_AUDIO, 0.0f },
    PortDesc{ "b", CLS_AUDIO, 0.0f },
    PortDesc{ "c", CLS_AUDIO, 0.0f },
    PortDesc{ "shift", CLS_TRIG, 0.0f },
    PortDesc{ "reset", CLS_TRIG, 0.0f },
    PortDesc{ "in", CLS_AUDIO, 0.0f },
};

PortDesc[4] STEPSW_OUTPUTS = {
    PortDesc{ "a", CLS_AUDIO, 0.0f },
    PortDesc{ "b", CLS_AUDIO, 0.0f },
    PortDesc{ "c", CLS_AUDIO, 0.0f },
    PortDesc{ "out", CLS_AUDIO, 0.0f },
};

ParamDesc[1] STEPSW_PARAMS = {
    ParamDesc{ "stages", 3.0f, 2.0f, 3.0f, TAPER_LIN, 2 },
};

ModuleDesc stepsw_desc() {
    return ModuleDesc{ "STEP SWITCH", &STEPSW_INPUTS[0], 6, &STEPSW_OUTPUTS[0], 4, &STEPSW_PARAMS[0], 1 };
}

struct StepswMod {
    ModBase base;
    i32 stage;                  // 0..2
    Schmitt shift;
    Schmitt reset;
}

void stepsw_mod_init(StepswMod* m, ModBase base) {
    *m = StepswMod{};
    m.base = base;
}

void stepsw_mod_reset(StepswMod* m) {
    ModBase b = m.base;
    stepsw_mod_init(m, b);
}

void stepsw_mod_tick(Core* c, StepswMod* m) {
    ModBase* b = &m.base;
    i32 stages = cast(i32, mod_param(c, b, STEPSW_P_STAGES) + 0.5f);
    bool was_shift = m.shift.high;
    if schmitt(&m.shift, mod_in(c, b, STEPSW_IN_SHIFT)) && !was_shift { m.stage++; }
    bool was_reset = m.reset.high;
    if schmitt(&m.reset, mod_in(c, b, STEPSW_IN_RESET)) && !was_reset { m.stage = 0; }
    if m.stage >= stages { m.stage = 0; }
    mod_out(c, b, STEPSW_OUT_OUT, mod_in(c, b, STEPSW_IN_A + m.stage));
    f32 in = mod_in(c, b, STEPSW_IN_IN);
    for i32 s = 0; s < 3; s++ {
        f32 v = 0.0f;
        if s == m.stage { v = in; }
        mod_out(c, b, STEPSW_OUT_A + s, v);
    }
}
