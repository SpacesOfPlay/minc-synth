// test_env.mc: timing, retrigger, release, loop and end-of-cycle of dsp_env.

import math;
import "../src/dsp_math.mc";
import "../src/dsp_env.mc";
import "util/check.mc";

const f32 SR = 48000.0f;

// Within 5 % of the expected sample count, or 2 samples for short stages.
bool near_count(i32 got, f64 want_s) {
    f64 want = want_s * SR;
    f64 tol = want * 0.05;
    if tol < 2.0 { tol = 2.0; }
    return fabs(cast(f64, got) - want) <= tol;
}

// Samples from gate-on until the level reaches full.
i32 attack_samples(f32 t) {
    Env e;
    env_set(&e, t, 1.0f, 0.5f, 1.0f, SR);
    i32 n = 0;
    while n < 10 * 48000 {
        n++;
        if env_tick(&e, true, false) >= 1.0f { break; }
    }
    return n;
}

// Samples from full level until within 1 % of the way to sustain 0.5.
i32 decay_samples(f32 t) {
    Env e;
    env_set(&e, 0.0005f, t, 0.5f, 1.0f, SR);
    while env_tick(&e, true, false) < 1.0f {}
    i32 n = 0;
    while n < 10 * 48000 {
        n++;
        if env_tick(&e, true, false) <= 0.505f { break; }
    }
    return n;
}

// Samples from gate-off at sustain 0.5 until 1 % of that level.
i32 release_samples(f32 t) {
    Env e;
    env_set(&e, 0.0005f, 0.001f, 0.5f, t, SR);
    for i32 i = 0; i < 4800; i++ { ignore env_tick(&e, true, false); }
    i32 n = 0;
    while n < 10 * 48000 {
        n++;
        if env_tick(&e, false, false) <= 0.005f { break; }
    }
    return n;
}

void test_timing() {
    f32[3] times = { 0.001f, 0.1f, 5.0f };
    for i32 i = 0; i < 3; i++ {
        f32 t = times[i];
        i32 a = attack_samples(t);
        i32 d = decay_samples(t);
        i32 r = release_samples(t);
        print("{} s: attack {} decay {} release {} samples (want {})\n",
              cast(f64, t), a, d, r, cast(f64, t) * 48000.0);
        check(near_count(a, t), "attack time within 5 %");
        check(near_count(d, t), "decay time within 5 %");
        check(near_count(r, t), "release time within 5 %");
    }
}

void test_shapes() {
    // Attack is concave (RC charge): past the midpoint in time, the level
    // is already above half.
    Env e;
    env_set(&e, 0.1f, 0.1f, 0.5f, 0.1f, SR);
    f32 mid = 0.0f;
    for i32 i = 0; i < 2400; i++ { mid = env_tick(&e, true, false); }
    check(mid > 0.55f && mid < 0.8f, "attack curve is an RC charge");

    // Retrigger during decay restarts the attack from the current level.
    env_set(&e, 0.01f, 0.2f, 0.2f, 0.2f, SR);
    e = Env{ .attack_coef = e.attack_coef, .decay_coef = e.decay_coef,
             .release_coef = e.release_coef, .sustain = e.sustain };
    for i32 i = 0; i < 4800; i++ { ignore env_tick(&e, true, false); }
    f32 before = e.level;
    f32 after = env_tick(&e, true, true);
    check(e.stage == ENV_ATTACK, "retrigger restarts the attack");
    check(after >= before, "retrigger does not drop the level");

    // Gate off mid-attack releases from where the attack was.
    Env f;
    env_set(&f, 0.1f, 0.1f, 0.5f, 0.1f, SR);
    for i32 i = 0; i < 1000; i++ { ignore env_tick(&f, true, false); }
    f32 held = f.level;
    f32 rel = env_tick(&f, false, false);
    check(f.stage == ENV_RELEASE, "gate off starts the release");
    check(rel <= held && rel > held * 0.99f, "release starts from the current level");

    // End of cycle fires once, when the release reaches silence.
    i32 eocs = 0;
    for i32 i = 0; i < 48000; i++ {
        ignore env_tick(&f, false, false);
        if f.eoc { eocs++; }
    }
    check(eocs == 1, "end of cycle fires once after the release");
    check(f.level == 0.0f && f.stage == ENV_IDLE, "release ends at silence");
}

void test_loop() {
    // Loop with sustain 0: an attack/decay LFO. 10 ms + 10 ms per cycle.
    Env e;
    env_set(&e, 0.01f, 0.01f, 0.0f, 0.01f, SR);
    e.loop = true;
    i32 cycles = 0;
    f32 lo = 1.0f;
    for i32 i = 0; i < 48000; i++ {
        f32 v = env_tick(&e, true, false);
        if e.eoc { cycles++; }
        if i > 4800 && v < lo { lo = v; }
    }
    print("loop: {} cycles per second, low point {}\n", cycles, cast(f64, lo));
    check(cycles >= 45 && cycles <= 55, "loop cycles about 50 times per second");
    check(lo < 0.02f, "loop decays close to sustain each cycle");
}

i32 main() {
    test_timing();
    test_shapes();
    test_loop();
    return check_done();
}
