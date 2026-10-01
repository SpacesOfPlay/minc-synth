// test_wav.mc: WAV header and sample round trips in the three formats,
// and that the 16-bit dither keeps a tone smaller than one step.

import math;
import file;
import "../src/wav.mc";
import "util/check.mc";

const str PATH = "build/test_wav.wav";

void test_round_trip(i32 fmt, str name, f32 tol) {
    f32[8] frames = { 0.0f, 0.5f, -0.5f, 1.0f, -1.0f, 2.0f, -2.0f, 0.25f };
    string what = format("{}: wav_write_format succeeds", name);
    defer free(what);
    check(wav_write_format(PATH, &frames[0], 4, 2, 48000, fmt), str_from(what.data, what.len));

    FileData fd = file_read(PATH);
    defer free(fd.data);
    WavInfo w = wav_info(fd.data, fd.len);
    string h = format("{}: header parses and its fields round trip", name);
    defer free(h);
    check(w.ok && w.format == fmt && w.channels == 2 && w.sample_rate == 48000 && w.frames == 4, str_from(h.data, h.len));

    f32[8] want = { 0.0f, 0.5f, -0.5f, 1.0f, -1.0f, 1.0f, -1.0f, 0.25f };
    if fmt == WAV_FLOAT32 {
        want[5] = 2.0f;                                 // float keeps what it is given
        want[6] = -2.0f;
    }
    bool same = true;
    for i32 i = 0; i < 8; i++ {
        if fabsf(wav_sample(fd.data, i) - want[i]) > tol { same = false; }
    }
    string s = format("{}: samples round trip within tolerance", name);
    defer free(s);
    check(same, str_from(s.data, s.len));
    ignore file_remove(PATH);
}

// A 1 kHz sine 0.4 of a 16-bit step tall. Rounded without dither it is
// silence; with dither it survives as a tone in noise. At 24 bits it is
// 100 steps tall and comes back as it went in.
void test_dither() {
    const i32 N = 48000;
    f32* x = alloc<f32>(N);
    defer free(x);
    f32 amp = 0.4f / 32767.0f;
    for i32 i = 0; i < N; i++ { x[i] = amp * sinf(2.0f * 3.14159265f * 1000.0f * cast(f32, i) / 48000.0f); }

    check(wav_write_format(PATH, x, N, 1, 48000, WAV_PCM16), "16-bit write of a sub-step tone");
    FileData fd = file_read(PATH);
    defer free(fd.data);
    f32* y = alloc<f32>(N);
    defer free(y);
    f32 peak = 0.0f;
    for i32 i = 0; i < N; i++ {
        y[i] = wav_sample(fd.data, i);
        if fabsf(y[i]) > peak { peak = fabsf(y[i]); }
    }
    f64 tone = tone_amplitude(y, N, 1000.0, 48000.0);
    f64 noise = rms(y, N);
    print("dither: tone {} of {} in, noise rms {} steps, peak {} steps\n", tone * 32767.0, cast(f64, amp) * 32767.0,
          noise * 32767.0, cast(f64, peak) * 32767.0);
    check(peak > 0.0f, "the file is not silent");
    check(fabs(tone - cast(f64, amp)) < 0.15 * cast(f64, amp), "the tone comes through the dither within 15 %");
    check(noise * 32767.0 > 0.3 && noise * 32767.0 < 0.9, "the noise floor is a fraction of a step, as TPDF gives");
    check(peak * 32767.0f < 2.5f, "nothing bigger than two steps");
    ignore file_remove(PATH);

    check(wav_write_format(PATH, x, N, 1, 48000, WAV_PCM24), "24-bit write of the same tone");
    FileData fd24 = file_read(PATH);
    defer free(fd24.data);
    f32 worst = 0.0f;
    for i32 i = 0; i < N; i++ {
        f32 d = fabsf(wav_sample(fd24.data, i) - x[i]);
        if d > worst { worst = d; }
    }
    check(worst < 1.0f / 8388607.0f, "at 24 bits the tone returns within one 24-bit step");
    ignore file_remove(PATH);
}

i32 main() {
    ignore dir_create("build");
    test_round_trip(WAV_PCM16, "16-bit", 2.0f / 32767.0f);       // one step plus the dither
    test_round_trip(WAV_PCM24, "24-bit", 1.0f / 8388607.0f);
    test_round_trip(WAV_FLOAT32, "float", 0.0f);
    test_dither();
    return check_done();
}
