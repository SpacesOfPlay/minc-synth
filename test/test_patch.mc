// test_patch.mc: the UI's patch model, its undo and redo, and that the
// engine always ends up mirroring it.

import math;
import "util/check.mc";
import "util/rig.mc";

// After the engine drains its commands, every input's sources and every
// knob target must match the patch.
bool mirrors(Patch* p, Engine* e) {
    ignore rig_run(e, 1);
    Core* c = &e.core;
    for i32 j = 0; j < c.n_jacks; j++ {
        Jack* k = &c.jacks[j];
        if k.n_src != patch_count_into(p, j) { return false; }
        for i32 s = 0; s < k.n_src; s++ {
            if patch_find(p, k.src[s], j) < 0 { return false; }
        }
    }
    for i32 i = 0; i < p.n_params; i++ {
        if fabsf(c.params[i].target - p.params[i]) > 1e-6f { return false; }
    }
    return c.profile == p.profile;
}

i32 out_of(Engine* e, str ref) { return engine_output_ref(e, ref); }
i32 in_of(Engine* e, str ref) { return engine_input_ref(e, ref); }

void test_default() {
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    patch_load_default(p, e);
    check(p.n_cables == DEFAULT_CABLES_N, "the default patch has its cables");
    check(p.n_undo == 0, "loading the default is not an undo step");
    check(mirrors(p, e), "the engine mirrors the default patch");
    patch_free(p);
}

void test_edits() {
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    patch_load_default(p, e);
    i32 saw = out_of(e, "osc.saw");
    i32 pulse = out_of(e, "osc.pulse");
    i32 tri = out_of(e, "osc.tri");
    i32 in1 = in_of(e, "lowpass.in1");
    i32 in2 = in_of(e, "lowpass.in2");

    check(patch_connect(p, e, pulse, in2), "connect a free input");
    check(mirrors(p, e) && patch_count_into(p, in2) == 1, "the engine has the new cable");

    // A single-cable input: the new cable replaces the old one.
    check(patch_connect(p, e, tri, in1), "connect into an occupied input");
    check(patch_count_into(p, in1) == 1 && patch_find(p, tri, in1) >= 0, "the old cable was replaced");
    check(mirrors(p, e), "the engine followed the replace");
    check(patch_undo(p, e) && patch_find(p, saw, in1) >= 0 && patch_find(p, tri, in1) < 0, "undo restores the old cable");
    check(mirrors(p, e), "the engine followed the undo");
    check(patch_redo(p, e) && patch_find(p, tri, in1) >= 0, "redo replaces it again");
    check(mirrors(p, e), "the engine followed the redo");

    // Move plugs, keeping colours.
    i32 c = patch_find(p, tri, in1);
    i32 color = p.cables[c].color;
    check(patch_move_src(p, e, c, saw), "move an output plug");
    check(patch_find(p, saw, in1) >= 0 && p.cables[patch_find(p, saw, in1)].color == color, "the moved cable keeps its colour");
    check(mirrors(p, e), "the engine followed the output move");
    c = patch_find(p, pulse, in2);
    check(patch_move_dst(p, e, c, in_of(e, "amp2.in1")), "move an input plug");
    check(patch_count_into(p, in2) == 0 && mirrors(p, e), "the input plug left its old jack");

    // Remove and undo.
    i32 before = p.n_cables;
    check(patch_remove(p, e, 0), "remove a cable");
    check(p.n_cables == before - 1 && mirrors(p, e), "the engine dropped the cable");
    check(patch_undo(p, e) && p.n_cables == before && mirrors(p, e), "undo brings it back");

    check(!patch_connect(p, e, saw, in1), "a duplicate cable is refused");
    patch_free(p);
}

void test_params() {
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    i32 res = engine_param_ref(e, "lowpass.res");
    f32 start = p.params[res];
    for i32 i = 1; i <= 10; i++ { patch_param_live(p, e, res, start + 0.05f * cast(f32, i)); }
    check(p.n_undo == 0, "a drag records nothing until release");
    patch_param_commit(p, res, start);
    check(p.n_undo == 1 && mirrors(p, e), "the release is one undo step");
    check(patch_undo(p, e) && p.params[res] == start && mirrors(p, e), "undo returns the knob to where the drag began");
    check(patch_redo(p, e) && fabsf(p.params[res] - (start + 0.5f)) < 1e-6f, "redo returns it to where the drag ended");

    i32 oct = engine_param_ref(e, "osc.octave");
    check(patch_set_param(p, e, oct, 1.0f) && mirrors(p, e), "a switch click sets the param");
    check(patch_undo(p, e) && fabsf(p.params[oct] - p.defaults[oct]) < 1e-6f, "undo resets the switch");
    patch_free(p);
}

