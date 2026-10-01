// rack.mc: the fixed rack.
//
// Which modules exist, their stable ids (patch files name ports as
// "id.port"), the panel row each sits in, and the normals between them.
// Ids never change once patches use them. The default patch is data
// too, so the engine and the UI's patch model load it the same way.
//
// Rows: sound sources and the two ladder filters; the band and spectrum
// filters, envelopes and amplifiers; mixing, utilities, the scope and the
// output.

import str;
import engine_core;
import engine;

struct RackEntry {
    str id;
    i32 kind;
    i32 row;                            // panel row, top to bottom
}

RackEntry[30] RACK = {
    RackEntry{ "keys", KIND_KEYS, 0 },
    RackEntry{ "osc", KIND_OSC, 0 },
    RackEntry{ "bank1", KIND_BANK, 0 },
    RackEntry{ "bank2", KIND_BANK, 0 },
    RackEntry{ "noise", KIND_NOISE, 0 },
    RackEntry{ "seq", KIND_SEQ, 0 },
    RackEntry{ "lowpass", KIND_LOWPASS, 0 },
    RackEntry{ "highpass", KIND_HIGHPASS, 0 },
    RackEntry{ "band", KIND_BAND, 1 },
    RackEntry{ "spectrum", KIND_SPECTRUM, 1 },
    RackEntry{ "env1", KIND_ENV, 1 },
    RackEntry{ "env2", KIND_ENV, 1 },
    RackEntry{ "env3", KIND_ENV, 1 },
    RackEntry{ "env4", KIND_ENV, 1 },
    RackEntry{ "env5", KIND_ENV, 1 },
    RackEntry{ "amp1", KIND_AMP, 1 },
    RackEntry{ "amp2", KIND_AMP, 1 },
    RackEntry{ "amp3", KIND_AMP, 1 },
    RackEntry{ "amp4", KIND_AMP, 1 },
    RackEntry{ "amp5", KIND_AMP, 1 },
    RackEntry{ "mix1", KIND_MIX, 2 },
    RackEntry{ "mix2", KIND_MIX, 2 },
    RackEntry{ "gates", KIND_GATES, 2 },
    RackEntry{ "delay", KIND_DELAY, 2 },
    RackEntry{ "stepsw", KIND_STEPSW, 2 },
    RackEntry{ "offsets", KIND_OFFSETS, 2 },
    RackEntry{ "atten", KIND_ATTEN, 2 },
    RackEntry{ "mult", KIND_MULT, 2 },
    RackEntry{ "scope", KIND_SCOPE, 2 },
    RackEntry{ "out", KIND_OUT, 2 },
};
const i32 RACK_N = 30;
const i32 RACK_ROWS = 3;

// Panel row of module m (modules are added in RACK order).
i32 rack_row(i32 m) {
    if m < 0 || m >= RACK_N { return 0; }
    return RACK[m].row;
}

void rack_build(Engine* e) {
    for i32 i = 0; i < RACK_N; i++ { ignore engine_add(e, RACK[i].kind, RACK[i].id); }

    // Every ENV gate follows the KEYS gate until a cable goes in.
    i32 gate = engine_output(e, "keys", "gate");
    for i32 m = 0; m < e.n_modules; m++ {
        if e.modules[m].kind == KIND_ENV {
            e.core.jacks[e.modules[m].base.jack0 + ENV_IN_GATE].normal_src = gate;
            core_jacks_changed(&e.core);
        }
    }
}

// ---- the default patch ----

struct RackCable {
    str src;                            // "module.port" output
    str dst;                            // "module.port" input
}

struct RackSetting {
    str param;                          // "module.param"
    f32 value;                          // in the param's own units
}

// KEYS plays OSC through LOWPASS and AMP1; ENV1 shapes the amp, ENV2
// sweeps the cutoff.
RackCable[6] DEFAULT_CABLES = {
    RackCable{ "keys.pitch", "osc.pitch1" },
    RackCable{ "osc.saw", "lowpass.in1" },
    RackCable{ "lowpass.out", "amp1.in1" },
    RackCable{ "env1.env", "amp1.cv1" },
    RackCable{ "env2.env", "lowpass.cv1" },
    RackCable{ "amp1.out", "out.l" },
};
const i32 DEFAULT_CABLES_N = 6;

RackSetting[11] DEFAULT_SETTINGS = {
    RackSetting{ "lowpass.cutoff", -2.0f },
    RackSetting{ "lowpass.res", 0.6f },
    RackSetting{ "lowpass.cv1_depth", 0.5f },
    RackSetting{ "env1.attack", 0.002f },
    RackSetting{ "env1.decay", 0.4f },
    RackSetting{ "env1.sustain", 0.6f },
    RackSetting{ "env1.release", 0.2f },
    RackSetting{ "env2.attack", 0.002f },
    RackSetting{ "env2.decay", 0.25f },
    RackSetting{ "env2.sustain", 0.1f },
    RackSetting{ "env2.release", 0.2f },
};
const i32 DEFAULT_SETTINGS_N = 11;

// Sends the default patch to an engine as commands.
void rack_default_patch(Engine* e) {
    for i32 i = 0; i < DEFAULT_CABLES_N; i++ { ignore engine_connect(e, DEFAULT_CABLES[i].src, DEFAULT_CABLES[i].dst); }
    for i32 i = 0; i < DEFAULT_SETTINGS_N; i++ { ignore engine_set(e, DEFAULT_SETTINGS[i].param, DEFAULT_SETTINGS[i].value); }
}
