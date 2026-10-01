// test_commands.mc: the command ring, cable edits, patch loads and panic.

import math;
import "util/check.mc";
import "util/rig.mc";

void test_ring() {
    CmdRing* r = new(CmdRing);
    defer free(r);
    i32 pushed = 0;
    while cmd_push(r, Cmd{ CMD_PARAM, pushed, 0, 0.0f }) { pushed++; }
    check(pushed == CMD_RING_SIZE, "the ring holds CMD_RING_SIZE commands");
    bool ordered = true;
    Cmd c;
    for i32 i = 0; i < pushed; i++ {
        if !cmd_pop(r, &c) || c.a != i { ordered = false; }
    }
    check(ordered, "commands come out in the order they went in");
    check(!cmd_pop(r, &c), "an empty ring pops nothing");
    check(cmd_push(r, Cmd{ CMD_PARAM, 7, 0, 0.0f }), "the ring accepts again once drained");
}

void test_cables() {
    Engine* e = rig_new();
    defer engine_free(e);
    Jack* in1 = rig_jack(e, "lowpass.in1");
    i32 saw = engine_output_ref(e, "osc.saw");
    i32 pulse = engine_output_ref(e, "osc.pulse");

    ignore engine_connect(e, "osc.saw", "lowpass.in1");
    ignore rig_run(e, 1);
    check(in1.n_src == 1 && in1.src[0] == saw, "connect patches the input");

    ignore engine_connect(e, "osc.pulse", "lowpass.in1");
    ignore rig_run(e, 1);
    check(in1.n_src == 1 && in1.src[0] == pulse, "a second cable replaces the first");

    ignore engine_connect(e, "osc.pulse", "lowpass.in2");
    ignore rig_run(e, 1);
    check(rig_jack(e, "lowpass.in2").n_src == 1, "one output feeds several inputs");

    ignore engine_disconnect(e, "osc.saw", "lowpass.in1");
    ignore rig_run(e, 1);
    check(in1.n_src == 1, "disconnecting a cable that isn't there changes nothing");
    ignore engine_disconnect(e, "osc.pulse", "lowpass.in1");
    ignore rig_run(e, 1);
    check(in1.n_src == 0, "disconnect unpatches the input");
    check(!engine_connect(e, "osc.nope", "lowpass.in1"), "unknown ports are refused on the UI side");
}

void test_load() {
    Engine* e = rig_new();
    defer engine_free(e);
    rack_default_patch(e);
    ignore engine_key_on(e, 48);
    ignore rig_run(e, 9600);

    i32 cutoff = engine_param_ref(e, "lowpass.cutoff");
    f32 before = e.core.params[cutoff].target;
    ignore engine_send_kind(e, CMD_LOAD_BEGIN, 0, 0, 0.0f);
    ignore engine_set(e, "lowpass.cutoff", 3.0f);
    ignore rig_run(e, 1);
    check(e.core.params[cutoff].target == before, "commands inside a load wait for silence");
    ignore rig_run(e, 1024);
    f32 quiet = rig_run(e, 512);
    check(e.core.params[cutoff].target != before, "the load applies once silent");
    check(quiet < 1e-6f, "the output stays silent until LOAD_END");

    ignore engine_send_kind(e, CMD_LOAD_END, 0, 0, 0.0f);
    ignore rig_run(e, 1024);
    f32 back = rig_run(e, 4800);
    print("load: silent {}, then {}\n", cast(f64, quiet), cast(f64, back));
    check(back > 0.05f, "sound returns after LOAD_END");
}

void test_panic() {
    Engine* e = rig_new();
    defer engine_free(e);
    rack_default_patch(e);
    ignore engine_key_on(e, 48);
    ignore rig_run(e, 9600);
    ignore engine_send_kind(e, CMD_PANIC, 0, 0, 0.0f);
    ignore rig_run(e, 2048);
    check(e.keys[0].n_held == 0, "panic releases every key");
    check(e.hold == HOLD_NONE && e.fade_target == 1.0f, "panic ends by fading back in");
    f32 after = rig_run(e, 4800);
    check(after < 1e-3f, "silent after panic until a key is played");
    ignore engine_key_on(e, 50);
    check(rig_run(e, 9600) > 0.05f, "the patch plays again after panic");
}

i32 main() {
    test_ring();
    test_cables();
    test_load();
    test_panic();
    return check_done();
}
