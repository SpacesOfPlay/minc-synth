// mod_scope.mc: SCOPE, two channels drawn on the panel.
//
// The module itself only holds the controls. The engine records the two
// inputs into the telemetry scope ring, keeping one frame in every
// `scope_decimation` so a screen spans TIME; the UI finds a rising
// crossing of LEVEL on channel A and draws from there, or the latest
// screen when there is none; LEVEL at the bottom of its travel turns the
// trigger off. RANGE sets the volts at the display's edge. Until a cable
// goes into A, A shows the output.

import dsp_math;
import profile;
import engine_core;

enum ScopeIn { SCOPE_IN_A, SCOPE_IN_B }
enum ScopeParam { SCOPE_P_TIME, SCOPE_P_LEVEL, SCOPE_P_RANGE }

const i32 SCOPE_SCREEN = 1024;          // recorded frames across one screen

f32[3] SCOPE_RANGES = { 1.0f, 5.0f, 10.0f };   // volts, by range switch position

PortDesc[2] SCOPE_INPUTS = {
    PortDesc{ "a", CLS_AUDIO, 0.0f },
    PortDesc{ "b", CLS_AUDIO, 0.0f },
};

ParamDesc[3] SCOPE_PARAMS = {
    ParamDesc{ "time", 0.02f, 0.001f, 1.0f, TAPER_EXP, 0 },       // seconds across the screen
    ParamDesc{ "level", 0.0f, -10.0f, 10.0f, TAPER_LIN, 0 },      // trigger, volts
    ParamDesc{ "range", 1.0f, 0.0f, 2.0f, TAPER_LIN, 3 },         // SCOPE_RANGES
};

ModuleDesc scope_desc() {
    return ModuleDesc{ "SCOPE", &SCOPE_INPUTS[0], 2, null, 0, &SCOPE_PARAMS[0], 3 };
}

struct ScopeMod {
    ModBase base;
}

void scope_mod_init(ScopeMod* m, ModBase base) { m.base = base; }

// Device frames per recorded frame for a screen of `seconds`.
i32 scope_decimation(f32 seconds, f32 device_rate) {
    return clampi(cast(i32, seconds * device_rate / cast(f32, SCOPE_SCREEN) + 0.5f), 1, 4096);
}

// An input in volts, as it arrives.
f32 scope_volts(Core* c, ScopeMod* m, i32 ch) {
    i32 j = m.base.jack0 + ch;
    return jack_read(c, j) / c.jacks[j].in_scale;
}
