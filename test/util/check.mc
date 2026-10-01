// check.mc: shared assertions and signal measurements for the tests.
//
// Lives in test/util/ so the test runner, which compiles every test/*.mc,
// does not treat it as a test of its own.

import math;

i32 g_failed = 0;

void check(bool ok, str what) {
    if !ok {
        print("FAIL: {}\n", what);
        g_failed++;
    }
}

// Exit status for main: 0 when every check passed.
i32 check_done() {
    if g_failed > 0 {
        print("{} check(s) failed\n", g_failed);
        return 1;
    }
    print("ok\n");
    return 0;
}

f64 cents(f64 measured, f64 expected) {
    return 1200.0 * log(measured / expected) / log(2.0);
}

f64 db(f64 ratio) { return 20.0 * log(ratio) / log(10.0); }

// Amplitude of the component at `hz` in buf[0..n): a Goertzel filter over
// a 4-term Blackman-Harris window (sidelobes below -92 dB). A full-scale
// sine at `hz` reads 1.0; the main lobe spans +-4 bins of sr / n.
f64 tone_amplitude(f32* buf, i32 n, f64 hz, f64 sr) {
    f64 w = 2.0 * 3.141592653589793 * hz / sr;
    f64 coeff = 2.0 * cos(w);
    f64 s1 = 0.0;
    f64 s2 = 0.0;
    f64 wsum = 0.0;
    f64 step = 2.0 * 3.141592653589793 / cast(f64, n);
    for i32 i = 0; i < n; i++ {
        f64 a = step * cast(f64, i);
        f64 win = 0.35875 - 0.48829 * cos(a) + 0.14128 * cos(2.0 * a) - 0.01168 * cos(3.0 * a);
        f64 x = buf[i];
        f64 s0 = x * win + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
        wsum += win;
    }
    f64 re = s1 - s2 * cos(w);
    f64 im = s2 * sin(w);
    return 2.0 * sqrt(re * re + im * im) / wsum;
}

// Frequency from the first and last rising zero crossings in buf[0..n),
// each located by linear interpolation. 0 when fewer than two crossings.
f64 measure_freq(f32* buf, i32 n, f64 sr) {
    f64 first = -1.0;
    f64 last = -1.0;
    i32 count = 0;
    for i32 i = 1; i < n; i++ {
        f32 a = buf[i - 1];
        f32 b = buf[i];
        if a < 0.0f && b >= 0.0f {
            f64 t = cast(f64, i - 1) + cast(f64, -a / (b - a));
            if count == 0 { first = t; }
            last = t;
            count++;
        }
    }
    if count < 2 { return 0.0; }
    return cast(f64, count - 1) * sr / (last - first);
}

f32 peak_abs(f32* buf, i32 n) {
    f32 p = 0.0f;
    for i32 i = 0; i < n; i++ {
        if fabsf(buf[i]) > p { p = fabsf(buf[i]); }
    }
    return p;
}

f64 mean(f32* buf, i32 n) {
    f64 s = 0.0;
    for i32 i = 0; i < n; i++ { s += buf[i]; }
    return s / cast(f64, n);
}

f64 rms(f32* buf, i32 n) {
    f64 s = 0.0;
    for i32 i = 0; i < n; i++ {
        f64 x = buf[i];
        s += x * x;
    }
    return sqrt(s / cast(f64, n));
}

bool all_finite(f32* buf, i32 n) {
    for i32 i = 0; i < n; i++ {
        f32 x = buf[i];
        if x != x || x > 1e30f || x < -1e30f { return false; }
    }
    return true;
}
