// engine_core.mc: the signal bus, jacks and parameters every module uses.
//
// Each module output owns one bus slot holding volts. There are two
// buses: during a tick every module reads the previous sample's values
// (rd) and writes this sample's (wr), then they swap. So every cable is
// exactly one sample of delay, module order does not matter, and
// feedback patches are always defined.
//
// Modules touch the bus only through jack_in and jack_out and read their
// knobs through param(). Keeping the bus layout behind those calls is
// what lets a cable carry voices.
//
// A cable carries 1 to MAX_VOICES channels, one per voice. Each output
// slot is a row of MAX_VOICES values on the bus, channel 0 first, with a
// channel count beside it; a mono slot uses only channel 0, so a mono
// patch computes exactly what it always has. A module that only knows mono reads channel 0 and writes
// one channel; a poly module reads each channel (a mono cable counts for
// every voice) and sets how many channels each of its outputs carries.

import math;
import dsp_math;
import profile;

const i32 MAX_SLOTS = 512;
const i32 MAX_JACKS = 512;
const i32 MAX_PARAMS = 1024;
const i32 MAX_VOICES = 8;

const f32 PARAM_SMOOTH_S = 0.03f;       // knob smoothing time constant: longer than a screen frame, so updates arriving once a frame blend into one move
const f32 FADE_S = 0.003f;              // SMOOTH plugging crossfade
const f32 BOUNCE_S = 0.006f;            // AUTHENTIC contact bounce
const i32 BOUNCE_SEGMENTS = 16;
const f32 TRIG_S = 0.002f;              // trigger pulse length

enum PlugFeel { FEEL_SMOOTH, FEEL_AUTHENTIC }
enum Taper { TAPER_LIN, TAPER_EXP }

// ---- descriptors ----

struct PortDesc {
    str name;
    i32 cls;
    f32 normal;                         // canonical value while unpatched
}

// `def` is in value units; `steps` > 1 makes a switch, and 1 a momentary
// button (1 while held, 0 otherwise).
struct ParamDesc {
    str name;
    f32 def;
    f32 lo;
    f32 hi;
    i32 taper;
    i32 steps;
}

struct ModuleDesc {
    str kind;
    PortDesc* inputs;
    i32 n_inputs;
    PortDesc* outputs;
    i32 n_outputs;
    ParamDesc* params;
    i32 n_params;
}

// Where a module's ports and params start in the core's tables.
struct ModBase {
    i32 id;
    i32 jack0;
    i32 slot0;
    i32 param0;
    i32 n_outputs;
    i32 voices;                         // the voices it ran last tick (mod_begin_voices)
}

// ---- jacks and params ----

struct Jack {
    i32[4] src;                         // bus slots patched in (TRIG_MAX_SOURCES)
    i32 n_src;
    i32[4] old_src;                     // sources before the last change, while it animates
    i32 old_n;
    i32 normal_src;                     // slot followed while unpatched, or -1
    f32 normal;                         // canonical value while unpatched
    i32 cls;
    f32 in_scale;                       // canonical units per volt
    i32 module;
    i32 fade_left;                      // SMOOTH: samples left in the crossfade
    i32 bounce_left;                    // AUTHENTIC: samples left in the bounce
    u32 bounce_bits;                    // contact pattern, one bit per segment
    bool animating;
}

struct Param {
    f32 target;                         // normalized 0..1, from the UI
    f32 norm;                           // smoothed normalized value
    f32 value;                          // mapped value the modules read
    f32 lo;
    f32 hi;
    f32 log_ratio;                      // log2(hi / lo) for TAPER_EXP
    i32 taper;
    i32 steps;
}

