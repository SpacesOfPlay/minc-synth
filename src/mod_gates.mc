// mod_gates.mc: GATES, the bridge between signals and triggers.
//
// Two channels, each with three stages:
// - SIG through a comparator with a threshold knob gives GATE, high
//   while the signal is above the threshold. Audio, an LFO or any CV
//   becomes a gate.
// - TRIG (following GATE until a cable goes in) gives PULSE, high for
//   LENGTH from each rising edge: an edge becomes a trigger, or a short
//   trigger a longer gate.
// - TRIG also gives V, +3 V on the signal side while TRIG is high.
// OR is high while either OR input is; B1 and B2 are high while their
// buttons are held.
//
// In MODERN these are gate utilities. In VINTAGE, where a signal can't be
// patched into a trigger input or the reverse, they are the only way
// between the two networks: SIG to GATE, and TRIG to V.

import dsp_math;
import profile;
import engine_core;

enum GatesIn { GATES_IN_SIG1, GATES_IN_TRIG1, GATES_IN_OR1, GATES_IN_SIG2, GATES_IN_TRIG2, GATES_IN_OR2 }
enum GatesOut {
    GATES_OUT_GATE1, GATES_OUT_PULSE1, GATES_OUT_V1,
    GATES_OUT_GATE2, GATES_OUT_PULSE2, GATES_OUT_V2,
    GATES_OUT_OR, GATES_OUT_B1, GATES_OUT_B2
}
enum GatesParam { GATES_P_THRESH1, GATES_P_LENGTH1, GATES_P_BUTTON1, GATES_P_THRESH2, GATES_P_LENGTH2, GATES_P_BUTTON2 }

const f32 GATES_HYST = 0.02f;           // comparator hysteresis, canonical
const f32 GATES_VTRIG_V = 3.0f;         // V output level, volts in either profile

PortDesc[6] GATES_INPUTS = {
    PortDesc{ "sig1", CLS_CV_BI, 0.0f },
    PortDesc{ "trig1", CLS_TRIG, 0.0f },
    PortDesc{ "or1", CLS_TRIG, 0.0f },
    PortDesc{ "sig2", CLS_CV_BI, 0.0f },
    PortDesc{ "trig2", CLS_TRIG, 0.0f },
    PortDesc{ "or2", CLS_TRIG, 0.0f },
};

PortDesc[9] GATES_OUTPUTS = {
    PortDesc{ "gate1", CLS_TRIG, 0.0f },
    PortDesc{ "pulse1", CLS_TRIG, 0.0f },
    PortDesc{ "v1", CLS_CV_UNI, 0.0f },
    PortDesc{ "gate2", CLS_TRIG, 0.0f },
    PortDesc{ "pulse2", CLS_TRIG, 0.0f },
    PortDesc{ "v2", CLS_CV_UNI, 0.0f },
    PortDesc{ "or", CLS_TRIG, 0.0f },
    PortDesc{ "b1", CLS_TRIG, 0.0f },
    PortDesc{ "b2", CLS_TRIG, 0.0f },
};

ParamDesc[6] GATES_PARAMS = {
    ParamDesc{ "thresh1", 0.2f, -1.0f, 1.0f, TAPER_LIN, 0 },      // canonical: 1 V in MODERN
    ParamDesc{ "length1", 0.002f, 0.001f, 2.0f, TAPER_EXP, 0 },   // seconds
    ParamDesc{ "button1", 0.0f, 0.0f, 1.0f, TAPER_LIN, 1 },
    ParamDesc{ "thresh2", 0.2f, -1.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "length2", 0.002f, 0.001f, 2.0f, TAPER_EXP, 0 },
    ParamDesc{ "button2", 0.0f, 0.0f, 1.0f, TAPER_LIN, 1 },
};

ModuleDesc gates_desc() {
    return ModuleDesc{ "GATES", &GATES_INPUTS[0], 6, &GATES_OUTPUTS[0], 9, &GATES_PARAMS[0], 6 };
}

struct GatesMod {
    ModBase base;
    bool[2] above;              // comparator states
    Schmitt[2] trig;
    Schmitt[2] or_in;
    i32[2] pulse_left;
}

void gates_mod_init(GatesMod* m, ModBase base) {
    *m = GatesMod{};
    m.base = base;
}

void gates_mod_reset(GatesMod* m) {
    ModBase b = m.base;
    gates_mod_init(m, b);
}

void gates_mod_tick(Core* c, GatesMod* m) {
    ModBase* b = &m.base;
    for i32 ch = 0; ch < 2; ch++ {
        i32 in0 = 3 * ch;               // this channel's first input, output and param
        f32 sig = mod_in(c, b, GATES_IN_SIG1 + in0);
        f32 th = mod_param(c, b, GATES_P_THRESH1 + in0);
        if m.above[ch] {
            if sig < th - 0.5f * GATES_HYST { m.above[ch] = false; }
        } else if sig > th + 0.5f * GATES_HYST {
            m.above[ch] = true;
        }

        bool was = m.trig[ch].high;
        bool trig = m.above[ch];
        if mod_patched(c, b, GATES_IN_TRIG1 + in0) {
            trig = schmitt(&m.trig[ch], mod_in(c, b, GATES_IN_TRIG1 + in0));
        } else {
            m.trig[ch].high = trig;
        }
        if trig && !was { m.pulse_left[ch] = cast(i32, mod_param(c, b, GATES_P_LENGTH1 + in0) * c.sample_rate); }
        f32 pulse = 0.0f;
        if m.pulse_left[ch] > 0 {
            m.pulse_left[ch]--;
            pulse = 1.0f;
        }

        f32 gate = 0.0f;
        if m.above[ch] { gate = 1.0f; }
        f32 v = 0.0f;
        if trig { v = GATES_VTRIG_V / c.out_scale[b.slot0 + GATES_OUT_V1 + in0]; }
        mod_out(c, b, GATES_OUT_GATE1 + in0, gate);
        mod_out(c, b, GATES_OUT_PULSE1 + in0, pulse);
        mod_out(c, b, GATES_OUT_V1 + in0, v);
    }
    bool a = schmitt(&m.or_in[0], mod_in(c, b, GATES_IN_OR1));
    bool o = schmitt(&m.or_in[1], mod_in(c, b, GATES_IN_OR2));
    f32 either = 0.0f;
    if a || o { either = 1.0f; }
    mod_out(c, b, GATES_OUT_OR, either);
    mod_out(c, b, GATES_OUT_B1, mod_param(c, b, GATES_P_BUTTON1));
    mod_out(c, b, GATES_OUT_B2, mod_param(c, b, GATES_P_BUTTON2));
}
