// engine.mc: the running rack.
//
// Owns the module instances, ticks them kind by kind, applies commands at
// the start of each block, fades the master output for panics and patch
// loads, publishes telemetry, and resets any module whose output stops
// being a finite number.
//
// Threads: the audio side calls engine_render; the UI side sends commands
// (engine_send and the helpers below) and reads telemetry. The module
// registry is written once while the rack is built and only read after.

import atomic;
import math;
import str;
import dsp_math;
import dsp_ladder;
import profile;
import engine_core;
import engine_cmd;
import mod_keys;
import mod_osc;
import mod_lowpass;
import mod_amp;
import mod_env;
import mod_noise;
import mod_mix;
import mod_out;
import mod_bank;
import mod_seq;
import mod_highpass;
import mod_band;
import mod_spectrum;
import mod_delay;
import mod_stepsw;
import mod_gates;
import mod_offsets;
import mod_atten;
import mod_mult;
import mod_scope;

enum ModKind {
    KIND_KEYS, KIND_OSC, KIND_LOWPASS, KIND_AMP, KIND_ENV, KIND_NOISE, KIND_MIX, KIND_OUT,
    KIND_BANK, KIND_SEQ, KIND_HIGHPASS, KIND_BAND, KIND_SPECTRUM, KIND_DELAY, KIND_STEPSW,
    KIND_GATES, KIND_OFFSETS, KIND_ATTEN, KIND_MULT, KIND_SCOPE
}

const i32 MAX_MODULES = 64;
const i32 MAX_PER_KIND = 8;
const f32 MASTER_FADE_S = 0.01f;
const f32 PEAK_WINDOW_S = 0.05f;        // telemetry peak window: one period at 20 Hz

// Engine rate against the device rate. NORMAL runs at 2x and HIGH at 4x;
// 1x (engine_new) is for measurements that need one tick per frame.
enum Quality { QUALITY_NORMAL, QUALITY_HIGH }

i32 quality_oversample(i32 quality) {
    if quality == QUALITY_HIGH { return 4; }
    return 2;
}

enum Hold { HOLD_NONE, HOLD_LOAD, HOLD_PANIC }

struct ModuleInfo {
    str id;                             // stable name: "lowpass", "env1"
    i32 kind;
    i32 index;                          // into the kind's instance array
    ModBase base;
    ModuleDesc desc;
}

struct Engine {
    Core core;
    ModuleInfo[MAX_MODULES] modules;
    i32 n_modules;
    KeysMod[MAX_PER_KIND] keys;
    i32 n_keys;
    OscMod[MAX_PER_KIND] osc;
    i32 n_osc;
    LowpassMod[MAX_PER_KIND] lowpass;
    i32 n_lowpass;
    AmpMod[MAX_PER_KIND] amp;
    i32 n_amp;
    EnvMod[MAX_PER_KIND] env;
    i32 n_env;
    NoiseMod[MAX_PER_KIND] noise;
    i32 n_noise;
    MixMod[MAX_PER_KIND] mix;
    i32 n_mix;
    OutMod out;
    bool has_out;
    BankMod[MAX_PER_KIND] bank;
    i32 n_bank;
    SeqMod[MAX_PER_KIND] seq;
    i32 n_seq;
    HighpassMod[MAX_PER_KIND] highpass;
    i32 n_highpass;
    BandMod[MAX_PER_KIND] band;
    i32 n_band;
    SpectrumMod[MAX_PER_KIND] spectrum;
    i32 n_spectrum;
    DelayMod[MAX_PER_KIND] delay;
    i32 n_delay;
    StepswMod[MAX_PER_KIND] stepsw;
    i32 n_stepsw;
    GatesMod[MAX_PER_KIND] gates;
    i32 n_gates;
    OffsetsMod[MAX_PER_KIND] offsets;
    i32 n_offsets;
    AttenMod[MAX_PER_KIND] atten;
    i32 n_atten;
    MultMod[MAX_PER_KIND] mult;
    i32 n_mult;
    ScopeMod scope;
    bool has_scope;
    CmdRing cmds;
    Telemetry tele;
    f32[MAX_SLOTS] peak_now;            // per slot, the peak of the telemetry window so far
    f32[MAX_SLOTS] peak_last;           // and of the whole window before it
    i32 peak_frames;                    // device frames into the window
    i32 scope_count;                    // device frames since the last recorded scope frame
    i32[2] scope_src;                   // slot per scope channel; -1 is the master output
    f32 fade;                           // master fade, 0..1
    f32 fade_target;
    f32 fade_step;
    i32 hold;                           // Hold: what the engine waits for at silence
    Rng rng;
    f32 device_rate;                    // the rate engine_render delivers
    i32 os;                             // engine ticks per device frame: 1, 2 or 4
    Halfband[2] dec_l;                  // output decimators, one stage per halving
    Halfband[2] dec_r;
}