struct Core {
    f32 sample_rate;
    i32 profile;
    i32 feel;
    f32 age;                            // OUT's AGE knob, read once a tick (dsp_age)
    f32* rd;
    f32* wr;
    f32[4096] bus_a;                    // MAX_SLOTS * MAX_VOICES: slot s channel v at s * MAX_VOICES + v
    f32[4096] bus_b;
    i32* chrd;                          // channels each slot carries, read side
    i32* chwr;
    i32[MAX_SLOTS] ch_a;
    i32[MAX_SLOTS] ch_b;
    i32 poly_hold;                      // ticks since a module last set more than one channel, counting down
    i32 n_poly_in;                      // inputs receiving more than one channel
    i32[64] mod_poly_in;                // and per module (MAX_MODULES)
    bool[MAX_SLOTS] slot_used;          // a cable or a normal reads it (kept with the live inputs)
    i32[MAX_SLOTS] slot_cls;
    i32[MAX_SLOTS] slot_module;
    f32[MAX_SLOTS] out_scale;           // volts per canonical unit
    i32 n_slots;
    Jack[MAX_JACKS] jacks;
    i32 n_jacks;
    i32[MAX_JACKS] anim;                // jacks with a fade or bounce running
    i32 n_anim;
    f32[MAX_JACKS] jv;                  // each input's value for this tick (core_step_jacks)
    f32[4096] jvp;                      // a poly input's channels, input k channel v at k * MAX_VOICES + v; 0 past its count
    i32[MAX_JACKS] jch;                 // channels at each input this tick
    f32*[MAX_JACKS] jptr;               // where an input's channels are: its jv for mono, its jvp row for poly
    i32[MAX_JACKS] jmask;               // 0 for mono (every voice reads the one value), MAX_VOICES - 1 for poly
    i32[MAX_JACKS] live;                // inputs whose value can change from tick to tick
    i32 n_live;
    bool jacks_dirty;                   // sources changed: find the live inputs again
    Param[MAX_PARAMS] params;
    i32 n_params;
    i32[MAX_PARAMS] moving;             // params still on their way to their targets
    i32 n_moving;
    bool[MAX_PARAMS] is_moving;
    f32 param_coef;
    i32 fade_samples;
    i32 bounce_samples;
    i32 trig_samples;
    Rng rng;
}

void core_init(Core* c, f32 sample_rate) {
    c.sample_rate = sample_rate;
    c.profile = PROFILE_MODERN;
    c.feel = FEEL_SMOOTH;
    c.rd = &c.bus_a[0];
    c.wr = &c.bus_b[0];
    c.chrd = &c.ch_a[0];
    c.chwr = &c.ch_b[0];
    c.param_coef = onepole_coef(PARAM_SMOOTH_S, sample_rate);
    c.fade_samples = cast(i32, FADE_S * sample_rate);
    c.bounce_samples = cast(i32, BOUNCE_S * sample_rate);
    c.trig_samples = cast(i32, TRIG_S * sample_rate);
    rng_seed(&c.rng, 0xC0FFEE, 11);
}

// ---- registration, while the rack is built ----

i32 core_add_output(Core* c, i32 cls, i32 module) {
    i32 s = c.n_slots;
    c.n_slots++;
    c.slot_cls[s] = cls;
    c.slot_module[s] = module;
    c.out_scale[s] = profile_scale(c.profile, cls);
    c.ch_a[s] = 1;
    c.ch_b[s] = 1;
    return s;
}

i32 core_add_input(Core* c, i32 cls, f32 normal, i32 module) {
    i32 j = c.n_jacks;
    c.n_jacks++;
    Jack* k = &c.jacks[j];
    k.cls = cls;
    k.normal = normal;
    k.normal_src = -1;
    k.module = module;
    c.jch[j] = 1;
    c.jptr[j] = &c.jv[j];
    k.in_scale = 1.0f / profile_scale(c.profile, cls);
    c.jacks_dirty = true;
    return j;
}

f32 param_map(Param* p, f32 n) {
    if p.steps > 1 {
        f32 idx = floorf(n * cast(f32, p.steps - 1) + 0.5f);
        return p.lo + idx * (p.hi - p.lo) / cast(f32, p.steps - 1);
    }
    if p.taper == TAPER_EXP { return p.lo * exp2_fast(n * p.log_ratio); }
    return p.lo + n * (p.hi - p.lo);
}

// Normalized position of a value; the inverse of param_map.
f32 param_unmap(Param* p, f32 v) {
    f32 n = 0.0f;
    if p.taper == TAPER_EXP && p.steps <= 1 {
        n = log2(v / p.lo) / p.log_ratio;
    } else {
        n = (v - p.lo) / (p.hi - p.lo);
    }
    return clampf(n, 0.0f, 1.0f);
}

