// patch.mc: the UI's model of the patch, with undo and redo.
//
// On the UI side the patch is the source of truth: cables and their
// colours, knob positions, the profile and the plugging feel. Every edit
// takes one path: it changes the model, records how to undo it, and sends
// the engine the commands that mirror it. One gesture is one undo step,
// however many cables it touches. The engine never sees cable colours,
// only jack sources.

import engine_core;
import engine_cmd;
import engine;
import profile;
import rack;

const i32 PATCH_MAX_CABLES = 256;
const i32 PATCH_UNDO = 128;             // gestures kept for undo
const i32 PATCH_MAX_PRIMS = 2048;       // primitive edits in one gesture: a whole patch replaced
const i32 PATCH_COLORS = 9;             // cable colour palette size (CABLE_COLORS)

struct Cable {
    i32 src;                            // output slot
    i32 dst;                            // input jack
    i32 color;                          // palette index
}

enum PrimKind {
    PRIM_ADD,                           // add cable src -> dst
    PRIM_REMOVE,                        // remove cable src -> dst
    PRIM_REPLACE,                       // dst's one cable changes source: from_src -> src
    PRIM_PARAM,                         // param: old_value -> new_value (normalized)
    PRIM_PROFILE,                       // profile: from_src -> src
}

struct Prim {
    i32 kind;
    i32 src;
    i32 dst;
    i32 color;
    i32 from_src;
    i32 from_color;
    i32 param;
    f32 old_value;
    f32 new_value;
}

struct Action {
    Prim* prims;
    i32 n;
    bool silent;                        // applied, undone and redone with the engine held at silence
}

struct Patch {
    Cable[256] cables;                  // PATCH_MAX_CABLES
    i32 n_cables;
    f32[1024] params;                   // normalized, MAX_PARAMS
    f32[1024] defaults;
    i32 n_params;
    i32 profile;
    i32 feel;
    Action[128] undo;                   // PATCH_UNDO
    i32 n_undo;
    Action[128] redo;
    i32 n_redo;
    Prim[2048] pending;                 // the gesture being built (PATCH_MAX_PRIMS)
    i32 n_pending;
    i32 next_color;
}

// A whole patch as plain data: what a file holds, without history or
// engine state. Params are normalized, every one present.
struct PatchData {
    i32 profile;
    Cable[256] cables;                  // PATCH_MAX_CABLES
    i32 n_cables;
    f32[1024] params;                   // MAX_PARAMS
    i32 n_params;
}

// A patch mirroring a freshly built engine: no cables, default knobs.
void patch_init(Patch* p, Engine* e) {
    *p = Patch{};
    p.n_params = e.core.n_params;
    for i32 i = 0; i < p.n_params; i++ {
        p.params[i] = e.core.params[i].target;
        p.defaults[i] = p.params[i];
    }
    p.profile = e.core.profile;
    p.feel = e.core.feel;
}

void patch_free(Patch* p) {
    for i32 i = 0; i < p.n_undo; i++ { free(p.undo[i].prims); }
    for i32 i = 0; i < p.n_redo; i++ { free(p.redo[i].prims); }
    p.n_undo = 0;
    p.n_redo = 0;
}

// Forgets the history: the patch as it stands becomes the starting state.
void patch_clear_history(Patch* p) { patch_free(p); }

// ---- queries ----

i32 patch_find(Patch* p, i32 src, i32 dst) {
    for i32 i = 0; i < p.n_cables; i++ {
        if p.cables[i].src == src && p.cables[i].dst == dst { return i; }
    }
    return -1;
}

i32 patch_count_into(Patch* p, i32 dst) {
    i32 n = 0;
    for i32 i = 0; i < p.n_cables; i++ { if p.cables[i].dst == dst { n++; } }
    return n;
}

// The most recent cable into dst, or -1.
i32 patch_last_into(Patch* p, i32 dst) {
    for i32 i = p.n_cables - 1; i >= 0; i-- { if p.cables[i].dst == dst { return i; } }
    return -1;
}

// The most recent cable out of src, or -1.
i32 patch_last_from(Patch* p, i32 src) {
    for i32 i = p.n_cables - 1; i >= 0; i-- { if p.cables[i].src == src { return i; } }
    return -1;
}