// An engine ticking `oversample` times per device frame (1, 2 or 4),
// with one decimation to the device rate at the output. Modules see the
// engine rate; cables are one engine tick of delay.
Engine* engine_new_os(f32 device_rate, i32 oversample) {
    i32 os = oversample;
    if os != 2 && os != 4 { os = 1; }
    Engine* e = new(Engine);
    f32 rate = device_rate * cast(f32, os);
    core_init(&e.core, rate);
    e.device_rate = device_rate;
    e.os = os;
    halfband_design();
    e.fade = 1.0f;
    e.fade_target = 1.0f;
    e.fade_step = 1.0f / (MASTER_FADE_S * rate);
    e.scope_src = { -1, -1 };
    e.tele.note = KEYS_NO_NOTE;
    rng_seed(&e.rng, 0x5EED5, 3);
    return e;
}

// One engine tick per frame, for measurements and tests.
Engine* engine_new(f32 sample_rate) { return engine_new_os(sample_rate, 1); }

void engine_free(Engine* e) { free(e); }

ModuleDesc kind_desc(i32 kind) {
    switch kind {
        case KIND_KEYS: { return keys_desc(); }
        case KIND_OSC: { return osc_desc(); }
        case KIND_LOWPASS: { return lowpass_desc(); }
        case KIND_AMP: { return amp_desc(); }
        case KIND_ENV: { return env_desc(); }
        case KIND_NOISE: { return noise_desc(); }
        case KIND_MIX: { return mix_desc(); }
        case KIND_BANK: { return bank_desc(); }
        case KIND_SEQ: { return seq_desc(); }
        case KIND_HIGHPASS: { return highpass_desc(); }
        case KIND_BAND: { return band_desc(); }
        case KIND_SPECTRUM: { return spectrum_desc(); }
        case KIND_DELAY: { return delay_desc(); }
        case KIND_STEPSW: { return stepsw_desc(); }
        case KIND_GATES: { return gates_desc(); }
        case KIND_OFFSETS: { return offsets_desc(); }
        case KIND_ATTEN: { return atten_desc(); }
        case KIND_MULT: { return mult_desc(); }
        case KIND_SCOPE: { return scope_desc(); }
        default: { return out_desc(); }
    }
}

// The next free instance of a kind: its index, counted, or -1 when full.
private i32 take(i32* n) {
    if *n == MAX_PER_KIND { return -1; }
    i32 i = *n;
    *n += 1;
    return i;
}

// A random start phase, so free-running oscillators beat.
private f64 start_phase(Engine* e) { return cast(f64, (rng_uniform(&e.rng) + 1.0f) * 0.5f); }

// A seed for a module's tolerances (dsp_age): the rack order decides it,
// so a rebuilt engine ages the same way.
private u64 seed_for(Engine* e) { return cast(u64, rng_next(&e.rng)); }

// ---- building the rack ----