i32 core_add_param(Core* c, ParamDesc* d) {
    i32 i = c.n_params;
    c.n_params++;
    Param* p = &c.params[i];
    p.lo = d.lo;
    p.hi = d.hi;
    p.taper = d.taper;
    p.steps = d.steps;
    if d.taper == TAPER_EXP { p.log_ratio = log2(d.hi / d.lo); }
    f32 n = param_unmap(p, d.def);
    p.target = n;
    p.norm = n;
    p.value = param_map(p, n);
    return i;
}

// ---- what modules call ----

private f32 read_sources(Core* c, Jack* j, i32* src, i32 n) {
    if n == 0 {
        if j.normal_src >= 0 { return c.rd[j.normal_src * MAX_VOICES] * j.in_scale; }
        return j.normal;
    }
    f32 v = c.rd[src[0] * MAX_VOICES];
    for i32 i = 1; i < n; i++ {
        f32 w = c.rd[src[i] * MAX_VOICES];                   // several trigger sources: a wired OR
        if w > v { v = w; }
    }
    return v * j.in_scale;
}

// The less common cases: several sources, a normal, a cable changing.
private f32 jack_in_rest(Core* c, Jack* j) {
    f32 now = read_sources(c, j, &j.src[0], j.n_src);
    if !j.animating { return now; }
    if j.fade_left > 0 {
        f32 before = read_sources(c, j, &j.old_src[0], j.old_n);
        f32 t = cast(f32, j.fade_left) / cast(f32, c.fade_samples);
        return now + (before - now) * t;
    }
    if j.bounce_left > 0 {
        i32 seg = (c.bounce_samples - j.bounce_left) * BOUNCE_SEGMENTS / c.bounce_samples;
        if ((j.bounce_bits >> cast(u32, seg)) & 1) == 0 {
            return read_sources(c, j, &j.old_src[0], j.old_n);
        }
    }
    return now;
}

// ---- the bus, for the engine and tests ----

// Channel 0 of a slot, in volts, as the last tick left it.
f32 slot_value(Core* c, i32 s) { return c.rd[s * MAX_VOICES]; }

// Channel v of a slot, in volts (whatever the row holds, past its count too).
f32 slot_voice(Core* c, i32 s, i32 v) { return c.rd[s * MAX_VOICES + v]; }

i32 slot_channels(Core* c, i32 s) { return c.chrd[s]; }

// Every channel of a slot to 0 on both buses, and back to mono.
void slot_clear(Core* c, i32 s) {
    for i32 v = 0; v < MAX_VOICES; v++ {
        c.bus_a[s * MAX_VOICES + v] = 0.0f;
        c.bus_b[s * MAX_VOICES + v] = 0.0f;
    }
    c.ch_a[s] = 1;
    c.ch_b[s] = 1;
}

// After a Core is copied byte for byte: aim the copy's pointers at its own
// arrays, the same way round as the original's.
void core_rebind(Core* c, Core* orig) {
    bool a = orig.rd == &orig.bus_a[0];
    c.rd = a ? &c.bus_a[0] : &c.bus_b[0];
    c.wr = a ? &c.bus_b[0] : &c.bus_a[0];
    c.chrd = a ? &c.ch_a[0] : &c.ch_b[0];
    c.chwr = a ? &c.ch_b[0] : &c.ch_a[0];
    for i32 k = 0; k < c.n_jacks; k++ {
        c.jptr[k] = c.jch[k] == 1 ? &c.jv[k] : &c.jvp[k * MAX_VOICES];
    }
}

// ---- voices ----

// Channel v of slot s in volts: a mono slot gives every voice its one
// value; a poly slot gives 0 past its channels.
private f32 slot_ch(Core* c, i32 s, i32 v) {
    i32 n = c.chrd[s];
    if n == 1 { return c.rd[s * MAX_VOICES]; }
    if v < n { return c.rd[s * MAX_VOICES + v]; }
    return 0.0f;
}