void test_vintage() {
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    patch_load_default(p, e);
    i32 gate = out_of(e, "keys.gate");
    i32 trig = out_of(e, "keys.trig");
    i32 eoc1 = out_of(e, "env1.eoc");
    i32 eoc2 = out_of(e, "env2.eoc");
    i32 retrig = in_of(e, "env1.retrig");
    check(patch_connect(p, e, gate, in_of(e, "amp2.cv1")), "MODERN: a trigger into a CV input");
    i32 cables = p.n_cables;

    check(patch_set_profile(p, e, PROFILE_VINTAGE), "switch to VINTAGE");
    check(p.n_cables == cables - 1 && mirrors(p, e), "VINTAGE removed the trigger -> signal cable");
    check(!patch_connect(p, e, gate, in_of(e, "amp2.cv2")), "VINTAGE refuses trigger -> signal");
    check(patch_connect(p, e, gate, retrig) && patch_connect(p, e, trig, retrig)
          && patch_connect(p, e, eoc1, retrig) && patch_connect(p, e, eoc2, retrig), "four trigger cables stack");
    check(patch_count_into(p, retrig) == 4 && mirrors(p, e), "the engine ORs all four");

    check(patch_set_profile(p, e, PROFILE_MODERN), "back to MODERN");
    check(patch_count_into(p, retrig) == 1 && mirrors(p, e), "MODERN keeps one cable per input");
    check(patch_undo(p, e) && patch_count_into(p, retrig) == 4 && p.profile == PROFILE_VINTAGE && mirrors(p, e),
          "undo restores VINTAGE and the stacked cables");
    patch_free(p);
}

void test_history() {
    // Many gestures, then undo them all: back to the starting state.
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    patch_load_default(p, e);
    Patch* start = new(Patch);
    defer free(start);
    *start = *p;
    Rng r;
    rng_seed(&r, 3, 3);
    i32 gestures = 0;
    for i32 i = 0; i < 60; i++ {
        u32 pick = rng_next(&r) % 4;
        if pick == 0 {
            if patch_connect(p, e, cast(i32, rng_next(&r) % cast(u32, e.core.n_slots)), cast(i32, rng_next(&r) % cast(u32, e.core.n_jacks))) { gestures++; }
        } else if pick == 1 && p.n_cables > 0 {
            if patch_remove(p, e, cast(i32, rng_next(&r) % cast(u32, p.n_cables))) { gestures++; }
        } else if pick == 2 {
            if patch_set_param(p, e, cast(i32, rng_next(&r) % cast(u32, p.n_params)), (rng_uniform(&r) + 1.0f) * 0.5f) { gestures++; }
        } else {
            if patch_set_profile(p, e, 1 - p.profile) { gestures++; }
        }
    }
    check(mirrors(p, e), "the engine mirrors the patch after 60 random edits");
    i32 undone = 0;
    while patch_undo(p, e) { undone++; }
    check(undone == gestures, "every gesture is one undo step");
    bool same = p.n_cables == start.n_cables && p.profile == start.profile;
    for i32 i = 0; i < p.n_cables && same; i++ {
        if patch_find(start, p.cables[i].src, p.cables[i].dst) < 0 { same = false; }
    }
    for i32 i = 0; i < p.n_params; i++ { if p.params[i] != start.params[i] { same = false; } }
    check(same, "undoing everything returns to the start");
    check(mirrors(p, e), "the engine followed all the way back");
    while patch_redo(p, e) {}
    check(mirrors(p, e), "and all the way forward again");
    patch_free(p);
}

void test_fresh_engine() {
    // A new engine (a quality switch) takes the whole patch directly.
    Engine* a = rig_new();
    defer engine_free(a);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, a);
    patch_load_default(p, a);
    ignore patch_set_profile(p, a, PROFILE_VINTAGE);
    Engine* b = engine_new_os(48000.0f, 2);
    defer engine_free(b);
    rack_build(b);
    patch_apply_to_engine(p, b);
    check(mirrors(p, b), "a fresh engine takes the patch directly");
    patch_free(p);
}

i32 main() {
    test_default();
    test_edits();
    test_params();
    test_vintage();
    test_history();
    test_fresh_engine();
    return check_done();
}
