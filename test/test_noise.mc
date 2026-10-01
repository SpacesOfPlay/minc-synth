// test_noise.mc: level, spectral slope and determinism of dsp_noise.

import math;
import "../src/dsp_math.mc";
import "../src/dsp_svf.mc";
import "../src/dsp_noise.mc";
import "util/check.mc";

const f32 SR = 48000.0f;
const i32 N = 5 * 48000;

// RMS of `buf` through a one-octave band-pass at fc (constant Q).
f64 band_rms(f32* buf, f32 fc) {
    Svf s;
    svf_set(&s, fc, 1.41421356f, SR);
    f64 sum = 0.0;
    for i32 i = 0; i < N; i++ {
        SvfOut o = svf_process(&s, buf[i]);
        f64 b = o.band * s.k;
        sum += b * b;
    }
    return sqrt(sum / cast(f64, N));
}

// Band level at 4 kHz relative to 250 Hz, four octaves apart. In
// constant-Q bands white rises 3 dB/oct, pink is flat, red falls 3 dB/oct.
f64 tilt_db(f32* buf) { return db(band_rms(buf, 4000.0f) / band_rms(buf, 250.0f)); }

i32 main() {
    f32* white = alloc<f32>(N);
    f32* pink = alloc<f32>(N);
    f32* red = alloc<f32>(N);
    defer free(white);
    defer free(pink);
    defer free(red);

    Noise n;
    noise_init(&n, 1);
    for i32 i = 0; i < N; i++ {
        NoiseSample o = noise_tick(&n);
        white[i] = o.white;
        pink[i] = o.pink;
        red[i] = o.red;
    }

    f64 rw = rms(white, N);
    f64 rp = rms(pink, N);
    f64 rr = rms(red, N);
    print("rms: white {} pink {} red {}\n", rw, rp, rr);
    check(fabs(mean(white, N)) < 0.01, "white has no DC");
    check(fabs(rw - 0.35) < 0.035, "white RMS near 0.35");
    check(fabs(rp - 0.35) < 0.035, "pink RMS near 0.35");
    check(fabs(rr - 0.35) < 0.07, "red RMS near 0.35");

    f64 tw = tilt_db(white);
    f64 tp = tilt_db(pink);
    f64 tr = tilt_db(red);
    print("tilt 250 Hz -> 4 kHz: white {} dB, pink {} dB, red {} dB\n", tw, tp, tr);
    check(fabs(tw - 12.0) < 2.5, "white rises 3 dB per octave in constant-Q bands");
    check(fabs(tp) < 2.5, "pink is flat in constant-Q bands");
    check(fabs(tr + 12.0) < 2.5, "red falls 3 dB per octave in constant-Q bands");

    Noise a;
    Noise b;
    noise_init(&a, 77);
    noise_init(&b, 77);
    bool same = true;
    for i32 i = 0; i < 1000; i++ {
        if noise_tick(&a).white != noise_tick(&b).white { same = false; }
    }
    check(same, "same seed, same noise");
    return check_done();
}