private f32 read_sources_ch(Core* c, Jack* j, i32* src, i32 n, i32 v) {
    if n == 0 {
        if j.normal_src >= 0 { return slot_ch(c, j.normal_src, v) * j.in_scale; }
        return j.normal;
    }
    f32 x = slot_ch(c, src[0], v);
    for i32 i = 1; i < n; i++ {
        f32 w = slot_ch(c, src[i], v);
        if w > x { x = w; }
    }
    return x * j.in_scale;
}

// jack_in_rest for channel v.
private f32 jack_in_rest_ch(Core* c, Jack* j, i32 v) {
    f32 now = read_sources_ch(c, j, &j.src[0], j.n_src, v);
    if !j.animating { return now; }
    if j.fade_left > 0 {
        f32 before = read_sources_ch(c, j, &j.old_src[0], j.old_n, v);
        f32 t = cast(f32, j.fade_left) / cast(f32, c.fade_samples);
        return now + (before - now) * t;
    }
    if j.bounce_left > 0 {
        i32 seg = (c.bounce_samples - j.bounce_left) * BOUNCE_SEGMENTS / c.bounce_samples;
        if ((j.bounce_bits >> cast(u32, seg)) & 1) == 0 {
            return read_sources_ch(c, j, &j.old_src[0], j.old_n, v);
        }
    }
    return now;
}

// Channels an input receives: its source's, the most of several, or its
// normal's.
private i32 sources_channels(Core* c, Jack* j) {
    if j.n_src == 0 {
        if j.normal_src >= 0 { return c.chrd[j.normal_src]; }
        return 1;
    }
    i32 n = c.chrd[j.src[0]];
    for i32 i = 1; i < j.n_src; i++ { n = maxi(n, c.chrd[j.src[i]]); }
    return n;
}

// The value at an input now, in canonical units, from the bus as it is.
f32 jack_read(Core* c, i32 jack) {
    Jack* j = &c.jacks[jack];
    if !j.animating {
        if j.n_src == 1 { return c.rd[j.src[0] * MAX_VOICES] * j.in_scale; }
        if j.n_src == 0 && j.normal_src < 0 { return j.normal; }
    }
    return jack_in_rest(c, j);
}

// The value at an input during a tick, in canonical units. Every input
// reads the previous tick's bus, so core_step_jacks works them all out
// before the modules run, and this stays a load the compiler inlines.
f32 jack_in(Core* c, i32 jack) { return c.jv[jack]; }

// Channels at an input this tick, 1 for a mono cable or none.
i32 jack_channels(Core* c, i32 jack) { return c.jch[jack]; }

// Channel v at an input: a mono input gives every voice its value, a poly
// one 0 past its channels.
// Kept to a select and a load so it inlines: a poly input's channels
// (0 past its count) sit in jvp, a mono input's one value in jv.
f32 jack_in_ch(Core* c, i32 jack, i32 v) { return c.jptr[jack][v & c.jmask[jack]]; }

// Every channel at an input, summed: how a mono audio processor hears a
// poly cable.
f32 jack_in_sum(Core* c, i32 jack) {
    f32 x = c.jv[jack];
    i32 n = c.jch[jack];
    for i32 v = 1; v < n; v++ { x += c.jvp[jack * MAX_VOICES + v]; }
    return x;
}

bool jack_patched(Core* c, i32 jack) { return c.jacks[jack].n_src > 0; }

void jack_out(Core* c, i32 slot, f32 canonical) { c.wr[slot * MAX_VOICES] = canonical * c.out_scale[slot]; }

// Channel v of an output. A poly module sets the channel count too, every
// tick; a module that never does stays mono.
void jack_out_ch(Core* c, i32 slot, i32 v, f32 canonical) {
    c.wr[slot * MAX_VOICES + v] = canonical * c.out_scale[slot];
}

void jack_set_channels(Core* c, i32 slot, i32 n) {
    c.chwr[slot] = n;
    if n > 1 { c.poly_hold = 3; }
}

// Back to one channel on both buffers, for a module that goes mono and
// then stops setting its count.
void jack_reset_channels(Core* c, i32 slot) {
    c.ch_a[slot] = 1;
    c.ch_b[slot] = 1;
}

f32 param(Core* c, i32 p) { return c.params[p].value; }

