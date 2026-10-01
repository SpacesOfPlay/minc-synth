// test_engine.mc: registry, cable delay, feedback, params, the default
// patch, and the NaN guard.

import math;
import "util/check.mc";
import "util/rig.mc";               // brings in the engine and everything under it

void test_registry() {
    Engine* e = rig_new();
    defer engine_free(e);
    bool all = e.n_modules == RACK_N;
    for i32 i = 0; i < RACK_N; i++ {
        i32 m = engine_module(e, RACK[i].id);
        if m != i || e.modules[m].kind != RACK[i].kind { all = false; }
    }
    check(all, "every rack entry is a module, in rack order");
    check(engine_module(e, "lowpass") >= 0, "modules resolve by id");
    check(engine_output_ref(e, "osc.saw") >= 0, "outputs resolve by module.port");
    check(engine_input_ref(e, "lowpass.cv1") >= 0, "inputs resolve by module.port");
    check(engine_param_ref(e, "env1.attack") >= 0, "params resolve by module.name");
    check(engine_output_ref(e, "osc.nope") < 0 && engine_input_ref(e, "nope.in1") < 0, "unknown names do not resolve");

    // Port names are unique within each module.
    bool unique = true;
    for i32 m = 0; m < e.n_modules; m++ {
        ModuleDesc d = e.modules[m].desc;
        for i32 i = 0; i < d.n_inputs; i++ {
            for i32 k = i + 1; k < d.n_inputs; k++ {
                if str_equal(d.inputs[i].name, d.inputs[k].name) { unique = false; }
            }
        }
        for i32 i = 0; i < d.n_outputs; i++ {
            for i32 k = i + 1; k < d.n_outputs; k++ {
                if str_equal(d.outputs[i].name, d.outputs[k].name) { unique = false; }
            }
        }
    }
    check(unique, "port names are unique per module");
    check(e.core.n_slots < MAX_SLOTS && e.core.n_jacks < MAX_JACKS, "the rack fits the tables");
}

void test_cable_delay() {
    // noise -> mix1 -> amp1: mix1 lags noise by one sample, amp1 by two.
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "noise.white", "mix1.in1");
    ignore engine_set(e, "mix1.level1", 1.0f);
    ignore engine_connect(e, "mix1.out", "amp1.in1");
    ignore engine_set(e, "amp1.gain", 1.0f);
    ignore rig_run(e, 48000);                   // past the plugging fades; params settle to the snap
    f32[3] white;
    f32 worst1 = 0.0f;
    f32 worst2 = 0.0f;
    for i32 n = 0; n < 2000; n++ {
        ignore rig_run(e, 1);
        white[2] = white[1];
        white[1] = white[0];
        white[0] = rig_value(e, "noise.white");
        if n >= 2 {
            f32 d1 = fabsf(rig_value(e, "mix1.out") - white[1]);
            f32 want2 = AMP_SAT * tanh_fast(white[2] / AMP_SAT);
            f32 d2 = fabsf(rig_value(e, "amp1.out") - want2);
            if d1 > worst1 { worst1 = d1; }
            if d2 > worst2 { worst2 = d2; }
        }
    }
    print("cable delay: 1-cable error {}, 2-cable error {}\n", cast(f64, worst1), cast(f64, worst2));
    check(worst1 < 1e-5f, "one cable is one sample of delay");
    check(worst2 < 1e-5f, "two cables are two samples of delay");
}

void test_feedback() {
    // mix1.out -> mix1.in2 at 0.9: a leaky loop that must stay finite.
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "noise.white", "mix1.in1");
    ignore engine_connect(e, "mix1.out", "mix1.in2");
    ignore engine_set(e, "mix1.level2", 0.9f);
    f32 worst = 0.0f;
    bool ok = true;
    for i32 n = 0; n < 48000; n += 512 {
        ignore rig_run(e, 512);
        f32 v = rig_value(e, "mix1.out");
        if v != v { ok = false; }
        if fabsf(v) > worst { worst = fabsf(v); }
    }
    print("feedback loop peak {}\n", cast(f64, worst));
    check(ok && worst < 20.0f, "a feedback loop stays finite and bounded");
}

void test_params() {
    Engine* e = rig_new();
    defer engine_free(e);
    Core* c = &e.core;
    i32 attack = engine_param_ref(e, "env1.attack");
    check(fabsf(param(c, attack) - 0.005f) < 1e-5f, "exp taper default maps back to its value");
    ignore engine_set(e, "osc.octave", 1.2f);
    ignore rig_run(e, 1);
    check(param(c, engine_param_ref(e, "osc.octave")) == 1.0f, "switch params snap to a step, at once");

    i32 cut = engine_param_ref(e, "lowpass.cutoff");
    f32 before = param(c, cut);
    ignore engine_set(e, "lowpass.cutoff", 5.0f);
    i32 tau = cast(i32, PARAM_SMOOTH_S * RIG_SR + 0.5f);
    ignore rig_run(e, tau);                     // one time constant
    f32 mid = param(c, cut);
    ignore rig_run(e, 20 * tau);
    f32 after = param(c, cut);
    f32 frac = (mid - before) / (5.0f - before);
    print("cutoff smoothing: {} of the way after one time constant\n", cast(f64, frac));
    check(frac > 0.55f && frac < 0.7f, "knobs glide with PARAM_SMOOTH_S as the time constant");
    check(fabsf(after - 5.0f) < 1e-3f, "knobs reach their target");
}

void test_default_patch() {
    Engine* e = rig_new();
    defer engine_free(e);
    rack_default_patch(e);
    f32 idle = rig_run(e, 4800);
    ignore engine_key_on(e, 48);
    f32 playing = rig_run(e, 24000);
    ignore engine_key_off(e, 48);
    ignore rig_run(e, 48000);
    f32 after = rig_run(e, 4800);
    print("default patch: idle {}, key held {}, after release {}\n",
          cast(f64, idle), cast(f64, playing), cast(f64, after));
    check(idle < 1e-6f, "silent before a key");
    check(playing > 0.05f && playing <= 1.0f, "a held key sounds, within full scale");
    check(after < 1e-3f, "silent again after the release");
    check(fabs(cast(f64, rig_value(e, "keys.pitch")) + 1.0) < 1e-4, "KEYS holds the last pitch: C3 is -1 V");
}

void test_nan_guard() {
    Engine* e = rig_new();
    defer engine_free(e);
    rack_default_patch(e);
    ignore engine_key_on(e, 48);
    ignore rig_run(e, 4800);
    f32 zero = 0.0f;
    e.lowpass[0].v.s[0] = zero / zero;          // poison the filter
    f32 during = rig_run(e, 512);
    f32 later = rig_run(e, 24000);
    u32 resets = e.tele.nan_resets;
    print("nan guard: {} resets, block peak {}, then {}\n", resets, cast(f64, during), cast(f64, later));
    check(resets >= 1, "the guard reset the poisoned module");
    check(during == during && later == later, "the output stays finite");
    check(later > 0.05f, "the patch plays again after the reset");
    check(e.lowpass[0].v.s[0] == e.lowpass[0].v.s[0], "the filter state is clean");
}

i32 main() {
    test_registry();
    test_cable_delay();
    test_feedback();
    test_params();
    test_default_patch();
    test_nan_guard();
    return check_done();
}