// Adds a module and registers its ports and params. Returns its index,
// or -1 when the rack or the kind is full.
i32 engine_add(Engine* e, i32 kind, str id) {
    if e.n_modules == MAX_MODULES { return -1; }
    Core* c = &e.core;
    ModuleDesc d = kind_desc(kind);
    i32 m = e.n_modules;
    ModBase b = ModBase{ m, c.n_jacks, c.n_slots, c.n_params, d.n_outputs, 1 };
    i32 index = 0;
    switch kind {
        case KIND_KEYS: {
            if e.n_keys == MAX_PER_KIND { return -1; }
            index = e.n_keys;
            e.n_keys++;
            keys_mod_init(&e.keys[index], b);
        }
        case KIND_OSC: {
            if e.n_osc == MAX_PER_KIND { return -1; }
            index = e.n_osc;
            e.n_osc++;
            f32 u = (rng_uniform(&e.rng) + 1.0f) * 0.5f;   // free-running: a random start phase
            osc_mod_init(&e.osc[index], b, u, seed_for(e), c.sample_rate);
        }
        case KIND_LOWPASS: {
            if e.n_lowpass == MAX_PER_KIND { return -1; }
            index = e.n_lowpass;
            e.n_lowpass++;
            lowpass_mod_init(&e.lowpass[index], b, seed_for(e));
        }
        case KIND_AMP: {
            if e.n_amp == MAX_PER_KIND { return -1; }
            index = e.n_amp;
            e.n_amp++;
            amp_mod_init(&e.amp[index], b);
        }
        case KIND_ENV: {
            if e.n_env == MAX_PER_KIND { return -1; }
            index = e.n_env;
            e.n_env++;
            env_mod_init(&e.env[index], b);
        }
        case KIND_NOISE: {
            if e.n_noise == MAX_PER_KIND { return -1; }
            index = e.n_noise;
            e.n_noise++;
            noise_mod_init(&e.noise[index], b, cast(u64, 1000 + m));
        }
        case KIND_MIX: {
            if e.n_mix == MAX_PER_KIND { return -1; }
            index = e.n_mix;
            e.n_mix++;
            mix_mod_init(&e.mix[index], b);
        }
        case KIND_BANK: {
            index = take(&e.n_bank);
            if index < 0 { return -1; }
            bank_mod_init(&e.bank[index], b, start_phase(e), start_phase(e), start_phase(e), seed_for(e), c.sample_rate);
        }
        case KIND_SEQ: {
            index = take(&e.n_seq);
            if index < 0 { return -1; }
            seq_mod_init(&e.seq[index], b);
        }
        case KIND_HIGHPASS: {
            index = take(&e.n_highpass);
            if index < 0 { return -1; }
            highpass_mod_init(&e.highpass[index], b, seed_for(e));
        }
        case KIND_BAND: {
            index = take(&e.n_band);
            if index < 0 { return -1; }
            band_mod_init(&e.band[index], b);
        }
        case KIND_SPECTRUM: {
            index = take(&e.n_spectrum);
            if index < 0 { return -1; }
            spectrum_mod_init(&e.spectrum[index], b, c.sample_rate);
        }
        case KIND_DELAY: {
            index = take(&e.n_delay);
            if index < 0 { return -1; }
            delay_mod_init(&e.delay[index], b);
        }
        case KIND_STEPSW: {
            index = take(&e.n_stepsw);
            if index < 0 { return -1; }
            stepsw_mod_init(&e.stepsw[index], b);
        }
        case KIND_GATES: {
            index = take(&e.n_gates);
            if index < 0 { return -1; }
            gates_mod_init(&e.gates[index], b);
        }
        case KIND_OFFSETS: {
            index = take(&e.n_offsets);
            if index < 0 { return -1; }
            offsets_mod_init(&e.offsets[index], b);
        }
        case KIND_ATTEN: {
            index = take(&e.n_atten);
            if index < 0 { return -1; }
            atten_mod_init(&e.atten[index], b);
        }
        case KIND_MULT: {
            index = take(&e.n_mult);
            if index < 0 { return -1; }
            mult_mod_init(&e.mult[index], b);
        }
        case KIND_SCOPE: {
            if e.has_scope { return -1; }
            e.has_scope = true;
            scope_mod_init(&e.scope, b);
        }
        default: {
            if e.has_out { return -1; }
            e.has_out = true;
            out_mod_init(&e.out, b, c.sample_rate);
        }
    }
    for i32 i = 0; i < d.n_inputs; i++ { ignore core_add_input(c, d.inputs[i].cls, d.inputs[i].normal, m); }
    for i32 i = 0; i < d.n_outputs; i++ { ignore core_add_output(c, d.outputs[i].cls, m); }
    for i32 i = 0; i < d.n_params; i++ { ignore core_add_param(c, &d.params[i]); }
    ModuleInfo* info = &e.modules[m];
    info.id = id;
    info.kind = kind;
    info.index = index;
    info.base = b;
    info.desc = d;
    e.n_modules++;
    return m;
}