// Module-relative forms.
f32 mod_in(Core* c, ModBase* b, i32 i) { return jack_in(c, b.jack0 + i); }
void mod_out(Core* c, ModBase* b, i32 i, f32 v) { jack_out(c, b.slot0 + i, v); }
f32 mod_param(Core* c, ModBase* b, i32 i) { return param(c, b.param0 + i); }
bool mod_patched(Core* c, ModBase* b, i32 i) { return jack_patched(c, b.jack0 + i); }
i32 mod_channels(Core* c, ModBase* b, i32 i) { return jack_channels(c, b.jack0 + i); }
f32 mod_in_ch(Core* c, ModBase* b, i32 i, i32 v) { return jack_in_ch(c, b.jack0 + i, v); }
f32 mod_in_sum(Core* c, ModBase* b, i32 i) { return jack_in_sum(c, b.jack0 + i); }
void mod_out_ch(Core* c, ModBase* b, i32 i, i32 v, f32 x) { jack_out_ch(c, b.slot0 + i, v, x); }
void mod_set_channels(Core* c, ModBase* b, i32 i, i32 n) { jack_set_channels(c, b.slot0 + i, n); }
void mod_reset_channels(Core* c, ModBase* b, i32 i) { jack_reset_channels(c, b.slot0 + i); }

// The voices a poly module runs this tick: the most channels at inputs
// i0 .. i0 + n - 1. Above 1 every output is marked with that many
// channels; on the way back to 1 they are marked mono once, so the mono
// path after it needs no upkeep at all.
// Whether a module has voices to run or to wind down: one load and a
// compare, so a mono tick pays nothing more. Only then mod_begin_voices.
bool mod_poly(Core* c, ModBase* b) { return c.mod_poly_in[b.id] > 0 || b.voices > 1; }

i32 mod_begin_voices(Core* c, ModBase* b, i32 i0, i32 n) {
    i32 v = 1;
    for i32 i = 0; i < n; i++ { v = maxi(v, c.jch[b.jack0 + i0 + i]); }
    if v > 1 {
        for i32 o = 0; o < b.n_outputs; o++ { jack_set_channels(c, b.slot0 + o, v); }
    } else if b.voices > 1 {
        for i32 o = 0; o < b.n_outputs; o++ { jack_reset_channels(c, b.slot0 + o); }
    }
    b.voices = v;
    return v;
}

// The most channels at inputs i0 .. i0 + n - 1: the voices a module runs.
i32 mod_voices(Core* c, ModBase* b, i32 i0, i32 n) {
    i32 v = 1;
    for i32 i = 0; i < n; i++ { v = maxi(v, c.jch[b.jack0 + i0 + i]); }
    return v;
}

// ---- gates and triggers ----

struct Schmitt {
    bool high;
}

bool schmitt(Schmitt* s, f32 canonical) {
    // High from GATE_HIGH up; once high, until GATE_LOW or below.
    s.high = canonical >= GATE_HIGH || (s.high && canonical > GATE_LOW);
    return s.high;
}

// A trigger output: 1 for TRIG_S after fire, then 0.
struct TrigOut {
    i32 left;
}

void trig_fire(Core* c, TrigOut* t) { t.left = c.trig_samples; }

f32 trig_tick(TrigOut* t) {
    if t.left > 0 {
        t.left--;
        return 1.0f;
    }
    return 0.0f;
}

// ---- per-sample upkeep, called by the engine ----

void core_step_params(Core* c) {
    i32 i = 0;
    while i < c.n_moving {
        i32 k = c.moving[i];
        Param* p = &c.params[k];
        if p.norm == p.target {
            c.is_moving[k] = false;
            c.n_moving--;
            c.moving[i] = c.moving[c.n_moving];
            continue;
        }
        // Near the target the step drops below half an ulp and the value
        // stalls short of it, so snap once the step stops moving it.
        f32 next = p.norm + c.param_coef * (p.target - p.norm);
        if next == p.norm || fabsf(p.target - next) < 1e-4f { next = p.target; }
        p.norm = next;
        p.value = param_map(p, p.norm);
        i++;
    }
}

// Something about the inputs' sources changed; the next tick finds the
// live inputs again.
void core_jacks_changed(Core* c) { c.jacks_dirty = true; }

