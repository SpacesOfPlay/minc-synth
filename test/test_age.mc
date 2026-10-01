// test_age.mc: the AGE knob. At 0 nothing moves; at 1 every oscillator
// sits a few cents off, wanders slowly, and no two agree.

import math;
import "util/check.mc";
import "util/rig.mc";

// Frequency of an output over one second, in cents from `ref`.
f64 pitch_cents(Engine* e, str out, f64 ref) {
    i32 n = 48000;
    f32* buf = alloc<f32>(n);
    defer free(buf);
    for i32 i = 0; i < n; i++ {
        ignore rig_run(e, 1);
        buf[i] = rig_value(e, out);
    }
    return cents(measure_freq(buf, n, RIG_SR), ref);
}

void test_pristine() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "keys.pitch", "bank1.pitch1");
    ignore engine_key_on(e, 69);
    ignore rig_run(e, 4800);
    check(fabs(pitch_cents(e, "osc.sine", 440.0)) < 0.1, "AGE 0: OSC is exact");
    check(fabs(pitch_cents(e, "bank1.sine1", 440.0)) < 0.1, "AGE 0: a bank core is exact");
    check(e.core.age == 0.0f, "AGE reads 0 in the core");
}

void test_aged() {
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_connect(e, "keys.pitch", "bank1.pitch1");
    ignore engine_set(e, "out.age", 1.0f);
    ignore engine_key_on(e, 69);
    ignore rig_run(e, 24000);                   // the knob glides in
    check(e.core.age == 1.0f, "AGE reads 1 in the core");

    f64 osc1 = pitch_cents(e, "osc.sine", 440.0);
    f64 b1 = pitch_cents(e, "bank1.sine1", 440.0);
    f64 b2 = pitch_cents(e, "bank1.sine2", 440.0);
    f64 b3 = pitch_cents(e, "bank1.sine3", 440.0);
    print("AGE 1 at A4: osc {} cents, bank cores {} {} {} cents\n", osc1, b1, b2, b3);
    check(fabs(osc1) > 0.2 && fabs(osc1) < 12.0, "OSC sits off by a few cents, not more than twelve");
    check(fabs(b1) < 12.0 && fabs(b2) < 12.0 && fabs(b3) < 12.0, "so does every bank core");
    check(fabs(b1 - b2) > 0.2 && fabs(b2 - b3) > 0.2 && fabs(b1 - b3) > 0.2, "no two cores agree");

    // Five seconds on, the wander has moved the pitch.
    ignore rig_run(e, 5 * 48000);
    f64 later = pitch_cents(e, "osc.sine", 440.0);
    print("five seconds later: osc {} cents\n", later);
    check(fabs(later - osc1) > 0.1, "the pitch wandered");
    check(fabs(later) < 12.0, "and stayed within twelve cents");

    // Back to 0: exact again, at once.
    ignore engine_set(e, "out.age", 0.0f);
    ignore rig_run(e, 4800);
    check(fabs(pitch_cents(e, "osc.sine", 440.0)) < 0.1, "AGE back to 0 is exact again");
}

void test_scale() {
    // The scale error shows as a different offset an octave up.
    Engine* e = rig_new();
    defer engine_free(e);
    ignore engine_connect(e, "keys.pitch", "osc.pitch1");
    ignore engine_set(e, "out.age", 1.0f);
    ignore engine_key_on(e, 57);
    ignore rig_run(e, 4800);
    f64 low = pitch_cents(e, "osc.sine", 220.0);
    ignore engine_key_off(e, 57);
    ignore engine_key_on(e, 81);
    ignore rig_run(e, 4800);
    f64 high = pitch_cents(e, "osc.sine", 880.0);
    print("AGE 1 tracking: A3 {} cents, A5 {} cents\n", low, high);
    check(fabs(high - low) > 0.05 && fabs(high - low) < 8.0, "two octaves apart the error differs: a scale error, within 8 cents");
}

i32 main() {
    test_pristine();
    test_aged();
    test_scale();
    return check_done();
}
