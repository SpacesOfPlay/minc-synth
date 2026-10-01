// test_patch_io.mc: patches as text. Save, load, save again gives the
// same bytes; a load is one undo step applied at silence; bad lines are
// skipped and counted.

import math;
import str;
import file;
import "util/check.mc";
import "util/rig.mc";

const str TMP_PATH = "build/test_patch_io.patch";

str sv(string s) { return str_from(s.data, s.len); }

// After the engine drains its commands (a load waits for the 10 ms fade
// first), every input's sources and every knob target must match the patch.
bool mirrors(Patch* p, Engine* e) {
    ignore rig_run(e, 2048);
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

// Same cables in the same order, same knobs to a millionth, same profile.
bool same_patch(Patch* a, Patch* b) {
    if a.n_cables != b.n_cables || a.profile != b.profile || a.n_params != b.n_params { return false; }
    for i32 i = 0; i < a.n_cables; i++ {
        if a.cables[i].src != b.cables[i].src || a.cables[i].dst != b.cables[i].dst
           || a.cables[i].color != b.cables[i].color { return false; }
    }
    for i32 i = 0; i < a.n_params; i++ {
        if fabsf(a.params[i] - b.params[i]) > 1e-6f { return false; }
    }
    return true;
}

// A patch with plenty in it: the default, then random edits.
void busy_patch(Patch* p, Engine* e, u64 seed) {
    patch_init(p, e);
    patch_load_default(p, e);
    Rng r;
    rng_seed(&r, seed, 7);
    for i32 i = 0; i < 80; i++ {
        u32 pick = rng_next(&r) % 3;
        if pick == 0 {
            ignore patch_connect(p, e, cast(i32, rng_next(&r) % cast(u32, e.core.n_slots)), cast(i32, rng_next(&r) % cast(u32, e.core.n_jacks)));
        } else if pick == 1 {
            ignore patch_set_param(p, e, cast(i32, rng_next(&r) % cast(u32, p.n_params)), (rng_uniform(&r) + 1.0f) * 0.5f);
        } else if p.n_cables > 0 {
            patch_cycle_color(p, cast(i32, rng_next(&r) % cast(u32, p.n_cables)));
        }
    }
}

void test_round_trip() {
    Engine* e1 = rig_new();
    defer engine_free(e1);
    Engine* e2 = rig_new();
    defer engine_free(e2);
    Patch* p = new(Patch);
    defer free(p);
    Patch* q = new(Patch);
    defer free(q);
    busy_patch(p, e1, 11);
    check(p.n_cables > 10, "the busy patch has cables");

    string t1 = patch_io_text(p, e1);
    defer free(t1);
    PatchData* d = new(PatchData);
    defer free(d);
    i32 skipped = 0;
    patch_init(q, e2);
    check(patch_io_parse(d, q, e2, sv(t1), &skipped) && skipped == 0, "the text parses without skipping a line");
    check(patch_replace(q, e2, d) == 0, "every cable is accepted");
    check(same_patch(p, q), "the loaded patch equals the saved one");
    check(mirrors(q, e2), "the engine mirrors the loaded patch");
    string t2 = patch_io_text(q, e2);
    defer free(t2);
    check(str_equal(sv(t1), sv(t2)), "save, load, save is byte-identical");
    print("{} bytes: {} cables, {} lines\n", t1.len, p.n_cables, 0);
    patch_free(p);
    patch_free(q);
}

void test_vintage_order() {
    // Stacked trigger cables keep their order through the file.
    Engine* e1 = rig_new();
    defer engine_free(e1);
    Engine* e2 = rig_new();
    defer engine_free(e2);
    Patch* p = new(Patch);
    defer free(p);
    Patch* q = new(Patch);
    defer free(q);
    patch_init(p, e1);
    ignore patch_set_profile(p, e1, PROFILE_VINTAGE);
    i32 retrig = engine_input_ref(e1, "env1.retrig");
    ignore patch_connect(p, e1, engine_output_ref(e1, "env2.eoc"), retrig);
    ignore patch_connect(p, e1, engine_output_ref(e1, "keys.gate"), retrig);
    ignore patch_connect(p, e1, engine_output_ref(e1, "keys.trig"), retrig);
    string t1 = patch_io_text(p, e1);
    defer free(t1);
    check(str_contains(sv(t1), "profile vintage"), "the profile is in the file");

    patch_init(q, e2);
    PatchData* d = new(PatchData);
    defer free(d);
    i32 skipped = 0;
    check(patch_io_parse(d, q, e2, sv(t1), &skipped) && patch_replace(q, e2, d) == 0, "the VINTAGE patch loads");
    check(q.profile == PROFILE_VINTAGE && patch_count_into(q, retrig) == 3, "three trigger cables stack again");
    check(same_patch(p, q) && mirrors(q, e2), "in the same order");

    // The same file into a MODERN patch: the profile line switches it first.
    patch_free(q);
    patch_free(p);
}

void test_file_and_undo() {
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    busy_patch(p, e, 5);
    string busy = patch_io_text(p, e);
    defer free(busy);
    check(patch_io_save(p, e, TMP_PATH), "save writes the file");

    Patch* q = new(Patch);
    defer free(q);
    patch_init(q, e);
    patch_load_default(q, e);
    string before = patch_io_text(q, e);
    defer free(before);
    PatchLoad r = patch_io_load(q, e, TMP_PATH);
    check(r.ok && r.skipped == 0 && r.cables == p.n_cables, "load reads it back");
    string after = patch_io_text(q, e);
    defer free(after);
    check(str_equal(sv(after), sv(busy)), "the loaded patch saves to the same bytes");
    check(mirrors(q, e), "the engine mirrors the loaded patch");
    check(q.n_undo == 1, "a load is one undo step");
    check(patch_undo(q, e), "undo the load");
    string back = patch_io_text(q, e);
    defer free(back);
    check(str_equal(sv(back), sv(before)) && mirrors(q, e), "undo restores the patch from before the load");
    check(patch_redo(q, e) && mirrors(q, e), "redo loads it again");
    string again = patch_io_text(q, e);
    defer free(again);
    check(str_equal(sv(again), sv(busy)), "to the same bytes");

    PatchLoad none = patch_io_load(q, e, "build/does_not_exist.patch");
    check(!none.ok, "a missing file is not a load");
    patch_free(p);
    patch_free(q);
}

void test_bad_lines() {
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    PatchData* d = new(PatchData);
    defer free(d);
    i32 skipped = 0;
    check(!patch_io_parse(d, p, e, "hello\n", &skipped), "text without the header is not a patch");
    check(!patch_io_parse(d, p, e, "", &skipped), "nor is empty text");

    str text = "# minc-synth patch 1\n\n# a comment\nprofile modern\r\nparam lowpass.res 0.5\nparam nosuch.knob 0.5\n"
               "param lowpass.res abc\ncable osc.saw -> lowpass.in1 color=3\ncable osc.saw lowpass.in2\n"
               "cable osc.nosuch -> lowpass.in2\ncable noise.white -> lowpass.in2\nwhatever 1 2 3\n";
    check(patch_io_parse(d, p, e, text, &skipped), "a patch with bad lines still parses");
    check(skipped == 5, "the bad lines are counted");
    check(d.n_cables == 2 && d.cables[0].color == 3 && d.cables[1].color == 4, "colours are read, or follow the last one");
    i32 res = engine_param_ref(e, "lowpass.res");
    check(fabsf(d.params[res] - 0.5f) < 1e-6f, "the knob was read");
    i32 cutoff = engine_param_ref(e, "lowpass.cutoff");
    check(d.params[cutoff] == p.defaults[cutoff], "a knob the file leaves out is at its default");

    // A header alone is an empty patch.
    check(patch_io_parse(d, p, e, "# minc-synth patch 1\n", &skipped) && skipped == 0 && d.n_cables == 0, "a header alone is an empty patch");
    check(patch_replace(p, e, d) == 0, "loading it is fine");
    string t = patch_io_text(p, e);
    defer free(t);
    check(str_equal(sv(t), "# minc-synth patch 1\nprofile modern\n"), "and saves as just the header and the profile");

    // A cable the profile forbids is refused at load, and counted.
    str vint = "# minc-synth patch 1\nprofile vintage\ncable keys.gate -> amp1.cv1\ncable keys.gate -> env1.retrig\n";
    check(patch_io_parse(d, p, e, vint, &skipped) && skipped == 0, "the lines themselves are fine");
    check(patch_replace(p, e, d) == 1 && p.n_cables == 1 && p.profile == PROFILE_VINTAGE, "VINTAGE refuses the trigger -> CV cable");
    patch_free(p);
}

// Loading while sound plays: the output fades to silence, the patch
// changes, and sound fades back, with no step in between.
void test_silent_load() {
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    i32 out_l = engine_input_ref(e, "out.l");
    ignore patch_connect(p, e, engine_output_ref(e, "osc.tri"), out_l);
    ignore rig_run(e, 4800);
    f32 before = rig_run(e, 4800);
    check(before > 0.05f, "the triangle sounds");

    PatchData* d = new(PatchData);
    defer free(d);
    patch_data_empty(p, d);
    d.cables[0] = Cable{ engine_output_ref(e, "osc.sine"), out_l, 0 };
    d.n_cables = 1;
    f32[1024] buf;
    engine_render(e, &buf[0], 512, 2);
    f32 last = buf[511 * 2];
    ignore patch_replace(p, e, d);

    // The load takes about two blocks: 10 ms out, the change, 10 ms in.
    // A 64-sample window of a C4 sine or triangle at this level peaks
    // well above 0.02, so only real silence gets a window under it.
    f32[4096] mono;
    i32 n = 0;
    f32 worst = 0.0f;
    for i32 b = 0; b < 8; b++ {
        engine_render(e, &buf[0], 512, 2);
        for i32 i = 0; i < 512; i++ {
            f32 step = fabsf(buf[i * 2] - last);
            if step > worst { worst = step; }
            last = buf[i * 2];
            mono[n] = buf[i * 2];
            n++;
        }
    }
    f32 quietest = 1.0f;
    for i32 i = 0; i + 64 <= n; i++ {
        f32 peak = peak_abs(&mono[i], 64);
        if peak < quietest { quietest = peak; }
    }
    f32 after = rig_run(e, 4800);
    print("silent load: worst step {}, quietest 64-sample window {}, sound after {}\n", cast(f64, worst), cast(f64, quietest), cast(f64, after));
    check(quietest < 0.02f, "the output reaches silence for the load");
    // A C4 sine at this level moves about 0.022 per sample on its own.
    check(worst < 0.04f, "no step in the output across the load");
    check(after > 0.05f && mirrors(p, e), "the sine sounds afterwards");
    patch_free(p);
}

i32 main() {
    test_round_trip();
    test_vintage_order();
    test_file_and_undo();
    test_bad_lines();
    test_silent_load();
    return check_done();
}