// ---- lookups by name ----

i32 engine_module(Engine* e, str id) {
    for i32 m = 0; m < e.n_modules; m++ {
        if str_equal(e.modules[m].id, id) { return m; }
    }
    return -1;
}

private i32 port_index(PortDesc* ports, i32 n, str name) {
    for i32 i = 0; i < n; i++ {
        if str_equal(ports[i].name, name) { return i; }
    }
    return -1;
}

i32 engine_output(Engine* e, str module, str port) {
    i32 m = engine_module(e, module);
    if m < 0 { return -1; }
    ModuleInfo* info = &e.modules[m];
    i32 i = port_index(info.desc.outputs, info.desc.n_outputs, port);
    if i < 0 { return -1; }
    return info.base.slot0 + i;
}

i32 engine_input(Engine* e, str module, str port) {
    i32 m = engine_module(e, module);
    if m < 0 { return -1; }
    ModuleInfo* info = &e.modules[m];
    i32 i = port_index(info.desc.inputs, info.desc.n_inputs, port);
    if i < 0 { return -1; }
    return info.base.jack0 + i;
}

i32 engine_param(Engine* e, str module, str name) {
    i32 m = engine_module(e, module);
    if m < 0 { return -1; }
    ModuleInfo* info = &e.modules[m];
    for i32 i = 0; i < info.desc.n_params; i++ {
        if str_equal(info.desc.params[i].name, name) { return info.base.param0 + i; }
    }
    return -1;
}

// Splits "module.port" at its first dot: ids have none, port names may
// ("spectrum.5.6k").
private bool split_ref(str ref, str* module, str* port) {
    for i32 i = 1; i < ref.len - 1; i++ {
        if ref.data[i] == '.' {
            *module = str_from(ref.data, i);
            *port = str_from(ref.data + i + 1, ref.len - i - 1);
            return true;
        }
    }
    return false;
}

i32 engine_output_ref(Engine* e, str ref) {
    str m = "";
    str p = "";
    if !split_ref(ref, &m, &p) { return -1; }
    return engine_output(e, m, p);
}

i32 engine_input_ref(Engine* e, str ref) {
    str m = "";
    str p = "";
    if !split_ref(ref, &m, &p) { return -1; }
    return engine_input(e, m, p);
}

i32 engine_param_ref(Engine* e, str ref) {
    str m = "";
    str p = "";
    if !split_ref(ref, &m, &p) { return -1; }
    return engine_param(e, m, p);
}

// ---- UI side: sending ----

bool engine_send(Engine* e, Cmd c) { return cmd_push(&e.cmds, c); }

bool engine_send_kind(Engine* e, i32 kind, i32 a, i32 b, f32 value) {
    return cmd_push(&e.cmds, Cmd{ kind, a, b, value });
}

// "osc.saw" -> "lowpass.in1". False if a name doesn't resolve or the ring is full.
bool engine_connect(Engine* e, str src, str dst) {
    i32 s = engine_output_ref(e, src);
    i32 j = engine_input_ref(e, dst);
    if s < 0 || j < 0 { return false; }
    return engine_send_kind(e, CMD_CONNECT, s, j, 0.0f);
}

