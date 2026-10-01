// mod_keys.mc: KEYS, the keyboard controller.
//
// Held notes arrive as commands. The sounding note follows the priority
// switch (last, low or high). Pitch glides with an exponential slew in
// the volt domain, gate is high while any key is held, and trig fires on
// every new key, legato ones included.
//
// With VOICES above 1 it is polyphonic: each new key takes a voice of its
// own (a free one, the one released longest ago first, else the oldest
// held one) and the three outputs carry one channel per voice. A voice
// keeps its pitch after its key is released, so a release tail stays in
// tune; glide is per voice.

import dsp_math;
import profile;
import engine_core;

enum KeysOut { KEYS_OUT_PITCH, KEYS_OUT_GATE, KEYS_OUT_TRIG }
enum KeysParam { KEYS_P_GLIDE, KEYS_P_OCTAVE, KEYS_P_PRIORITY, KEYS_P_VOICES }
enum KeysPriority { PRIORITY_LAST, PRIORITY_LOW, PRIORITY_HIGH }

PortDesc[3] KEYS_OUTPUTS = {
    PortDesc{ "pitch", CLS_PITCH, 0.0f },
    PortDesc{ "gate", CLS_TRIG, 0.0f },
    PortDesc{ "trig", CLS_TRIG, 0.0f },
};

ParamDesc[4] KEYS_PARAMS = {
    ParamDesc{ "glide", 0.001f, 0.001f, 2.0f, TAPER_EXP, 0 },     // seconds to 99 %
    ParamDesc{ "octave", 0.0f, -3.0f, 3.0f, TAPER_LIN, 7 },
    ParamDesc{ "priority", 1.0f, 0.0f, 2.0f, TAPER_LIN, 3 },      // KeysPriority, mono only; low, as the classic keyboards
    ParamDesc{ "voices", 1.0f, 1.0f, 8.0f, TAPER_LIN, 8 },        // 1 is mono
};

ModuleDesc keys_desc() {
    return ModuleDesc{ "KEYS", null, 0, &KEYS_OUTPUTS[0], 3, &KEYS_PARAMS[0], 4 };
}

const i32 KEYS_MAX_HELD = 16;
const i32 KEYS_NO_NOTE = -1;

// One voice when KEYS is polyphonic.
struct KeysVoice {
    i32 note;                   // KEYS_NO_NOTE before its first key
    bool gate;
    bool pressed;               // its key went down since the last tick
    bool fresh;                 // no pitch yet: the first note does not glide in
    u32 stamp;                  // when its key went down or up, for choosing a voice
    Smooth pitch;               // volts
    TrigOut trig;
}

struct KeysMod {
    ModBase base;
    i32[16] held;               // held notes, oldest first
    i32 n_held;
    i32 note;                   // sounding note, KEYS_NO_NOTE before the first key
    bool pressed;               // a key went down since the last tick
    Smooth pitch;               // volts
    f32 glide_s;                // glide the smoother coefficient was made for
    TrigOut trig;
    i32 voices;                 // the VOICES switch as last seen; 1 is mono
    KeysVoice[8] voice;         // MAX_VOICES
    u32 clock;                  // counts key events
}

void keys_mod_init(KeysMod* k, ModBase base) {
    *k = KeysMod{};
    k.base = base;
    k.note = KEYS_NO_NOTE;
    k.glide_s = -1.0f;
    k.voices = 1;
    for i32 v = 0; v < MAX_VOICES; v++ {
        k.voice[v].note = KEYS_NO_NOTE;
        k.voice[v].fresh = true;
    }
}

// Releases every key; the pitch stays where it is.
void keys_mod_reset(KeysMod* k) {
    k.n_held = 0;
    k.pressed = false;
    k.trig.left = 0;
    for i32 v = 0; v < MAX_VOICES; v++ {
        k.voice[v].gate = false;
        k.voice[v].pressed = false;
        k.voice[v].trig.left = 0;
    }
}

// The voice for a new key: the one already playing it, else a free one
// (released longest ago), else the one held longest.
private i32 keys_pick_voice(KeysMod* k, i32 note) {
    for i32 v = 0; v < k.voices; v++ { if k.voice[v].gate && k.voice[v].note == note { return v; } }
    i32 best = -1;
    for i32 v = 0; v < k.voices; v++ {
        if k.voice[v].gate { continue; }
        if best < 0 || k.voice[v].stamp < k.voice[best].stamp { best = v; }
    }
    if best >= 0 { return best; }
    best = 0;
    for i32 v = 1; v < k.voices; v++ { if k.voice[v].stamp < k.voice[best].stamp { best = v; } }
    return best;
}

void keys_note_off(KeysMod* k, i32 note) {
    for i32 v = 0; v < MAX_VOICES; v++ {
        if k.voice[v].gate && k.voice[v].note == note {
            k.voice[v].gate = false;
            k.clock++;
            k.voice[v].stamp = k.clock;
        }
    }
    i32 w = 0;
    for i32 i = 0; i < k.n_held; i++ {
        if k.held[i] != note {
            k.held[w] = k.held[i];
            w++;
        }
    }
    k.n_held = w;
}

