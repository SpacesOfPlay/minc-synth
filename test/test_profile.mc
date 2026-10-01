// test_profile.mc: MODERN and VINTAGE scaling, connection rules, trigger OR.

import math;
import "util/check.mc";
import "util/rig.mc";

// The default patch minus its one cross-class cable (ENV2 into a pitch input).
void same_class_patch(Engine* e) {
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "osc.saw", "lowpass.in1");
    ignore engine_connect(e, "lowpass.out", "amp1.in1");
    ignore engine_connect(e, "env1.env", "amp1.cv1");
    ignore engine_connect(e, "amp1.out", "out.l");
    ignore engine_set(e, "lowpass.res", 0.6f);
}

void test_same_class() {
    Engine* a = rig_new();
    Engine* b = rig_new();
    defer engine_free(a);
    defer engine_free(b);
    ignore engine_send_kind(b, CMD_PROFILE, PROFILE_VINTAGE, 0, 0.0f);
    same_class_patch(a);
    same_class_patch(b);
    ignore engine_key_on(a, 45);
    ignore engine_key_on(b, 45);
    f32 worst = 0.0f;
    for i32 n = 0; n < 48000; n += RIG_BLOCK {
        ignore rig_run(a, RIG_BLOCK);
        f32 va = rig_value(a, "amp1.out");
        ignore rig_run(b, RIG_BLOCK);
        f32 vb = rig_value(b, "amp1.out");
        if fabsf(va - vb) > worst { worst = fabsf(va - vb); }
    }
    print("same-class patch, MODERN vs VINTAGE: worst difference {}\n", cast(f64, worst));
    check(worst < 1e-4f, "same-class patches sound the same in both profiles");
    check(fabsf(rig_volts(b, "amp1.out")) < 1.6f * 1.5f, "VINTAGE audio sits on the bus at its own level");
}

void test_cross_class() {
    // Audio into an AMP CV input: the depth is the ratio of the scales.
    f32[2] ratio;
    for i32 p = 0; p < 2; p++ {
        Engine* e = rig_new();
        ignore engine_send_kind(e, CMD_PROFILE, p, 0, 0.0f);
        ignore engine_connect(e, "osc.saw", "amp1.cv1");
        ignore rig_run(e, 4800);
        ratio[p] = rig_input(e, "amp1.cv1") / rig_value(e, "osc.saw");
        engine_free(e);
    }
    print("audio -> CV depth: MODERN {}, VINTAGE {}\n", cast(f64, ratio[0]), cast(f64, ratio[1]));
    check(fabsf(ratio[0] - 5.0f / 10.0f) < 1e-4f, "MODERN: 5 V audio is half of a 10 V CV");
    check(fabsf(ratio[1] - 1.5f / 5.5f) < 1e-4f, "VINTAGE: audio is gentler against CV");
}

void test_rules() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.gate", "amp1.cv1");
    ignore engine_connect(e, "osc.saw", "env1.retrig");
    ignore rig_run(e, 1);
    check(rig_jack(e, "amp1.cv1").n_src == 1 && rig_jack(e, "env1.retrig").n_src == 1,
          "MODERN patches trigger and signal jacks together");

    // Switching to VINTAGE drops the cables it forbids.
    ignore engine_send_kind(e, CMD_PROFILE, PROFILE_VINTAGE, 0, 0.0f);
    ignore rig_run(e, 1);
    check(rig_jack(e, "amp1.cv1").n_src == 0 && rig_jack(e, "env1.retrig").n_src == 0,
          "VINTAGE drops trigger <-> signal cables");
    ignore engine_connect(e, "keys.gate", "amp1.cv1");
    ignore rig_run(e, 1);
    check(rig_jack(e, "amp1.cv1").n_src == 0, "VINTAGE refuses trigger -> signal");

    // Trigger inputs OR up to four sources in VINTAGE.
    ignore engine_connect(e, "keys.gate", "env1.retrig");
    ignore engine_connect(e, "keys.trig", "env1.retrig");
    ignore engine_connect(e, "env2.eoc", "env1.retrig");
    ignore rig_run(e, 1);
    check(rig_jack(e, "env1.retrig").n_src == 3, "VINTAGE trigger inputs stack cables");
    ignore engine_key_on(e, 60);
    ignore rig_run(e, 480);
    check(rig_input(e, "env1.retrig") == 1.0f, "stacked triggers read as an OR");
}

void test_core_limits() {
    // A bare core: five trigger outputs into one trigger input.
    Core* c = new(Core);
    defer free(c);
    core_init(c, 48000.0f);
    core_set_profile(c, PROFILE_VINTAGE);
    i32[5] outs;
    for i32 i = 0; i < 5; i++ { outs[i] = core_add_output(c, CLS_TRIG, 0); }
    i32 j = core_add_input(c, CLS_TRIG, 0.0f, 1);
    bool ok = true;
    for i32 i = 0; i < 4; i++ { if !core_connect(c, outs[i], j) { ok = false; } }
    check(ok, "four trigger cables fit");
    check(!core_connect(c, outs[4], j), "a fifth trigger cable is refused");
    c.rd[outs[2] * MAX_VOICES] = 1.0f;
    check(jack_read(c, j) == 1.0f, "one closed source closes the line");

    core_set_profile(c, PROFILE_MODERN);
    check(c.jacks[j].n_src == 1, "back in MODERN a trigger input keeps one cable");
    check(profile_scale(PROFILE_MODERN, CLS_PITCH) == profile_scale(PROFILE_VINTAGE, CLS_PITCH),
          "1 V/oct is shared by both profiles");
}

i32 main() {
    test_same_class();
    test_cross_class();
    test_rules();
    test_core_limits();
    return check_done();
}