bool engine_disconnect(Engine* e, str src, str dst) {
    i32 s = engine_output_ref(e, src);
    i32 j = engine_input_ref(e, dst);
    if s < 0 || j < 0 { return false; }
    return engine_send_kind(e, CMD_DISCONNECT, s, j, 0.0f);
}

// A param by name, in its own units ("lowpass.cutoff", 1.5 volts).
bool engine_set(Engine* e, str ref, f32 value) {
    i32 p = engine_param_ref(e, ref);
    if p < 0 { return false; }
    return engine_send_kind(e, CMD_PARAM, p, 0, param_unmap(&e.core.params[p], value));
}

bool engine_key_on(Engine* e, i32 note) { return engine_send_kind(e, CMD_KEY_ON, note, 0, 0.0f); }
bool engine_key_off(Engine* e, i32 note) { return engine_send_kind(e, CMD_KEY_OFF, note, 0, 0.0f); }

// ---- audio side ----

void engine_reset_module(Engine* e, i32 m) {
    if m < 0 || m >= e.n_modules { return; }
    ModuleInfo* info = &e.modules[m];
    i32 i = info.index;
    switch info.kind {
        case KIND_KEYS: { keys_mod_reset(&e.keys[i]); }
        case KIND_OSC: { osc_mod_reset(&e.osc[i]); }
        case KIND_LOWPASS: { lowpass_mod_reset(&e.lowpass[i]); }
        case KIND_ENV: { env_mod_reset(&e.env[i]); }
        case KIND_NOISE: { noise_mod_reset(&e.noise[i]); }
        case KIND_OUT: { out_mod_reset(&e.out); }
        case KIND_BANK: { bank_mod_reset(&e.bank[i]); }
        case KIND_SEQ: { seq_mod_reset(&e.seq[i]); }
        case KIND_HIGHPASS: { highpass_mod_reset(&e.highpass[i]); }
        case KIND_BAND: { band_mod_reset(&e.band[i]); }
        case KIND_SPECTRUM: { spectrum_mod_reset(&e.spectrum[i]); }
        case KIND_DELAY: { delay_mod_reset(&e.delay[i]); }
        case KIND_STEPSW: { stepsw_mod_reset(&e.stepsw[i]); }
        case KIND_GATES: { gates_mod_reset(&e.gates[i]); }
        default: {}                     // the rest hold no state
    }
    for i32 o = 0; o < info.desc.n_outputs; o++ {
        slot_clear(&e.core, info.base.slot0 + o);
    }
}

private void engine_apply(Engine* e, Cmd c) {
    Core* core = &e.core;
    switch c.kind {
        case CMD_PARAM: { core_set_param(core, c.a, c.value); }
        case CMD_CONNECT: { ignore core_connect(core, c.a, c.b); }
        case CMD_DISCONNECT: { ignore core_disconnect(core, c.a, c.b); }
        case CMD_KEY_ON: {
            for i32 i = 0; i < e.n_keys; i++ {
                keys_note_on(&e.keys[i], c.a);
                ignore atomic_add(&e.tele.events[e.keys[i].base.id], 1);
            }
        }
        case CMD_KEY_OFF: { for i32 i = 0; i < e.n_keys; i++ { keys_note_off(&e.keys[i], c.a); } }
        case CMD_RESET_MODULE: { engine_reset_module(e, c.a); }
        case CMD_PROFILE: { core_set_profile(core, c.a); }
        case CMD_FEEL: { if c.a == FEEL_SMOOTH || c.a == FEEL_AUTHENTIC { core.feel = c.a; } }
        case CMD_SCOPE: { if c.a == 0 || c.a == 1 { e.scope_src[c.a] = c.b; } }
        default: {}
    }
}

