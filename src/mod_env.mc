// mod_env.mc: ENV, the contour generator.
//
// Gate and retrigger pass through Schmitt triggers into dsp_env. The rack
// normals every ENV gate to the KEYS gate, so a patch plays from the
// keyboard before any gate cable is plugged. Stage times are recomputed
// only when their knobs move.

import dsp_math;
import dsp_env;
import profile;
import engine_core;

enum EnvIn { ENV_IN_GATE, ENV_IN_RETRIG }
enum EnvOut { ENV_OUT_ENV, ENV_OUT_INV, ENV_OUT_EOC }
enum EnvParam { ENV_P_ATTACK, ENV_P_DECAY, ENV_P_SUSTAIN, ENV_P_RELEASE, ENV_P_LOOP }

PortDesc[2] ENV_INPUTS = {
    PortDesc{ "gate", CLS_TRIG, 0.0f },
    PortDesc{ "retrig", CLS_TRIG, 0.0f },
};

PortDesc[3] ENV_OUTPUTS = {
    PortDesc{ "env", CLS_CV_UNI, 0.0f },
    PortDesc{ "inv", CLS_CV_UNI, 0.0f },
    PortDesc{ "eoc", CLS_TRIG, 0.0f },
};

ParamDesc[5] ENV_PARAMS = {
    ParamDesc{ "attack", 0.005f, 0.001f, 10.0f, TAPER_EXP, 0 },
    ParamDesc{ "decay", 0.3f, 0.001f, 10.0f, TAPER_EXP, 0 },
    ParamDesc{ "sustain", 0.7f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "release", 0.3f, 0.001f, 10.0f, TAPER_EXP, 0 },
    ParamDesc{ "loop", 0.0f, 0.0f, 1.0f, TAPER_LIN, 2 },
};

ModuleDesc env_desc() {
    return ModuleDesc{ "ENV", &ENV_INPUTS[0], 2, &ENV_OUTPUTS[0], 3, &ENV_PARAMS[0], 5 };
}

// One voice's envelope and its gate edges.
struct EnvVoice {
    Env v;
    Schmitt gate;
    Schmitt retrig;
    TrigOut eoc;
}

struct EnvMod {
    ModBase base;
    Env v;                      // voice 0
    Schmitt gate;
    Schmitt retrig;
    TrigOut eoc;
    f32[4] set;                 // attack, decay, sustain, release dsp_env was set with
    EnvVoice[7] vp;             // voices 1 .. MAX_VOICES - 1
}

void env_mod_init(EnvMod* m, ModBase base) {
    *m = EnvMod{};
    m.base = base;
    m.set = { -1.0f, -1.0f, -1.0f, -1.0f };
}

void env_mod_reset(EnvMod* m) {
    ModBase b = m.base;
    env_mod_init(m, b);
}

void env_mod_tick(Core* c, EnvMod* m) {
    ModBase* b = &m.base;
    f32 a = mod_param(c, b, ENV_P_ATTACK);
    f32 d = mod_param(c, b, ENV_P_DECAY);
    f32 s = mod_param(c, b, ENV_P_SUSTAIN);
    f32 r = mod_param(c, b, ENV_P_RELEASE);
    if a != m.set[0] || d != m.set[1] || s != m.set[2] || r != m.set[3] {
        env_set(&m.v, a, d, s, r, c.sample_rate);
        for i32 v = 0; v < MAX_VOICES - 1; v++ { env_set(&m.vp[v].v, a, d, s, r, c.sample_rate); }
        m.set = { a, d, s, r };
    }
    bool loop = mod_param(c, b, ENV_P_LOOP) > 0.5f;
    m.v.loop = loop;
    bool gate = schmitt(&m.gate, mod_in(c, b, ENV_IN_GATE));
    bool retrig = schmitt(&m.retrig, mod_in(c, b, ENV_IN_RETRIG));
    f32 level = env_tick(&m.v, gate, retrig);
    if m.v.eoc { trig_fire(c, &m.eoc); }
    mod_out(c, b, ENV_OUT_ENV, level);
    mod_out(c, b, ENV_OUT_INV, 1.0f - level);
    mod_out(c, b, ENV_OUT_EOC, trig_tick(&m.eoc));

    // One envelope per channel of the gate (the KEYS gate, normalled, when
    // KEYS is polyphonic) and retrigger.
    i32 n = 1;
    if mod_poly(c, b) { n = mod_begin_voices(c, b, 0, 2); }
    for i32 v = 1; v < n; v++ {
        EnvVoice* ev = &m.vp[v - 1];
        ev.v.loop = loop;
        bool g = schmitt(&ev.gate, mod_in_ch(c, b, ENV_IN_GATE, v));
        bool rt = schmitt(&ev.retrig, mod_in_ch(c, b, ENV_IN_RETRIG, v));
        f32 lv = env_tick(&ev.v, g, rt);
        if ev.v.eoc { trig_fire(c, &ev.eoc); }
        mod_out_ch(c, b, ENV_OUT_ENV, v, lv);
        mod_out_ch(c, b, ENV_OUT_INV, v, 1.0f - lv);
        mod_out_ch(c, b, ENV_OUT_EOC, v, trig_tick(&ev.eoc));
    }
}