bool patch_can_connect(Patch* p, Engine* e, i32 src, i32 dst) {
    if src < 0 || src >= e.core.n_slots || dst < 0 || dst >= e.core.n_jacks { return false; }
    return profile_can_connect(p.profile, e.core.slot_cls[src], e.core.jacks[dst].cls);
}

// ---- primitives: model change plus the engine commands ----

private void cable_add(Patch* p, i32 src, i32 dst, i32 color) {
    if p.n_cables == PATCH_MAX_CABLES { return; }
    p.cables[p.n_cables] = Cable{ src, dst, color };
    p.n_cables++;
}

private void cable_remove(Patch* p, i32 src, i32 dst) {
    i32 i = patch_find(p, src, dst);
    if i < 0 { return; }
    for i32 k = i + 1; k < p.n_cables; k++ { p.cables[k - 1] = p.cables[k]; }
    p.n_cables--;
}

private void prim_do(Patch* p, Engine* e, Prim* x) {
    switch x.kind {
        case PRIM_ADD: {
            cable_add(p, x.src, x.dst, x.color);
            ignore engine_send_kind(e, CMD_CONNECT, x.src, x.dst, 0.0f);
        }
        case PRIM_REMOVE: {
            cable_remove(p, x.src, x.dst);
            ignore engine_send_kind(e, CMD_DISCONNECT, x.src, x.dst, 0.0f);
        }
        case PRIM_REPLACE: {
            // One engine command, so the engine crossfades old to new.
            i32 i = patch_find(p, x.from_src, x.dst);
            if i >= 0 {
                p.cables[i].src = x.src;
                p.cables[i].color = x.color;
            }
            ignore engine_send_kind(e, CMD_CONNECT, x.src, x.dst, 0.0f);
        }
        case PRIM_PARAM: {
            p.params[x.param] = x.new_value;
            ignore engine_send_kind(e, CMD_PARAM, x.param, 0, x.new_value);
        }
        default: {
            p.profile = x.src;
            ignore engine_send_kind(e, CMD_PROFILE, x.src, 0, 0.0f);
        }
    }
}

private Prim prim_inverse(Prim x) {
    Prim r = x;
    if x.kind == PRIM_ADD { r.kind = PRIM_REMOVE; }
    else if x.kind == PRIM_REMOVE { r.kind = PRIM_ADD; }
    else if x.kind == PRIM_REPLACE || x.kind == PRIM_PROFILE {
        r.src = x.from_src;
        r.from_src = x.src;
        r.color = x.from_color;
        r.from_color = x.color;
    } else {
        r.old_value = x.new_value;
        r.new_value = x.old_value;
    }
    return r;
}

// ---- gestures ----

private void begin(Patch* p) { p.n_pending = 0; }

// Applies a primitive now and adds it to the gesture.
private void step(Patch* p, Engine* e, Prim x) {
    if p.n_pending == PATCH_MAX_PRIMS { return; }
    prim_do(p, e, &x);
    p.pending[p.n_pending] = x;
    p.n_pending++;
}

private void drop_redo(Patch* p) {
    for i32 i = 0; i < p.n_redo; i++ { free(p.redo[i].prims); }
    p.n_redo = 0;
}

private void push_undo(Patch* p, Action a) {
    if p.n_undo == PATCH_UNDO {
        free(p.undo[0].prims);
        for i32 i = 1; i < PATCH_UNDO; i++ { p.undo[i - 1] = p.undo[i]; }
        p.n_undo--;
    }
    p.undo[p.n_undo] = a;
    p.n_undo++;
}

// Ends the gesture: one undo step, and redo history is gone.
private bool commit_as(Patch* p, bool silent) {
    if p.n_pending == 0 { return false; }
    Prim* prims = alloc<Prim>(p.n_pending);
    for i32 i = 0; i < p.n_pending; i++ { prims[i] = p.pending[i]; }
    drop_redo(p);
    push_undo(p, Action{ prims, p.n_pending, silent });
    p.n_pending = 0;
    return true;
}

private bool commit(Patch* p) { return commit_as(p, false); }

// The engine applies everything between these at silence, so a whole
// patch changes without a click.
private void hold_begin(Engine* e) { ignore engine_send_kind(e, CMD_LOAD_BEGIN, 0, 0, 0.0f); }
private void hold_end(Engine* e) { ignore engine_send_kind(e, CMD_LOAD_END, 0, 0, 0.0f); }