// Applies pending commands. A patch load and a panic both wait for the
// master fade to reach silence first; the load then applies everything up
// to LOAD_END in one go.
private void engine_drain(Engine* e) {
    if e.hold == HOLD_PANIC {
        if e.fade > 0.0f { return; }
        for i32 m = 0; m < e.n_modules; m++ { engine_reset_module(e, m); }
        e.hold = HOLD_NONE;
        e.fade_target = 1.0f;
    }
    if e.hold == HOLD_LOAD && e.fade > 0.0f { return; }
    Cmd c;
    while cmd_pop(&e.cmds, &c) {
        if c.kind == CMD_LOAD_BEGIN {
            e.hold = HOLD_LOAD;
            e.fade_target = 0.0f;
            if e.fade > 0.0f { return; }
        } else if c.kind == CMD_LOAD_END {
            e.hold = HOLD_NONE;
            e.fade_target = 1.0f;
        } else if c.kind == CMD_PANIC {
            e.hold = HOLD_PANIC;
            e.fade_target = 0.0f;
            return;
        } else {
            engine_apply(e, c);
        }
    }
}

private bool is_finite(f32 x) { return x == x && x < 1e30f && x > -1e30f; }

// After a block: any module whose outputs are not finite is reset.
private void engine_guard(Engine* e) {
    Core* c = &e.core;
    for i32 m = 0; m < e.n_modules; m++ {
        ModuleInfo* info = &e.modules[m];
        bool bad = false;
        for i32 o = 0; o < info.desc.n_outputs; o++ {
            if !is_finite(slot_value(c, info.base.slot0 + o)) { bad = true; }
        }
        if info.kind == KIND_OUT && (!is_finite(e.out.dc_l.y1) || !is_finite(e.out.dc_r.y1)) { bad = true; }
        if bad {
            engine_reset_module(e, m);
            ignore atomic_add(&e.tele.nan_resets, 1);
        }
    }
}

// One tick at the engine rate: every module, then OUT and the master fade.
private void engine_tick(Engine* e, f32* l, f32* r) {
    Core* c = &e.core;
    core_step_params(c);
    core_step_jacks(c);
    if e.has_out { c.age = param(c, e.out.base.param0 + OUT_P_AGE); }
    for i32 i = 0; i < e.n_keys; i++ { keys_mod_tick(c, &e.keys[i]); }
    for i32 i = 0; i < e.n_noise; i++ { noise_mod_tick(c, &e.noise[i]); }
    for i32 i = 0; i < e.n_osc; i++ { osc_mod_tick(c, &e.osc[i]); }
    for i32 i = 0; i < e.n_env; i++ { env_mod_tick(c, &e.env[i]); }
    for i32 i = 0; i < e.n_lowpass; i++ { lowpass_mod_tick(c, &e.lowpass[i]); }
    for i32 i = 0; i < e.n_amp; i++ { amp_mod_tick(c, &e.amp[i]); }
    for i32 i = 0; i < e.n_mix; i++ { mix_mod_tick(c, &e.mix[i]); }
    for i32 i = 0; i < e.n_bank; i++ { bank_mod_tick(c, &e.bank[i]); }
    for i32 i = 0; i < e.n_seq; i++ { seq_mod_tick(c, &e.seq[i]); }
    for i32 i = 0; i < e.n_highpass; i++ { highpass_mod_tick(c, &e.highpass[i]); }
    for i32 i = 0; i < e.n_band; i++ { band_mod_tick(c, &e.band[i]); }
    for i32 i = 0; i < e.n_spectrum; i++ { spectrum_mod_tick(c, &e.spectrum[i]); }
    for i32 i = 0; i < e.n_delay; i++ { delay_mod_tick(c, &e.delay[i]); }
    for i32 i = 0; i < e.n_stepsw; i++ { stepsw_mod_tick(c, &e.stepsw[i]); }
    for i32 i = 0; i < e.n_gates; i++ { gates_mod_tick(c, &e.gates[i]); }
    for i32 i = 0; i < e.n_offsets; i++ { offsets_mod_tick(c, &e.offsets[i]); }
    for i32 i = 0; i < e.n_atten; i++ { atten_mod_tick(c, &e.atten[i]); }
    for i32 i = 0; i < e.n_mult; i++ { mult_mod_tick(c, &e.mult[i]); }
    f32 lv = 0.0f;
    f32 rv = 0.0f;
    if e.has_out {
        out_mod_tick(c, &e.out);
        lv = e.out.l;
        rv = e.out.r;
    }
    if e.fade < e.fade_target {
        e.fade = clampf(e.fade + e.fade_step, 0.0f, e.fade_target);
    } else if e.fade > e.fade_target {
        e.fade = clampf(e.fade - e.fade_step, e.fade_target, 1.0f);
    }
    *l = lv * e.fade;
    *r = rv * e.fade;
    core_swap(c);
}

