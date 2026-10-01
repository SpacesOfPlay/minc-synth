// bench.mc: what the full rack costs, against the budget in plan.md 5.15.
//
//   minc run tools/bench.mc
//
// Renders the rack at a 48 kHz device rate with a key held: the default
// patch, and a worst case with every input patched. Prints the share of
// one core at each engine rate.

import math;
import "../test/util/rig.mc";

f64 now_s() { return cast(f64, qpc()) / cast(f64, qpf()); }

// Every input takes a cable from the first of a few sources its profile
// allows, as test_roster's whole-rack test does.
void patch_everything(Engine* e) {
    str[5] sources = { "osc.saw", "keys.gate", "noise.smooth", "env1.env", "seq.gate" };
    for i32 j = 0; j < e.core.n_jacks; j++ {
        for i32 k = 0; k < 5; k++ {
            i32 s = engine_output_ref(e, sources[k]);
            if e.core.slot_module[s] == e.core.jacks[j].module { continue; }
            if profile_can_connect(e.core.profile, e.core.slot_cls[s], e.core.jacks[j].cls) {
                ignore engine_send_kind(e, CMD_CONNECT, s, j, 0.0f);
                break;
            }
        }
    }
}

// Percent of one core for `seconds` of audio.
f64 cost(i32 os, bool worst, f64 seconds) {
    Engine* e = engine_new_os(48000.0f, os);
    defer engine_free(e);
    rack_build(e);
    rack_default_patch(e);
    if worst { patch_everything(e); }
    ignore engine_key_on(e, 48);
    ignore rig_run(e, 9600);
    f64 t0 = now_s();
    ignore rig_run(e, cast(i32, 48000.0 * seconds));
    return 100.0 * (now_s() - t0) / seconds;
}

i32 main() {
    ignore cost(2, false, 2.0);                 // lets the CPU clock up before measuring
    print("full rack ({} modules), 48 kHz device, % of one core:\n", RACK_N);
    i32[3] rates = { 1, 2, 4 };
    str[3] names = { "1x", "2x NORMAL", "4x HIGH" };
    for i32 i = 0; i < 3; i++ {
        print("  {}: default patch {} %, every input patched {} %\n", names[i], cost(rates[i], false, 5.0), cost(rates[i], true, 5.0));
    }
    print("budget: NORMAL < 15 %, HIGH < 30 %\n");
    return 0;
}