private i32 take_color(Patch* p) {
    i32 c = p.next_color;
    p.next_color = (p.next_color + 1) % PATCH_COLORS;
    return c;
}

// Plugs src into dst within the current gesture: adds a cable, replaces
// the one a single-cable input holds, or stacks onto a VINTAGE trigger
// input. False when the profile or a full input forbids it.
private bool connect_step(Patch* p, Engine* e, i32 src, i32 dst, i32 color) {
    if !patch_can_connect(p, e, src, dst) { return false; }
    if patch_find(p, src, dst) >= 0 { return false; }
    i32 max = profile_max_sources(p.profile, e.core.jacks[dst].cls);
    i32 have = patch_count_into(p, dst);
    if have < max {
        step(p, e, Prim{ .kind = PRIM_ADD, .src = src, .dst = dst, .color = color });
        return true;
    }
    if max > 1 { return false; }
    Cable old = p.cables[patch_last_into(p, dst)];
    step(p, e, Prim{ .kind = PRIM_REPLACE, .src = src, .dst = dst, .color = color,
                     .from_src = old.src, .from_color = old.color });
    return true;
}

bool patch_connect(Patch* p, Engine* e, i32 src, i32 dst) {
    begin(p);
    ignore connect_step(p, e, src, dst, take_color(p));
    return commit(p);
}

bool patch_remove(Patch* p, Engine* e, i32 cable) {
    if cable < 0 || cable >= p.n_cables { return false; }
    Cable c = p.cables[cable];
    begin(p);
    step(p, e, Prim{ .kind = PRIM_REMOVE, .src = c.src, .dst = c.dst, .color = c.color });
    return commit(p);
}

// Moves a cable's input plug to another input, keeping its colour.
bool patch_move_dst(Patch* p, Engine* e, i32 cable, i32 dst) {
    if cable < 0 || cable >= p.n_cables { return false; }
    Cable c = p.cables[cable];
    if c.dst == dst || !patch_can_connect(p, e, c.src, dst) { return false; }
    begin(p);
    step(p, e, Prim{ .kind = PRIM_REMOVE, .src = c.src, .dst = c.dst, .color = c.color });
    if !connect_step(p, e, c.src, dst, c.color) {
        // The new input refused it: put the cable back.
        prim_undo_pending(p, e);
        return false;
    }
    return commit(p);
}

// Moves a cable's output plug to another output, keeping its colour.
bool patch_move_src(Patch* p, Engine* e, i32 cable, i32 src) {
    if cable < 0 || cable >= p.n_cables { return false; }
    Cable c = p.cables[cable];
    if c.src == src || !patch_can_connect(p, e, src, c.dst) || patch_find(p, src, c.dst) >= 0 { return false; }
    begin(p);
    if profile_max_sources(p.profile, e.core.jacks[c.dst].cls) == 1 {
        step(p, e, Prim{ .kind = PRIM_REPLACE, .src = src, .dst = c.dst, .color = c.color,
                         .from_src = c.src, .from_color = c.color });
    } else {
        step(p, e, Prim{ .kind = PRIM_REMOVE, .src = c.src, .dst = c.dst, .color = c.color });
        step(p, e, Prim{ .kind = PRIM_ADD, .src = src, .dst = c.dst, .color = c.color });
    }
    return commit(p);
}

// Rolls back the gesture being built, for a step that turned out invalid.
private void prim_undo_pending(Patch* p, Engine* e) {
    for i32 i = p.n_pending - 1; i >= 0; i-- {
        Prim inv = prim_inverse(p.pending[i]);
        prim_do(p, e, &inv);
    }
    p.n_pending = 0;
}

// A knob while it's being dragged: the engine follows, undo waits for
// the release.
void patch_param_live(Patch* p, Engine* e, i32 param, f32 norm) {
    if param < 0 || param >= p.n_params { return; }
    f32 n = clampf(norm, 0.0f, 1.0f);
    p.params[param] = n;
    ignore engine_send_kind(e, CMD_PARAM, param, 0, n);
}