// An input's value while nothing is patched into it.
void core_set_normal(Core* c, i32 jack, f32 value) {
    c.jacks[jack].normal = value;
    c.jacks_dirty = true;
}

// An input's channel count changed: where jack_in_ch reads.
void input_channels(Core* c, i32 k, i32 n) {
    if (c.jch[k] > 1) != (n > 1) {
        i32 d = n > 1 ? 1 : -1;
        c.n_poly_in += d;
        c.mod_poly_in[c.jacks[k].module] += d;
    }
    c.jch[k] = n;
    if n == 1 {
        c.jptr[k] = &c.jv[k];
        c.jmask[k] = 0;
    } else {
        c.jptr[k] = &c.jvp[k * MAX_VOICES];
        c.jmask[k] = MAX_VOICES - 1;
    }
}

// A poly input's channels for this tick, and 0 past them, so a module
// running more voices than the cable carries reads silence there.
private void poly_input(Core* c, Jack* j, i32 k, i32 n) {
    f32* p = &c.jvp[k * MAX_VOICES];
    if !j.animating && j.n_src <= 1 {
        // The usual case, one steady cable or a normal: a scaled copy of
        // the source's row, which has exactly n channels.
        i32 s = j.n_src == 1 ? j.src[0] : j.normal_src;
        f32* x = &c.rd[s * MAX_VOICES];
        for i32 v = 0; v < n; v++ { p[v] = x[v] * j.in_scale; }
    } else {
        p[0] = c.jv[k];
        for i32 v = 1; v < n; v++ { p[v] = jack_in_rest_ch(c, j, v); }
    }
    for i32 v = n; v < MAX_VOICES; v++ { p[v] = 0.0f; }
}

void core_step_jacks(Core* c) {
    i32 i = 0;
    while i < c.n_anim {
        Jack* j = &c.jacks[c.anim[i]];
        if j.fade_left > 0 { j.fade_left--; }
        if j.bounce_left > 0 { j.bounce_left--; }
        if j.fade_left == 0 && j.bounce_left == 0 {
            j.animating = false;
            c.n_anim--;
            c.anim[i] = c.anim[c.n_anim];
        } else {
            i++;
        }
    }
    if c.jacks_dirty {
        // A cable, a normal to follow or a change under way makes an input
        // live; the rest hold their normal until the sources change again.
        c.jacks_dirty = false;
        c.n_live = 0;
        for i32 s = 0; s < c.n_slots; s++ { c.slot_used[s] = false; }
        for i32 k = 0; k < c.n_jacks; k++ {
            Jack* j = &c.jacks[k];
            if j.animating || j.n_src > 0 || j.normal_src >= 0 {
                c.live[c.n_live] = k;
                c.n_live++;
                for i32 i = 0; i < j.n_src; i++ { c.slot_used[j.src[i]] = true; }
                if j.normal_src >= 0 { c.slot_used[j.normal_src] = true; }
            } else {
                c.jv[k] = j.normal;
                input_channels(c, k, 1);
            }
        }
    }
    bool chans = c.poly_hold > 0 || c.n_poly_in > 0;
    for i32 n = 0; n < c.n_live; n++ {
        i32 k = c.live[n];
        Jack* j = &c.jacks[k];
        if !j.animating && j.n_src == 1 {
            c.jv[k] = c.rd[j.src[0] * MAX_VOICES] * j.in_scale;
        } else if !j.animating && j.n_src == 0 {
            // A normal: another output (an ENV gate following KEYS), or a value.
            if j.normal_src >= 0 { c.jv[k] = c.rd[j.normal_src * MAX_VOICES] * j.in_scale; } else { c.jv[k] = j.normal; }
        } else {
            c.jv[k] = jack_in_rest(c, j);
        }
        // Voices, only while something in the patch carries them.
        if chans {
            i32 n = j.n_src == 1 ? c.chrd[j.src[0]] : sources_channels(c, j);
            if n != c.jch[k] { input_channels(c, k, n); }
            if n > 1 { poly_input(c, j, k, n); }
        }
    }
}

