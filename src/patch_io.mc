// patch_io.mc: patches as text files.
//
// One line per fact, in a fixed order, so two saves of the same patch
// are byte-identical and two patches diff by their cables and knobs:
//
//   # minc-synth patch 1
//   profile modern
//   param lowpass.cutoff 0.35
//   cable keys.pitch -> osc.pitch1 color=1
//
// Ports and knobs are named "module.port" by the rack's stable ids.
// Knobs are normalized 0..1 with six decimals, and only the ones off
// their default are written; a knob the file leaves out is at its
// default. Cables are in patch order, which matters for VINTAGE trigger
// inputs. The plugging feel and the engine rate are working preferences,
// not part of a patch. Lines starting with # and blank lines are ignored;
// a line that names nothing in the rack is skipped and counted.

import str;
import file;
import dsp_math;
import profile;
import engine_core;
import engine;
import patch;

const str PATCH_HEADER = "# minc-synth patch 1";
const i32 PATCH_DECIMALS = 6;

str[2] PROFILE_NAMES = { "modern", "vintage" };

struct PatchLoad {
    bool ok;                            // the file was read and was a patch
    i32 skipped;                        // lines that named nothing, or cables refused
    i32 cables;
}

// ---- names ----

private void ref_write(str_buf* sb, str module, str port) {
    str_buf_add(sb, module);
    str_buf_add_byte(sb, '.');
    str_buf_add(sb, port);
}

private void slot_ref(Engine* e, i32 slot, str_buf* sb) {
    for i32 m = 0; m < e.n_modules; m++ {
        ModuleInfo* info = &e.modules[m];
        if slot >= info.base.slot0 && slot < info.base.slot0 + info.desc.n_outputs {
            ref_write(sb, info.id, info.desc.outputs[slot - info.base.slot0].name);
            return;
        }
    }
}

private void jack_ref(Engine* e, i32 jack, str_buf* sb) {
    ModuleInfo* info = &e.modules[e.core.jacks[jack].module];
    ref_write(sb, info.id, info.desc.inputs[jack - info.base.jack0].name);
}

private void param_ref(Engine* e, i32 k, str_buf* sb) {
    for i32 m = 0; m < e.n_modules; m++ {
        ModuleInfo* info = &e.modules[m];
        if k >= info.base.param0 && k < info.base.param0 + info.desc.n_params {
            ref_write(sb, info.id, info.desc.params[k - info.base.param0].name);
            return;
        }
    }
}

// ---- numbers ----

// A normalized value to the nearest millionth, as an integer 0..1000000.
private i32 quantize(f32 v) {
    f64 x = cast(f64, clampf(v, 0.0f, 1.0f)) * 1000000.0;
    return cast(i32, floor(x + 0.5));
}

// "0.35", "1.0", "0.123456": a millionth is far below what a knob
// resolves, and an f32 near it reads back to the same six digits.
private void norm_write(f32 v, str_buf* sb) {
    i32 q = quantize(v);
    i32 whole = q / 1000000;
    i32 frac = q % 1000000;
    i32 digits = PATCH_DECIMALS;
    while digits > 1 && frac % 10 == 0 {
        frac /= 10;
        digits--;
    }
    string s = format("{}", whole);
    defer free(s);
    str_buf_add(sb, s);
    str_buf_add_byte(sb, '.');
    string f = format("{}", frac);
    defer free(f);
    for i32 i = f.len; i < digits; i++ { str_buf_add_byte(sb, '0'); }
    str_buf_add(sb, f);
}

private void int_write(i32 v, str_buf* sb) {
    string s = format("{}", v);
    defer free(s);
    str_buf_add(sb, s);
}

// Plain decimal: an optional sign, digits, an optional fraction.
private bool norm_parse(str s, f32* out) {
    i32 i = 0;
    bool neg = false;
    if i < s.len && (s.data[i] == '-' || s.data[i] == '+') {
        neg = s.data[i] == '-';
        i++;
    }
    f64 v = 0.0;
    i32 digits = 0;
    while i < s.len && s.data[i] >= '0' && s.data[i] <= '9' {
        v = v * 10.0 + cast(f64, s.data[i] - '0');
        i++;
        digits++;
    }
    if i < s.len && s.data[i] == '.' {
        i++;
        f64 place = 0.1;
        while i < s.len && s.data[i] >= '0' && s.data[i] <= '9' {
            v += cast(f64, s.data[i] - '0') * place;
            place *= 0.1;
            i++;
            digits++;
        }
    }
    if i != s.len || digits == 0 { return false; }
    if neg { v = -v; }
    *out = cast(f32, v);
    return true;
}

private bool int_parse(str s, i32* out) {
    if s.len == 0 { return false; }
    i32 v = 0;
    for i32 i = 0; i < s.len; i++ {
        u8 c = s.data[i];
        if c < '0' || c > '9' { return false; }
        v = v * 10 + cast(i32, c - '0');
    }
    *out = v;
    return true;
}

// ---- writing ----