// Engine-rate samples down to one device-rate sample.
f32 engine_decimate(Halfband* d, i32 os, f32* x) {
    if os == 1 { return x[0]; }
    if os == 2 { return halfband_down(&d[0], x[0], x[1]); }
    f32 a = halfband_down(&d[0], x[0], x[1]);
    f32 b = halfband_down(&d[0], x[2], x[3]);
    return halfband_down(&d[1], a, b);
}

// Renders `frames` interleaved frames at the device rate. One or two
// channels carry the output; channels past two are silent.
void engine_render(Engine* e, f32* out, i32 frames, i32 channels) {
    engine_drain(e);
    Core* c = &e.core;
    u32 w = e.tele.scope_w;
    f32 out_peak = 0.0f;
    i32 decim = 1;
    if e.has_scope { decim = scope_decimation(param(c, e.scope.base.param0 + SCOPE_P_TIME), e.device_rate); }
    f32[4] ls;
    f32[4] rs;
    for i32 n = 0; n < frames; n++ {
        for i32 s = 0; s < e.os; s++ { engine_tick(e, &ls[s], &rs[s]); }
        // Telemetry peaks, sampled once a frame: enough for a level to
        // read and for a 2 ms trigger to register.
        if c.poly_hold > 0 {
            for i32 s = 0; s < c.n_slots; s++ {
                f32 a = fabsf(slot_value(c, s));
                i32 nc = c.chrd[s];
                for i32 v = 1; v < nc; v++ { a = maxf(a, fabsf(slot_voice(c, s, v))); }      // the loudest voice
                if a > e.peak_now[s] { e.peak_now[s] = a; }
            }
        } else {
            for i32 s = 0; s < c.n_slots; s++ {
                f32 a = fabsf(slot_value(c, s));
                if a > e.peak_now[s] { e.peak_now[s] = a; }
            }
        }
        f32 l = engine_decimate(&e.dec_l[0], e.os, &ls[0]);
        f32 r = engine_decimate(&e.dec_r[0], e.os, &rs[0]);
        if !is_finite(l) {
            l = 0.0f;
            e.dec_l = { Halfband{}, Halfband{} };
        }
        if !is_finite(r) {
            r = 0.0f;
            e.dec_r = { Halfband{}, Halfband{} };
        }

        if channels == 1 {
            out[n] = 0.5f * (l + r);
        } else {
            out[n * channels] = l;
            out[n * channels + 1] = r;
            for i32 k = 2; k < channels; k++ { out[n * channels + k] = 0.0f; }
        }

        if fabsf(l) > out_peak { out_peak = fabsf(l); }
        if fabsf(r) > out_peak { out_peak = fabsf(r); }
        // With a SCOPE module its inputs are recorded, one frame in every
        // `decim`; otherwise the chosen slots, every frame. Until a cable
        // goes into A, A shows the output, in volts on the audio scale.
        if e.has_scope {
            e.scope_count++;
            if e.scope_count >= decim {
                e.scope_count = 0;
                f32 a = l / OUT_HALF_SCALE * profile_scale(c.profile, CLS_AUDIO);
                if jack_patched(c, e.scope.base.jack0 + SCOPE_IN_A) { a = scope_volts(c, &e.scope, SCOPE_IN_A); }
                e.tele.scope[0][w & SCOPE_MASK] = a;
                e.tele.scope[1][w & SCOPE_MASK] = scope_volts(c, &e.scope, SCOPE_IN_B);
                w++;
            }
        } else {
            for i32 ch = 0; ch < 2; ch++ {
                i32 src = e.scope_src[ch];
                f32 v = l;
                if src >= 0 && src < c.n_slots { v = slot_value(c, src); }
                e.tele.scope[ch][w & SCOPE_MASK] = v;
            }
            w++;
        }
    }

    engine_guard(e);
    // A slot's peak spans the window so far and the whole one before, so
    // a steady tone reads steady even when its period outlasts a block.
    e.peak_frames += frames;
    bool roll = cast(f32, e.peak_frames) >= PEAK_WINDOW_S * e.device_rate;
    for i32 s = 0; s < c.n_slots; s++ {
        atomic_store(&e.tele.peak_bits[s], f32_bits(fmaxf(e.peak_now[s], e.peak_last[s])), RELAXED);
        atomic_store(&e.tele.value_bits[s], f32_bits(slot_value(c, s)), RELAXED);
        atomic_store(&e.tele.channels[s], c.chrd[s], RELAXED);
        if roll {
            e.peak_last[s] = e.peak_now[s];
            e.peak_now[s] = 0.0f;
        }
    }
    if roll { e.peak_frames = 0; }
    atomic_store(&e.tele.out_peak_bits, f32_bits(out_peak), RELAXED);
    i32 note = KEYS_NO_NOTE;
    if e.n_keys > 0 && e.keys[0].n_held > 0 { note = e.keys[0].note; }
    atomic_store(&e.tele.note, note, RELAXED);
    i32 silent = 0;
    if e.hold != HOLD_NONE && e.fade == 0.0f { silent = 1; }
    atomic_store(&e.tele.silent, silent, RELEASE);
    for i32 i = 0; i < e.n_seq; i++ { atomic_store(&e.tele.state[e.seq[i].base.id], e.seq[i].step, RELAXED); }
    for i32 i = 0; i < e.n_stepsw; i++ { atomic_store(&e.tele.state[e.stepsw[i].base.id], e.stepsw[i].stage, RELAXED); }
    atomic_store(&e.tele.scope_decim, cast(u32, decim), RELAXED);
    atomic_store(&e.tele.scope_w, w, RELEASE);
    ignore atomic_add(&e.tele.blocks, 1);
}