// The release: one undo step from where the drag started.
void patch_param_commit(Patch* p, i32 param, f32 start) {
    if param < 0 || param >= p.n_params || p.params[param] == start { return; }
    begin(p);
    p.pending[0] = Prim{ .kind = PRIM_PARAM, .param = param, .old_value = start, .new_value = p.params[param] };
    p.n_pending = 1;
    ignore commit(p);
}

// A knob set in one go, e.g. a switch click or a reset.
bool patch_set_param(Patch* p, Engine* e, i32 param, f32 norm) {
    if param < 0 || param >= p.n_params { return false; }
    f32 n = clampf(norm, 0.0f, 1.0f);
    if p.params[param] == n { return false; }
    begin(p);
    step(p, e, Prim{ .kind = PRIM_PARAM, .param = param, .old_value = p.params[param], .new_value = n });
    return commit(p);
}

// New profile, as one undoable step that first removes the cables it
// forbids (and extra trigger cables a single-cable input can't keep).
bool patch_set_profile(Patch* p, Engine* e, i32 profile) {
    if profile == p.profile || profile < 0 || profile >= PROFILE_COUNT { return false; }
    begin(p);
    i32 i = 0;
    while i < p.n_cables {
        Cable c = p.cables[i];
        bool ok = profile_can_connect(profile, e.core.slot_cls[c.src], e.core.jacks[c.dst].cls);
        if ok {
            // Keep only the first cables into an input, up to its new limit.
            i32 max = profile_max_sources(profile, e.core.jacks[c.dst].cls);
            i32 before = 0;
            for i32 k = 0; k < i; k++ { if p.cables[k].dst == c.dst { before++; } }
            if before >= max { ok = false; }
        }
        if ok {
            i++;
        } else {
            step(p, e, Prim{ .kind = PRIM_REMOVE, .src = c.src, .dst = c.dst, .color = c.color });
        }
    }
    step(p, e, Prim{ .kind = PRIM_PROFILE, .src = profile, .from_src = p.profile });
    return commit(p);
}

// How plugging feels is a working preference, not part of the patch
// history.
void patch_set_feel(Patch* p, Engine* e, i32 feel) {
    p.feel = feel;
    ignore engine_send_kind(e, CMD_FEEL, feel, 0, 0.0f);
}

void patch_cycle_color(Patch* p, i32 cable) {
    if cable < 0 || cable >= p.n_cables { return; }
    p.cables[cable].color = (p.cables[cable].color + 1) % PATCH_COLORS;
}

bool patch_undo(Patch* p, Engine* e) {
    if p.n_undo == 0 { return false; }
    p.n_undo--;
    Action a = p.undo[p.n_undo];
    if a.silent { hold_begin(e); }
    for i32 i = a.n - 1; i >= 0; i-- {
        Prim inv = prim_inverse(a.prims[i]);
        prim_do(p, e, &inv);
    }
    if a.silent { hold_end(e); }
    p.redo[p.n_redo] = a;
    p.n_redo++;
    return true;
}

bool patch_redo(Patch* p, Engine* e) {
    if p.n_redo == 0 { return false; }
    p.n_redo--;
    Action a = p.redo[p.n_redo];
    if a.silent { hold_begin(e); }
    for i32 i = 0; i < a.n; i++ { prim_do(p, e, &a.prims[i]); }
    if a.silent { hold_end(e); }
    push_undo(p, a);
    return true;
}

// ---- loading ----

// The rack's default patch, as the starting state (not an undo step).
void patch_load_default(Patch* p, Engine* e) {
    begin(p);
    for i32 i = 0; i < DEFAULT_CABLES_N; i++ {
        i32 s = engine_output_ref(e, DEFAULT_CABLES[i].src);
        i32 d = engine_input_ref(e, DEFAULT_CABLES[i].dst);
        if s >= 0 && d >= 0 { ignore connect_step(p, e, s, d, take_color(p)); }
    }
    for i32 i = 0; i < DEFAULT_SETTINGS_N; i++ {
        i32 k = engine_param_ref(e, DEFAULT_SETTINGS[i].param);
        if k < 0 { continue; }
        f32 n = param_unmap(&e.core.params[k], DEFAULT_SETTINGS[i].value);
        step(p, e, Prim{ .kind = PRIM_PARAM, .param = k, .old_value = p.params[k], .new_value = n });
    }
    p.n_pending = 0;
}

