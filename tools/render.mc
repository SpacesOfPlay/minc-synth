// render.mc: offline renderer. Plays the rack to a WAV file.
//
//   minc run render [out.wav] [seconds] [--quality normal|high|1x] [--patch file] [--format 24|16|f32]
//
// Defaults: build/render.wav, 16 s, NORMAL (the engine at 2x the rate),
// 24-bit PCM. 16-bit is written with TPDF dither; f32 keeps the float
// samples as they are, including anything past full scale.
//
// Builds the rack, loads the default patch (or the patch file named with
// --patch), and plays a 16-step bass line
// at 120 BPM into KEYS: notes are key commands at exact sample positions,
// and slides are legato notes with a short glide. The same engine and
// commands as the live app, without an audio device.

import math;
import str;
import file;
import "../src/dsp_math.mc";
import "../src/engine_cmd.mc";
import "../src/engine.mc";
import "../src/rack.mc";
import "../src/wav.mc";
import "../src/patch.mc";
import "../src/patch_io.mc";

const i32 SR = 48000;
const i32 STEP_SAMPLES = SR / 8;        // 16th notes at 120 BPM
const i32 GATE_SAMPLES = STEP_SAMPLES * 55 / 100;
const i32 ROOT_NOTE = 36;               // C2
const i32 BLOCK = 512;

// Semitones above the root; a slide glides into its note without a new attack.
i32[16] PATTERN = { 0, 0, 12, 0, 3, 0, 7, 10, 0, 0, 12, 5, 3, 0, -2, 0 };
bool[16] SLIDE = { false, false, false, false, false, false, false, true,
                   false, false, false, true, false, false, true, false };

// Renders n frames into out, in blocks.
void render_frames(Engine* e, f32* out, i32 n) {
    i32 done = 0;
    while done < n {
        i32 k = BLOCK;
        if n - done < k { k = n - done; }
        engine_render(e, out + done * 2, k, 2);
        done += k;
    }
}

void bass_patch(Engine* e) {
    rack_default_patch(e);
    ignore engine_set(e, "lowpass.res", 0.7f);
    ignore engine_set(e, "env2.decay", 0.18f);
    ignore engine_set(e, "env2.sustain", 0.0f);
    ignore engine_set(e, "env1.decay", 0.3f);
    ignore engine_set(e, "env1.sustain", 0.5f);
    ignore engine_set(e, "env1.release", 0.05f);
}

// A saved patch into the engine before it runs.
bool load_patch(Engine* e, str path) {
    string text = file_read_str(path);
    defer free(text);
    if text.len == 0 {
        eprint("cannot read {}\n", path);
        return false;
    }
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    PatchData* d = new(PatchData);
    defer free(d);
    i32 skipped = 0;
    if !patch_io_parse(d, p, e, str_from(text.data, text.len), &skipped) {
        eprint("{} is not a minc-synth patch\n", path);
        return false;
    }
    if skipped > 0 { eprint("{}: {} lines skipped\n", path, skipped); }
    patch_set_data(p, d);
    patch_apply_to_engine(p, e);
    return true;
}

i32 parse_seconds(str s) {
    i32 v = 0;
    for i32 i = 0; i < s.len; i++ {
        u8 c = s.data[i];
        if c < '0' || c > '9' { return -1; }
        v = v * 10 + cast(i32, c - '0');
    }
    return v;
}

i32 main() {
    str path = "build/render.wav";
    i32 seconds = 16;
    i32 os = quality_oversample(QUALITY_NORMAL);
    i32 positional = 0;
    str patch_path = "";
    i32 fmt = WAV_PCM24;
    for i32 i = 1; i < get_argc(); i++ {
        str a = str_from_cstr(get_arg(i));
        if str_equal(a, "--format") && i + 1 < get_argc() {
            i++;
            str f = str_from_cstr(get_arg(i));
            if str_equal(f, "16") { fmt = WAV_PCM16; }
            else if str_equal(f, "24") { fmt = WAV_PCM24; }
            else if str_equal(f, "f32") { fmt = WAV_FLOAT32; }
            else {
                eprint("--format takes 16, 24 or f32\n");
                return 1;
            }
        } else if str_equal(a, "--patch") && i + 1 < get_argc() {
            i++;
            patch_path = str_from_cstr(get_arg(i));
        } else if str_equal(a, "--quality") && i + 1 < get_argc() {
            i++;
            str q = str_from_cstr(get_arg(i));
            if str_equal(q, "high") { os = quality_oversample(QUALITY_HIGH); }
            else if str_equal(q, "normal") { os = quality_oversample(QUALITY_NORMAL); }
            else if str_equal(q, "1x") { os = 1; }
            else {
                eprint("--quality takes normal, high or 1x\n");
                return 1;
            }
        } else if positional == 0 {
            path = a;
            positional++;
        } else {
            seconds = parse_seconds(a);
            if seconds <= 0 {
                eprint("seconds must be a positive integer\n");
                return 1;
            }
            positional++;
        }
    }

    i32 frames = SR * seconds;
    f32* buf = alloc<f32>(frames * 2);
    defer free(buf);

    Engine* e = engine_new_os(cast(f32, SR), os);
    defer engine_free(e);
    rack_build(e);
    if patch_path.len > 0 {
        if !load_patch(e, patch_path) { return 1; }
    } else {
        bass_patch(e);
    }

    i64 t0 = qpc();
    i32 pos = 0;
    i32 step = 0;
    i32 held = -1;                          // note currently held
    while pos < frames {
        i32 s = step % 16;
        i32 next = (step + 1) % 16;
        i32 note = ROOT_NOTE + PATTERN[s];
        ignore engine_set(e, "keys.glide", SLIDE[s] ? 0.06f : 0.001f);
        ignore engine_key_on(e, note);
        if held >= 0 && held != note { ignore engine_key_off(e, held); }
        held = note;

        // Hold through the gate; a slide into the next step keeps the key down.
        i32 gate = GATE_SAMPLES;
        if SLIDE[next] { gate = STEP_SAMPLES; }
        if pos + gate > frames { gate = frames - pos; }
        render_frames(e, buf + pos * 2, gate);
        pos += gate;
        if !SLIDE[next] && pos < frames {
            ignore engine_key_off(e, held);
            held = -1;
            i32 rest = STEP_SAMPLES - gate;
            if pos + rest > frames { rest = frames - pos; }
            render_frames(e, buf + pos * 2, rest);
            pos += rest;
        }
        step++;
    }
    f64 elapsed = cast(f64, qpc() - t0) / cast(f64, qpf());

    f32 peak = 0.0f;
    f64 sum = 0.0;
    for i32 i = 0; i < frames; i++ {
        f32 v = buf[i * 2];
        if fabsf(v) > peak { peak = fabsf(v); }
        sum += cast(f64, v * v);
    }
    if !wav_write_format(path, buf, frames, 2, SR, fmt) {
        eprint("could not write {}\n", path);
        return 1;
    }
    print("wrote {}: {} s, peak {}, rms {}\n", path, seconds, cast(f64, peak), sqrt(sum / cast(f64, frames)));
    print("rendered with the engine at {}x in {} s ({}x real time)\n", os, elapsed, cast(f64, seconds) / elapsed);
    return 0;
}