// Copies the patch of an engine built from the same rack: knob targets,
// cables, profile, plugging feel, held keys and scope sources. Module
// states start fresh and the output fades in. Call it while `src` holds
// in silence (after CMD_LOAD_BEGIN) and before `dst` is published, so
// neither is being written.
void engine_copy_patch(Engine* dst, Engine* src) {
    Core* d = &dst.core;
    Core* s = &src.core;
    core_set_profile(d, s.profile);
    d.feel = s.feel;
    for i32 i = 0; i < s.n_params && i < d.n_params; i++ {
        Param* p = &d.params[i];
        p.target = s.params[i].target;
        p.norm = p.target;
        p.value = param_map(p, p.norm);
    }
    for i32 j = 0; j < s.n_jacks && j < d.n_jacks; j++ {
        d.jacks[j].src = s.jacks[j].src;
        d.jacks[j].n_src = s.jacks[j].n_src;
        d.jacks[j].normal = s.jacks[j].normal;
        d.jacks[j].normal_src = s.jacks[j].normal_src;
    }
    core_jacks_changed(d);
    engine_copy_keys(dst, src);
    dst.scope_src = src.scope_src;
    dst.fade = 0.0f;
    dst.fade_target = 1.0f;
}

// Held keys and the sounding pitch, so notes carry across an engine swap.
void engine_copy_keys(Engine* dst, Engine* src) {
    for i32 k = 0; k < src.n_keys && k < dst.n_keys; k++ {
        dst.keys[k].held = src.keys[k].held;
        dst.keys[k].n_held = src.keys[k].n_held;
        dst.keys[k].note = src.keys[k].note;
        dst.keys[k].pitch.y = src.keys[k].pitch.y;
        dst.keys[k].voices = src.keys[k].voices;
        dst.keys[k].voice = src.keys[k].voice;
        dst.keys[k].clock = src.keys[k].clock;
    }
}
