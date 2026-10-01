// wav.mc: WAV files for offline renders.
//
// Three formats: 16-bit PCM with TPDF dither, 24-bit PCM, and 32-bit
// float. The renderer writes 24-bit by default; 16-bit is for a file
// that must play anywhere, and the dither turns its quantization into
// a low, even noise floor instead of distortion on quiet tails.

import file;

enum WavFormat { WAV_PCM16, WAV_PCM24, WAV_FLOAT32 }

private {
    void put_u16(u8* p, i32 v) {
        p[0] = cast(u8, v & 0xFF);
        p[1] = cast(u8, (v >> 8) & 0xFF);
    }

    void put_u24(u8* p, i32 v) {
        p[0] = cast(u8, v & 0xFF);
        p[1] = cast(u8, (v >> 8) & 0xFF);
        p[2] = cast(u8, (v >> 16) & 0xFF);
    }

    void put_u32(u8* p, i32 v) {
        put_u16(p, v & 0xFFFF);
        put_u16(p + 2, (v >> 16) & 0xFFFF);
    }

    void put_tag(u8* p, str tag) {
        for i32 i = 0; i < 4; i++ { p[i] = tag.data[i]; }
    }

    i32 get_u16(u8* p) { return p[0] | (p[1] << 8); }
    i32 get_u32(u8* p) { return get_u16(p) | (get_u16(p + 2) << 16); }

    unsafe_union WavBits { u32 u; f32 f; }

    i32 bytes_per_sample(i32 fmt) {
        if fmt == WAV_PCM16 { return 2; }
        if fmt == WAV_PCM24 { return 3; }
        return 4;
    }

    // Uniform in [-0.5, 0.5) from a xorshift32 state.
    f32 uniform(u32* state) {
        u32 x = *state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        *state = x;
        return cast(f32, x >> 8) * (1.0f / 16777216.0f) - 0.5f;
    }

    // x in -1..1 to a signed integer of `full` scale, rounded, with
    // triangular dither of one step peak-to-peak when `dither` is set.
    i32 quantize(f32 x, f32 full, bool dither, u32* rng) {
        if x > 1.0f { x = 1.0f; }
        if x < -1.0f { x = -1.0f; }
        f32 scaled = x * full;
        if dither { scaled += uniform(rng) + uniform(rng); }
        if scaled >= 0.0f { scaled += 0.5f; } else { scaled -= 0.5f; }
        i32 v = cast(i32, scaled);
        i32 top = cast(i32, full);
        if v > top { v = top; }
        if v < -top - 1 { v = -top - 1; }
        return v;
    }
}

const i32 WAV_HEADER_BYTES = 44;

// Interleaved frames in -1..1, written in `fmt`. PCM values outside the
// range clamp; float keeps them. False when the file cannot be written.
bool wav_write_format(str path, f32* samples, i32 frames, i32 channels, i32 sample_rate, i32 fmt) {
    i32 bps = bytes_per_sample(fmt);
    i32 data_bytes = frames * channels * bps;
    i64 total = WAV_HEADER_BYTES + data_bytes;
    u8* buf = alloc<u8>(total);
    defer free(buf);

    put_tag(buf, "RIFF");
    put_u32(buf + 4, 36 + data_bytes);
    put_tag(buf + 8, "WAVE");
    put_tag(buf + 12, "fmt ");
    put_u32(buf + 16, 16);
    put_u16(buf + 20, fmt == WAV_FLOAT32 ? 3 : 1);      // IEEE float or PCM
    put_u16(buf + 22, channels);
    put_u32(buf + 24, sample_rate);
    put_u32(buf + 28, sample_rate * channels * bps);    // bytes per second
    put_u16(buf + 32, channels * bps);                  // bytes per frame
    put_u16(buf + 34, 8 * bps);
    put_tag(buf + 36, "data");
    put_u32(buf + 40, data_bytes);

    u8* p = buf + WAV_HEADER_BYTES;
    u32 rng = 0x2545F491;
    for i32 i = 0; i < frames * channels; i++ {
        f32 x = samples[i];
        if fmt == WAV_PCM16 {
            put_u16(p + i * 2, quantize(x, 32767.0f, true, &rng) & 0xFFFF);
        } else if fmt == WAV_PCM24 {
            put_u24(p + i * 3, quantize(x, 8388607.0f, false, &rng) & 0xFFFFFF);
        } else {
            WavBits b = WavBits{ .f = x };
            put_u32(p + i * 4, cast(i32, b.u));
        }
    }
    return file_write(path, FileData{ .data = buf, .len = total });
}

// 16-bit PCM with dither.
bool wav_write(str path, f32* samples, i32 frames, i32 channels, i32 sample_rate) {
    return wav_write_format(path, samples, frames, channels, sample_rate, WAV_PCM16);
}

struct WavInfo {
    i32 channels;
    i32 sample_rate;
    i32 frames;
    i32 format;                         // WavFormat
    bool ok;
}

// Reads the header of a file written by wav_write_format.
WavInfo wav_info(u8* bytes, i64 len) {
    WavInfo w;
    if len < WAV_HEADER_BYTES { return w; }
    if bytes[0] != 'R' || bytes[8] != 'W' || bytes[36] != 'd' { return w; }
    i32 tag = get_u16(bytes + 20);
    i32 bits = get_u16(bytes + 34);
    if tag == 3 && bits == 32 { w.format = WAV_FLOAT32; }
    else if tag == 1 && bits == 24 { w.format = WAV_PCM24; }
    else if tag == 1 && bits == 16 { w.format = WAV_PCM16; }
    else { return w; }
    w.channels = get_u16(bytes + 22);
    w.sample_rate = get_u32(bytes + 24);
    if w.channels <= 0 { return w; }
    w.frames = get_u32(bytes + 40) / (w.channels * bytes_per_sample(w.format));
    w.ok = true;
    return w;
}

// Sample `i` of the interleaved data, as -1..1.
f32 wav_sample(u8* bytes, i32 i) {
    i32 bits = get_u16(bytes + 34);
    u8* p = bytes + WAV_HEADER_BYTES;
    if bits == 32 {
        WavBits b = WavBits{ .u = cast(u32, get_u32(p + i * 4)) };
        return b.f;
    }
    if bits == 24 {
        i32 v = p[i * 3] | (p[i * 3 + 1] << 8) | (p[i * 3 + 2] << 16);
        if v >= 8388608 { v -= 16777216; }
        return cast(f32, v) / 8388607.0f;
    }
    i32 v = get_u16(p + i * 2);
    if v >= 32768 { v -= 65536; }
    return cast(f32, v) / 32767.0f;
}
