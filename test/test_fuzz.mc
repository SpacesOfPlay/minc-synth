// test_fuzz.mc: random patches must stay finite and within full scale.
//
// 200 patches of 1 s each: random cables (feedback included), random
// knobs, random keys, random profile and plugging feel. `--long` runs
// 1000 patches of 5 s.

import math;
import str;
import "util/check.mc";
import "util/rig.mc";

i32 main() {
    i32 patches = 200;
    i32 seconds = 1;
    for i32 i = 1; i < get_argc(); i++ {
        if str_equal(str_from_cstr(get_arg(i)), "--long") {
            patches = 1000;
            seconds = 5;
        }
    }
    Rng r;
    rng_seed(&r, 20260927, 1);
    bool finite_ok = true;
    bool range_ok = true;
    u32 resets = 0;
    for i32 p = 0; p < patches; p++ {
        Engine* e = rig_new();
        Core* c = &e.core;
        ignore engine_send_kind(e, CMD_PROFILE, cast(i32, rng_next(&r) % 2), 0, 0.0f);
        ignore engine_send_kind(e, CMD_FEEL, cast(i32, rng_next(&r) % 2), 0, 0.0f);
        i32 cables = 8 + cast(i32, rng_next(&r) % 24);
        for i32 k = 0; k < cables; k++ {
            i32 s = cast(i32, rng_next(&r) % cast(u32, c.n_slots));
            i32 j = cast(i32, rng_next(&r) % cast(u32, c.n_jacks));
            ignore engine_send_kind(e, CMD_CONNECT, s, j, 0.0f);
        }
        for i32 k = 0; k < c.n_params; k++ {
            ignore engine_send_kind(e, CMD_PARAM, k, 0, (rng_uniform(&r) + 1.0f) * 0.5f);
        }
        // Loud outputs matter most: make sure something reaches OUT.
        ignore engine_send_kind(e, CMD_CONNECT, cast(i32, rng_next(&r) % cast(u32, c.n_slots)),
                                engine_input_ref(e, "out.l"), 0.0f);
        for i32 b = 0; b < seconds * 48000; b += RIG_BLOCK {
            if rng_next(&r) % 8 == 0 {
                i32 note = 36 + cast(i32, rng_next(&r) % 48);
                if rng_next(&r) % 2 == 0 { ignore engine_key_on(e, note); } else { ignore engine_key_off(e, note); }
            }
            engine_render(e, &g_rig_frames[0], RIG_BLOCK, 2);
            for i32 i = 0; i < RIG_BLOCK * 2; i++ {
                f32 v = g_rig_frames[i];
                if v != v { finite_ok = false; }
                if fabsf(v) > 1.0f { range_ok = false; }
            }
        }
        resets += e.tele.nan_resets;
        engine_free(e);
    }
    print("fuzz: {} patches x {} s, {} NaN-guard resets\n", patches, seconds, resets);
    check(finite_ok, "no NaN reaches the output");
    check(range_ok, "the output never exceeds full scale");
    return check_done();
}