void patch_io_write(Patch* p, Engine* e, str_buf* sb) {
    str_buf_add(sb, PATCH_HEADER);
    str_buf_add_byte(sb, '\n');
    str_buf_add(sb, "profile ");
    str_buf_add(sb, PROFILE_NAMES[p.profile]);
    str_buf_add_byte(sb, '\n');
    for i32 i = 0; i < p.n_params; i++ {
        if quantize(p.params[i]) == quantize(p.defaults[i]) { continue; }
        str_buf_add(sb, "param ");
        param_ref(e, i, sb);
        str_buf_add_byte(sb, ' ');
        norm_write(p.params[i], sb);
        str_buf_add_byte(sb, '\n');
    }
    for i32 i = 0; i < p.n_cables; i++ {
        Cable c = p.cables[i];
        str_buf_add(sb, "cable ");
        slot_ref(e, c.src, sb);
        str_buf_add(sb, " -> ");
        jack_ref(e, c.dst, sb);
        str_buf_add(sb, " color=");
        int_write(c.color, sb);
        str_buf_add_byte(sb, '\n');
    }
}

// The patch as text, owned.
string patch_io_text(Patch* p, Engine* e) {
    str_buf sb;
    str_buf_init(&sb);
    defer str_buf_free(&sb);
    patch_io_write(p, e, &sb);
    return format("{}", str_buf_to_str(&sb));
}

bool patch_io_save(Patch* p, Engine* e, str path) {
    str_buf sb;
    str_buf_init(&sb);
    defer str_buf_free(&sb);
    patch_io_write(p, e, &sb);
    return file_write_str(path, str_buf_to_str(&sb));
}

// ---- reading ----

private bool is_space(u8 c) { return c == ' ' || c == '\t' || c == '\r'; }

// The next whitespace-separated word from pos, empty at the end.
private str next_word(str line, i32* pos) {
    i32 i = *pos;
    while i < line.len && is_space(line.data[i]) { i++; }
    i32 start = i;
    while i < line.len && !is_space(line.data[i]) { i++; }
    *pos = i;
    return str_slice(line, start, i);
}

// One line into d. False when it named nothing the rack has.
private bool parse_line(PatchData* d, Patch* p, Engine* e, str line, i32* next_color) {
    i32 pos = 0;
    str key = next_word(line, &pos);
    if str_equal(key, "profile") {
        str name = next_word(line, &pos);
        for i32 i = 0; i < PROFILE_COUNT; i++ {
            if str_equal(name, PROFILE_NAMES[i]) {
                d.profile = i;
                return true;
            }
        }
        return false;
    }
    if str_equal(key, "param") {
        i32 k = engine_param_ref(e, next_word(line, &pos));
        f32 v = 0.0f;
        if k < 0 || k >= d.n_params || !norm_parse(next_word(line, &pos), &v) { return false; }
        d.params[k] = clampf(v, 0.0f, 1.0f);
        return true;
    }
    if str_equal(key, "cable") {
        i32 src = engine_output_ref(e, next_word(line, &pos));
        if !str_equal(next_word(line, &pos), "->") { return false; }
        i32 dst = engine_input_ref(e, next_word(line, &pos));
        if src < 0 || dst < 0 || d.n_cables == PATCH_MAX_CABLES { return false; }
        i32 color = *next_color;
        str opt = next_word(line, &pos);
        if str_starts_with(opt, "color=") {
            i32 c = 0;
            if int_parse(str_slice(opt, 6, opt.len), &c) { color = c % PATCH_COLORS; }
        }
        *next_color = (color + 1) % PATCH_COLORS;
        d.cables[d.n_cables] = Cable{ src, dst, color };
        d.n_cables++;
        return true;
    }
    return false;
}

// Text into d, starting from an empty patch. False when the text is not
// a patch at all; then d is untouched. Lines that name nothing count in
// skipped.
bool patch_io_parse(PatchData* d, Patch* p, Engine* e, str text, i32* skipped) {
    *skipped = 0;
    i32 pos = 0;
    bool header = false;
    i32 next_color = 0;
    PatchData* out = new(PatchData);
    defer free(out);
    patch_data_empty(p, out);
    while pos < text.len {
        i32 end = pos;
        while end < text.len && text.data[end] != '\n' { end++; }
        str line = str_trim(str_slice(text, pos, end));
        pos = end + 1;
        if line.len == 0 { continue; }
        if !header {
            if !str_starts_with(line, PATCH_HEADER) { return false; }
            header = true;
            continue;
        }
        if line.data[0] == '#' { continue; }
        if !parse_line(out, p, e, line, &next_color) { *skipped += 1; }
    }
    if !header { return false; }
    *d = *out;
    return true;
}

// Text into the patch as one undo step, at silence.
PatchLoad patch_io_load_text(Patch* p, Engine* e, str text) {
    PatchLoad r = PatchLoad{};
    if text.len == 0 { return r; }
    PatchData* d = new(PatchData);
    defer free(d);
    if !patch_io_parse(d, p, e, text, &r.skipped) { return r; }
    r.skipped += patch_replace(p, e, d);
    r.ok = true;
    r.cables = p.n_cables;
    return r;
}

// Reads a file into the patch, likewise.
PatchLoad patch_io_load(Patch* p, Engine* e, str path) {
    string text = file_read_str(path);
    defer free(text);
    return patch_io_load_text(p, e, str_from(text.data, text.len));
}