// Puts the whole patch into an engine that isn't running yet (a new one
// for a quality switch): direct, no commands, no fades.
void patch_apply_to_engine(Patch* p, Engine* e) {
    Core* c = &e.core;
    core_set_profile(c, p.profile);
    c.feel = p.feel;
    for i32 i = 0; i < p.n_params && i < c.n_params; i++ {
        core_set_param(c, i, p.params[i]);
        c.params[i].norm = c.params[i].target;
        c.params[i].value = param_map(&c.params[i], c.params[i].norm);
    }
    for i32 i = 0; i < p.n_cables; i++ { ignore core_connect(c, p.cables[i].src, p.cables[i].dst); }
    for i32 j = 0; j < c.n_jacks; j++ {
        c.jacks[j].fade_left = 0;
        c.jacks[j].bounce_left = 0;
        c.jacks[j].animating = false;
    }
    c.n_anim = 0;
}

// ---- whole patches as data ----

// The patch as it stands.
void patch_data_from(Patch* p, PatchData* d) {
    *d = PatchData{};
    d.profile = p.profile;
    d.n_cables = p.n_cables;
    for i32 i = 0; i < p.n_cables; i++ { d.cables[i] = p.cables[i]; }
    d.n_params = p.n_params;
    for i32 i = 0; i < p.n_params; i++ { d.params[i] = p.params[i]; }
}

// An empty patch: no cables, every knob at its default, the same profile.
void patch_data_empty(Patch* p, PatchData* d) {
    *d = PatchData{};
    d.profile = p.profile;
    d.n_params = p.n_params;
    for i32 i = 0; i < p.n_params; i++ { d.params[i] = p.defaults[i]; }
}

// Replaces the whole patch with d as one undo step, applied at silence:
// the old cables go, then the profile, the knobs and the new cables. A
// cable the profile or a full input refuses is left out; the count of
// those comes back.
i32 patch_replace(Patch* p, Engine* e, PatchData* d) {
    i32 refused = 0;
    hold_begin(e);
    begin(p);
    for i32 i = p.n_cables - 1; i >= 0; i-- {
        Cable c = p.cables[i];
        step(p, e, Prim{ .kind = PRIM_REMOVE, .src = c.src, .dst = c.dst, .color = c.color });
    }
    if d.profile != p.profile && d.profile >= 0 && d.profile < PROFILE_COUNT {
        step(p, e, Prim{ .kind = PRIM_PROFILE, .src = d.profile, .from_src = p.profile });
    }
    for i32 i = 0; i < p.n_params && i < d.n_params; i++ {
        f32 n = clampf(d.params[i], 0.0f, 1.0f);
        if n != p.params[i] {
            step(p, e, Prim{ .kind = PRIM_PARAM, .param = i, .old_value = p.params[i], .new_value = n });
        }
    }
    for i32 i = 0; i < d.n_cables; i++ {
        Cable c = d.cables[i];
        bool ok = patch_can_connect(p, e, c.src, c.dst) && patch_find(p, c.src, c.dst) < 0
               && patch_count_into(p, c.dst) < profile_max_sources(p.profile, e.core.jacks[c.dst].cls);
        if ok { ok = connect_step(p, e, c.src, c.dst, ((c.color % PATCH_COLORS) + PATCH_COLORS) % PATCH_COLORS); }
        if !ok { refused++; }
    }
    if p.n_cables > 0 { p.next_color = (p.cables[p.n_cables - 1].color + 1) % PATCH_COLORS; }
    ignore commit_as(p, true);
    hold_end(e);
    return refused;
}

// Sets the model to d directly: no commands, no history. For a patch
// that goes into an engine through patch_apply_to_engine.
void patch_set_data(Patch* p, PatchData* d) {
    p.n_cables = 0;
    for i32 i = 0; i < d.n_cables && i < PATCH_MAX_CABLES; i++ { cable_add(p, d.cables[i].src, d.cables[i].dst, d.cables[i].color); }
    for i32 i = 0; i < p.n_params && i < d.n_params; i++ { p.params[i] = clampf(d.params[i], 0.0f, 1.0f); }
    if d.profile >= 0 && d.profile < PROFILE_COUNT { p.profile = d.profile; }
}