void core_swap(Core* c) {
    f32* t = c.rd;
    c.rd = c.wr;
    c.wr = t;
    if c.poly_hold > 0 { c.poly_hold--; }
    i32* ct = c.chrd;
    c.chrd = c.chwr;
    c.chwr = ct;
}

// ---- edits, applied from commands on the audio side ----

void core_set_param(Core* c, i32 p, f32 norm) {
    if p < 0 || p >= c.n_params { return; }
    Param* q = &c.params[p];
    q.target = clampf(norm, 0.0f, 1.0f);
    if q.steps >= 1 {
        q.norm = q.target;
        q.value = param_map(q, q.norm);
    } else if q.norm != q.target && !c.is_moving[p] {
        c.is_moving[p] = true;
        c.moving[c.n_moving] = p;
        c.n_moving++;
    }
}

private void begin_change(Core* c, i32 jack) {
    Jack* j = &c.jacks[jack];
    j.old_src = j.src;
    j.old_n = j.n_src;
    if c.feel == FEEL_SMOOTH {
        j.fade_left = c.fade_samples;
        j.bounce_left = 0;
    } else {
        // Contact bounce: touches get likelier segment by segment and the
        // last segment is always connected.
        u32 bits = 0;
        for i32 s = 0; s < BOUNCE_SEGMENTS; s++ {
            f32 p = cast(f32, s + 1) / cast(f32, BOUNCE_SEGMENTS);
            if (rng_uniform(&c.rng) + 1.0f) * 0.5f < p { bits |= cast(u32, 1) << cast(u32, s); }
        }
        bits |= cast(u32, 1) << cast(u32, BOUNCE_SEGMENTS - 1);
        j.bounce_bits = bits;
        j.bounce_left = c.bounce_samples;
        j.fade_left = 0;
    }
    if !j.animating {
        j.animating = true;
        c.anim[c.n_anim] = jack;
        c.n_anim++;
    }
    c.jacks_dirty = true;
}

// Patch output slot into input jack. A full single-source input swaps
// its cable. Returns false when the profile forbids the connection.
bool core_connect(Core* c, i32 slot, i32 jack) {
    if slot < 0 || slot >= c.n_slots || jack < 0 || jack >= c.n_jacks { return false; }
    Jack* j = &c.jacks[jack];
    if !profile_can_connect(c.profile, c.slot_cls[slot], j.cls) { return false; }
    for i32 i = 0; i < j.n_src; i++ {
        if j.src[i] == slot { return true; }
    }
    i32 max = profile_max_sources(c.profile, j.cls);
    if j.n_src >= max && max > 1 { return false; }
    begin_change(c, jack);
    if j.n_src < max {
        j.src[j.n_src] = slot;
        j.n_src++;
    } else {
        j.src[0] = slot;
    }
    return true;
}

bool core_disconnect(Core* c, i32 slot, i32 jack) {
    if jack < 0 || jack >= c.n_jacks { return false; }
    Jack* j = &c.jacks[jack];
    for i32 i = 0; i < j.n_src; i++ {
        if j.src[i] == slot {
            begin_change(c, jack);
            j.n_src--;
            j.src[i] = j.src[j.n_src];
            return true;
        }
    }
    return false;
}

// New profile: rescale every jack and drop connections it forbids. The UI
// removes those itself as one undoable edit; this keeps the engine safe
// either way.
void core_set_profile(Core* c, i32 profile) {
    if profile < 0 || profile >= PROFILE_COUNT { return; }
    c.profile = profile;
    c.jacks_dirty = true;
    for i32 s = 0; s < c.n_slots; s++ { c.out_scale[s] = profile_scale(profile, c.slot_cls[s]); }
    for i32 k = 0; k < c.n_jacks; k++ {
        Jack* j = &c.jacks[k];
        j.in_scale = 1.0f / profile_scale(profile, j.cls);
        i32 kept = 0;
        i32 max = profile_max_sources(profile, j.cls);
        for i32 i = 0; i < j.n_src; i++ {
            if kept < max && profile_can_connect(profile, c.slot_cls[j.src[i]], j.cls) {
                j.src[kept] = j.src[i];
                kept++;
            }
        }
        j.n_src = kept;
    }
}