void keys_note_on(KeysMod* k, i32 note) {
    keys_note_off(k, note);                     // a repeated key moves to the top
    if k.n_held == KEYS_MAX_HELD {
        for i32 i = 1; i < KEYS_MAX_HELD; i++ { k.held[i - 1] = k.held[i]; }
        k.n_held--;
    }
    k.held[k.n_held] = note;
    k.n_held++;
    k.pressed = true;
    if k.voices > 1 {
        KeysVoice* kv = &k.voice[keys_pick_voice(k, note)];
        kv.note = note;
        kv.gate = true;
        kv.pressed = true;
        k.clock++;
        kv.stamp = k.clock;
    }
}

private i32 keys_choose(KeysMod* k, i32 priority) {
    i32 n = k.held[k.n_held - 1];
    if priority == PRIORITY_LOW {
        for i32 i = 0; i < k.n_held; i++ { if k.held[i] < n { n = k.held[i]; } }
    } else if priority == PRIORITY_HIGH {
        for i32 i = 0; i < k.n_held; i++ { if k.held[i] > n { n = k.held[i]; } }
    }
    return n;
}

// Polyphonic: every voice its own pitch, gate and trigger.
private void keys_poly_tick(Core* c, KeysMod* k, f32 glide) {
    ModBase* b = &k.base;
    f32 octave = mod_param(c, b, KEYS_P_OCTAVE);
    for i32 v = 0; v < k.voices; v++ {
        KeysVoice* kv = &k.voice[v];
        if kv.pressed {
            trig_fire(c, &kv.trig);
            kv.pressed = false;
        }
        kv.pitch.a = k.pitch.a;
        f32 target = octave;
        if kv.note != KEYS_NO_NOTE { target += cast(f32, kv.note - 60) / 12.0f; }
        if kv.fresh && kv.gate {
            kv.pitch.y = target;
            kv.fresh = false;
        }
        mod_out_ch(c, b, KEYS_OUT_PITCH, v, smooth_step(&kv.pitch, target));
        mod_out_ch(c, b, KEYS_OUT_GATE, v, kv.gate ? 1.0f : 0.0f);
        mod_out_ch(c, b, KEYS_OUT_TRIG, v, trig_tick(&kv.trig));
    }
    for i32 o = 0; o < 3; o++ { mod_set_channels(c, b, o, k.voices); }
}

// A change of VOICES starts the voices afresh from the keys held now.
private void keys_set_voices(KeysMod* k, i32 n) {
    k.voices = n;
    for i32 v = 0; v < MAX_VOICES; v++ {
        k.voice[v].gate = false;
        k.voice[v].pressed = false;
    }
    if n == 1 { return; }
    for i32 i = 0; i < k.n_held; i++ {
        KeysVoice* kv = &k.voice[keys_pick_voice(k, k.held[i])];
        kv.note = k.held[i];
        kv.gate = true;
        k.clock++;
        kv.stamp = k.clock;
    }
}

void keys_mod_tick(Core* c, KeysMod* k) {
    ModBase* b = &k.base;
    i32 voices = clampi(cast(i32, mod_param(c, b, KEYS_P_VOICES) + 0.5f), 1, MAX_VOICES);
    if voices != k.voices {
        keys_set_voices(k, voices);
        for i32 o = 0; o < 3; o++ { mod_reset_channels(c, b, o); }
    }
    if voices > 1 {
        f32 g = mod_param(c, b, KEYS_P_GLIDE);
        if g != k.glide_s {
            k.glide_s = g;
            k.pitch.a = onepole_coef(g / 4.6f, c.sample_rate);
        }
        keys_poly_tick(c, k, g);
        k.pressed = false;
        if k.n_held > 0 { k.note = k.held[k.n_held - 1]; }
        return;
    }
    bool gate = k.n_held > 0;
    bool first = k.note == KEYS_NO_NOTE;
    if gate { k.note = keys_choose(k, cast(i32, mod_param(c, b, KEYS_P_PRIORITY))); }
    if k.pressed {
        trig_fire(c, &k.trig);
        k.pressed = false;
    }

    f32 glide = mod_param(c, b, KEYS_P_GLIDE);
    if glide != k.glide_s {
        k.glide_s = glide;
        k.pitch.a = onepole_coef(glide / 4.6f, c.sample_rate);
    }
    f32 target = mod_param(c, b, KEYS_P_OCTAVE);
    if k.note != KEYS_NO_NOTE { target += cast(f32, k.note - 60) / 12.0f; }
    if first && gate { k.pitch.y = target; }    // the first note does not glide in from 0 V

    mod_out(c, b, KEYS_OUT_PITCH, smooth_step(&k.pitch, target));
    mod_out(c, b, KEYS_OUT_GATE, gate ? 1.0f : 0.0f);
    mod_out(c, b, KEYS_OUT_TRIG, trig_tick(&k.trig));
}
