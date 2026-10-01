// test_plugging.mc: SMOOTH crossfades and AUTHENTIC switching with bounce.

import math;
import "util/check.mc";
import "util/rig.mc";

// A steady source: KEYS pitch at +1 V (C5) into MIX1 at unity, which reads
// it as 0.2 of full audio level.
Engine* dc_rig(i32 feel) {
    Engine* e = rig_new();
    ignore engine_send_kind(e, CMD_FEEL, feel, 0, 0.0f);
    ignore engine_set(e, "mix1.level1", 1.0f);
    ignore engine_key_on(e, 72);
    ignore rig_run(e, 48000);
    return e;
}

// Records MIX1's output for n samples after the command already queued.
void record(Engine* e, f32* buf, i32 n) {
    for i32 i = 0; i < n; i++ {
        ignore rig_run(e, 1);
        buf[i] = rig_value(e, "mix1.out");
    }
}

void test_smooth() {
    Engine* e = dc_rig(FEEL_SMOOTH);
    defer engine_free(e);
    f32[400] buf;
    ignore engine_connect(e, "keys.pitch", "mix1.in1");
    record(e, &buf[0], 400);
    f32 max_step = 0.0f;
    for i32 i = 1; i < 400; i++ {
        f32 d = fabsf(buf[i] - buf[i - 1]);
        if d > max_step { max_step = d; }
    }
    i32 fade = cast(i32, FADE_S * RIG_SR);
    print("smooth connect: max step {} over a {}-sample fade, final {}\n", cast(f64, max_step), fade, cast(f64, buf[399]));
    check(max_step < 0.2f / cast(f32, fade) * 1.1f, "SMOOTH ramps in with no step");
    check(fabsf(buf[fade + 2] - 0.2f) < 1e-5f, "SMOOTH reaches the new source after the fade");

    ignore engine_disconnect(e, "keys.pitch", "mix1.in1");
    record(e, &buf[0], 400);
    max_step = 0.0f;
    for i32 i = 1; i < 400; i++ {
        f32 d = fabsf(buf[i] - buf[i - 1]);
        if d > max_step { max_step = d; }
    }
    check(max_step < 0.2f / cast(f32, fade) * 1.1f, "SMOOTH ramps out on disconnect");
    check(fabsf(buf[399]) < 1e-6f, "the unpatched input returns to its normal");
}

void test_authentic() {
    Engine* e = dc_rig(FEEL_AUTHENTIC);
    defer engine_free(e);
    f32[400] buf;
    i32 bounce = cast(i32, BOUNCE_S * RIG_SR);
    i32 total_flips = 0;
    bool only_ends = true;
    for i32 round = 0; round < 8; round++ {
        ignore engine_connect(e, "keys.pitch", "mix1.in1");
        record(e, &buf[0], 400);
        i32 flips = 0;
        for i32 i = 0; i < 400; i++ {
            bool off = fabsf(buf[i]) < 1e-6f;
            bool on = fabsf(buf[i] - 0.2f) < 1e-5f;
            if !off && !on { only_ends = false; }
            if i > 0 && fabsf(buf[i] - buf[i - 1]) > 0.1f { flips++; }
        }
        total_flips += flips;
        check(fabsf(buf[bounce + 2] - 0.2f) < 1e-5f, "AUTHENTIC ends connected after the bounce");
        ignore engine_disconnect(e, "keys.pitch", "mix1.in1");
        record(e, &buf[0], 400);
        check(fabsf(buf[399]) < 1e-6f, "AUTHENTIC disconnect ends unpatched");
    }
    print("authentic: {} contact flips over 8 connects\n", total_flips);
    check(only_ends, "AUTHENTIC switches between the two sources with nothing in between");
    check(total_flips >= 8, "AUTHENTIC connects bounce");
}

i32 main() {
    test_smooth();
    test_authentic();
    return check_done();
}
