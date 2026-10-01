// test_presets.mc: every preset in patches/ loads with nothing skipped,
// arrives through silence, sounds with a key held, and stays finite.

import math;
import str;
import file;
import "util/check.mc";
import "util/rig.mc";

const str PRESET_DIR = "patches";
const i32 KEY = 48;                     // C3

f32[1024] g_buf;

// Renders n frames and returns the peak, noting the quietest 64-sample
// window and whether everything stayed finite.
f32 render(Engine* e, i32 n, f32* quietest, bool* finite) {
    f32 peak = 0.0f;
    f32[4096] mono;
    i32 have = 0;
    i32 left = n;
    while left > 0 {
        i32 k = 512;
        if left < k { k = left; }
        engine_render(e, &g_buf[0], k, 2);
        if !all_finite(&g_buf[0], k * 2) { *finite = false; }
        for i32 i = 0; i < k; i++ {
            f32 v = fabsf(g_buf[i * 2]);
            if v > peak { peak = v; }
            if have < 4096 {
                mono[have] = g_buf[i * 2];
                have++;
            }
        }
        left -= k;
    }
    for i32 i = 0; i + 64 <= have; i++ {
        f32 w = peak_abs(&mono[i], 64);
        if w < *quietest { *quietest = w; }
    }
    return peak;
}

void test_preset(str name) {
    string path = path_join(PRESET_DIR, name);
    defer free(path);
    str p_str = str_from(path.data, path.len);
    Engine* e = rig_new();
    defer engine_free(e);
    Patch* p = new(Patch);
    defer free(p);
    patch_init(p, e);
    patch_load_default(p, e);
    ignore engine_key_on(e, KEY);
    ignore rig_run(e, 24000);

    PatchLoad r = patch_io_load(p, e, p_str);
    string what = format("{}: loads with nothing skipped", name);
    defer free(what);
    check(r.ok && r.skipped == 0 && r.cables == p.n_cables, str_from(what.data, what.len));

    // The first 20 ms hold the load: silence somewhere in there.
    f32 quietest = 1.0f;
    bool finite = true;
    ignore render(e, 2048, &quietest, &finite);
    string q = format("{}: the load passes through silence", name);
    defer free(q);
    check(quietest < 0.02f, str_from(q.data, q.len));

    // Then three seconds with the key held: sound, and nothing blows up.
    f32 rest = 1.0f;
    f32 peak = render(e, 144000, &rest, &finite);
    string s = format("{}: sounds ({} peak) and stays finite", name, cast(f64, peak));
    defer free(s);
    check(finite && peak > 0.02f && peak < 1.0f, str_from(s.data, s.len));
    check(atomic_load(&e.tele.nan_resets, RELAXED) == 0, "no guard resets");

    // Save it back: the same bytes.
    string text = patch_io_text(p, e);
    defer free(text);
    string disk = file_read_str(p_str);
    defer free(disk);
    string same = format("{}: saves back to the same bytes", name);
    defer free(same);
    check(str_equal(str_from(text.data, text.len), str_from(disk.data, disk.len)), str_from(same.data, same.len));
    patch_free(p);
}

i32 main() {
    DirList files = dir_list_ext(PRESET_DIR, ".patch");
    defer dir_list_free(&files);
    check(files.count >= 8, "at least eight presets");
    i32 vintage = 0;
    for i32 i = 0; i < files.count; i++ {
        test_preset(files.items[i]);
        string path = path_join(PRESET_DIR, files.items[i]);
        defer free(path);
        string text = file_read_str(str_from(path.data, path.len));
        defer free(text);
        if str_contains(str_from(text.data, text.len), "profile vintage") { vintage++; }
    }
    check(vintage >= 2, "at least two VINTAGE presets");
    return check_done();
}
