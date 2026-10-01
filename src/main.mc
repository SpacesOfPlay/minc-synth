// main.mc: minc-synth application. Window, audio device, frame loop.
//
//   frame thread (sapp)                    audio thread (stream_cb)
//   mouse and keys -> ui -> patch -> engine commands -> engine_render
//   panels, cables, bar <- engine telemetry ------------
//
// The UI (ui_state, ui_draw) edits the patch (patch.mc), which mirrors
// every change to the engine. Letters on the two note rows play KEYS.
//
// `--quality high` starts the engine at 4x the device rate instead of 2x;
// F3 or the bar button switches while playing.
//
// `--smoke N` holds a key for N seconds, switching quality halfway, then
// quits. The exit code is 0 when the device took callbacks and sound
// reached the output, 3 when there were no callbacks, and 4 when the
// output stayed silent.
//
// Patch files: the one open is the current file, named in the status row
// with a dot while it has unsaved changes. Ctrl+S writes it, or asks
// where when there is none yet; the SAVE button and Ctrl+Shift+S always
// ask; Ctrl+O (or LOAD) and a file dropped on the window open one, as an
// undoable step. The dialogs are the system's own (file_dialog.mc). At
// start `--patch file`, else minc-synth.patch in the working directory,
// is opened when it exists. [ and ] step through the presets, the .patch
// files in patches/ sorted by name; a preset opens as an untitled copy.
//
// On the web there is no file: SAVE keeps the patch in the page's storage
// and in the URL hash, so the link carries it, and LOAD and the start
// read them back (web/synth.html provides the two imports).
//
// `--shot file.png` saves the frame drawn after one second, then quits
// (Direct3D 11 only). With --smoke, a key is held so the cables glow.

@wasm_html "../web/synth.html"      // the page the browser build is served with (web/synth.html)
import sokol_all;
import sokol_gl;
import ui_text;
import sokol_time;
import sokol_audio;
import atomic;
import math;
import str;
import dsp_math;
import profile;
import engine_core;
import engine_cmd;
import engine;
import rack;
import patch;
import patch_io;
import file;
import ui_layout;
import ui_view;
import ui_state;
import ui_draw;
import shot;
import file_dialog;
import window;

const i32 AUDIO_RATE = 48000;
const i32 AUDIO_FRAMES = 512;
const i32 SMOKE_NOTE = 48;
const f64 SHOT_AT_S = 1.0;

// Two tracker-style rows: Z..M, the lower octave from C3; Q..I, the upper from C4.
const str KEYS_LOWER = "ZSXDCVGBHNJM,";
const str KEYS_UPPER = "Q2W3ER5T6Y7UI";

// ---- shared with the audio thread ----

Engine* g_engine = null;            // published once built
u32 g_audio_ready = 0;              // 1 once g_engine runs at the device's rate; the callback renders from then on
u32 g_load_bits = 0;                // callback time / buffer time, f32 bits
u32 g_callbacks = 0;
bool[128] g_held;                   // notes down on the computer keyboard, for the KEYS panel's key map

// ---- frame thread only ----

sg_pass_action g_pass_action;
Patch* g_patch = null;
Ui* g_ui = null;
bool g_audio_started = false;       // start_audio has run
bool g_audio_ok = false;
f32 g_load_shown = 0.0f;
f32 g_out_peak_max = 0.0f;
f64 g_frame_sum = 0.0;              // frame times after the first second, for the smoke report
f64 g_frame_max = 0.0;
i32 g_frames = 0;
i32 g_quality = QUALITY_NORMAL;
f32 g_device_rate = 48000.0f;
f64 g_smoke_seconds = 0.0;          // 0: run until the window closes
bool g_smoke_switched = false;
u64 g_start_ticks = 0;
str g_shot_path = "";              // --shot: where to save the frame
str g_patch_path = "minc-synth.patch";   // --patch: the file opened at start
string g_file;                      // the current patch file, or empty for an untitled patch
string g_title;                     // its name as the status row shows it
string g_saved_text;                // the patch as last saved or opened, for spotting changes
bool g_dirty = false;
f64 g_dirty_checked = 0.0;
string g_dropped;                   // a file dropped on the window, opened on the next frame
const str PRESET_DIR = "patches";
when os(wasm) {
    extern "env" i32 web_text_read(u8* key, u8* buf, i32 cap);
    extern "env" void web_text_write(u8* key, u8* text, i32 len);
    const i32 WEB_TEXT_CAP = 65536;
}
const str FONT_DIR = "fonts";
DirList g_presets;                  // the preset files, sorted
string g_preset_index;              // on the web: the manifest the names point into
i32 g_preset = -1;                  // the one loaded last, or -1
bool g_shot_done = false;

// Changing the engine rate: the old engine holds at silence, a new one
// takes the patch, and the old one is freed once the audio thread has
// moved on.
bool g_switching = false;
Engine* g_retired = null;
u32 g_retire_after = 0;             // callback count after which g_retired is unused

// ---- audio ----

void stream_cb(f32* buf, i32 num_frames, i32 num_channels) {
    Engine* e = null;
    if atomic_load(&g_audio_ready, ACQUIRE) != 0 { e = atomic_load(&g_engine, ACQUIRE); }
    if e == null {
        for i32 i = 0; i < num_frames * num_channels; i++ { buf[i] = 0.0f; }
        return;
    }
    u64 t0 = stm_now();
    engine_render(e, buf, num_frames, num_channels);
    f64 frames = num_frames;
    f64 used = stm_sec(stm_since(t0));
    atomic_store(&g_load_bits, f32_bits(cast(f32, used * cast(f64, e.device_rate) / frames)), RELAXED);
    ignore atomic_add(&g_callbacks, 1);
}

// ---- engine rate ----

void start_switch() {
    if g_switching { return; }
    g_quality = 1 - g_quality;
    g_switching = true;
    ignore engine_send_kind(g_engine, CMD_LOAD_BEGIN, 0, 0, 0.0f);
}

// Finishes a quality switch once the old engine is silent, and frees the
// engine it replaced once the audio thread can no longer be inside it.
void update_switch() {
    Engine* old = g_engine;
    u32 callbacks = atomic_load(&g_callbacks);
    if g_retired != null && (callbacks >= g_retire_after || !g_audio_ok) {
        engine_free(g_retired);
        g_retired = null;
    }
    if !g_switching || g_retired != null { return; }
    if g_audio_ok && atomic_load(&old.tele.silent, ACQUIRE) == 0 { return; }
    Engine* e = engine_new_os(g_device_rate, quality_oversample(g_quality));
    rack_build(e);
    patch_apply_to_engine(g_patch, e);
    engine_copy_keys(e, old);
    e.fade = 0.0f;
    e.fade_target = 1.0f;
    atomic_store(&g_engine, e, RELEASE);
    g_retired = old;
    g_retire_after = callbacks + 2;         // a callback in flight finishes with the old one
    g_switching = false;
}

// Opens the audio device. Called once the first frame is on screen, so
// the window doesn't wait for the device (opening it takes about 0.2 s).
// init built the engine for the rate asked for; a device that runs at
// another rate gets an engine of its own before the callback renders
// anything, which is safe because the callback touches no engine until
// g_audio_ready is set.
void start_audio() {
    g_audio_started = true;
    saudio_setup(&saudio_desc{
        .sample_rate = AUDIO_RATE,
        .num_channels = 2,
        .buffer_frames = AUDIO_FRAMES,
        .stream_cb = stream_cb,
        .logger = saudio_logger{ .func = slog_func },
    });
    g_audio_ok = saudio_isvalid();
    if g_audio_ok && cast(f32, saudio_sample_rate()) != g_device_rate {
        g_device_rate = cast(f32, saudio_sample_rate());
        Engine* old = g_engine;
        Engine* e = engine_new_os(g_device_rate, quality_oversample(g_quality));
        rack_build(e);
        patch_apply_to_engine(g_patch, e);
        // The old engine never ran, so what init sent it (a key held for
        // the smoke run, say) is still queued: it goes to the new one.
        Cmd c;
        while cmd_pop(&old.cmds, &c) { ignore engine_send(e, c); }
        atomic_store(&g_engine, e, RELEASE);
        engine_free(old);
    }
    atomic_store(&g_audio_ready, 1, RELEASE);
}

// ---- the patch on the web ----

when os(wasm) {
    // The text kept under `key` ("hash" or "store"), owned; empty when none.
    string web_text(str key) {
        u8* buf = alloc<u8>(WEB_TEXT_CAP);
        defer free(buf);
        i32 n = web_text_read(str_to_cstr(key), buf, WEB_TEXT_CAP);
        if n <= 0 || n > WEB_TEXT_CAP { return string(""); }
        return format("{}", str_from(buf, n));
    }

    void web_save(Engine* e) {
        string text = patch_io_text(g_patch, e);
        defer free(text);
        web_text_write(str_to_cstr("store"), text.data, text.len);
        web_text_write(str_to_cstr("hash"), text.data, text.len);
        ui_notice(g_ui, "saved: this page keeps it, and the address bar holds a link to it");
    }

    // The patch from the URL, else the page's storage; false when neither has one.
    bool web_load(Engine* e, bool at_start) {
        string text = web_text("hash");
        defer free(text);
        if text.len == 0 {
            free(text);
            text = web_text("store");
        }
        if text.len == 0 {
            if !at_start { ui_notice(g_ui, "nothing saved on this page yet"); }
            return false;
        }
        PatchLoad r = patch_io_load_text(g_patch, e, str_from(text.data, text.len));
        if !r.ok {
            if !at_start { ui_notice(g_ui, "the saved text is not a patch"); }
            return false;
        }
        if !at_start {
            string msg = format("loaded: {} cables, {} lines skipped", r.cables, r.skipped);
            defer free(msg);
            ui_notice(g_ui, str_from(msg.data, msg.len));
        }
        return true;
    }
}

// ---- the current file ----

// The window that owns a dialog, where the system wants one.
void* dialog_owner() {
    when os(windows) { return sapp_win32_get_hwnd(); }
    else { return null; }
}

// The patch as it stands is the saved state of `path` (empty: untitled,
// shown as `title`).
void set_current(Engine* e, str path, str title) {
    string file = format("{}", path);
    string name = format("{}", title);
    free(g_file);
    free(g_title);
    g_file = move(file);
    g_title = move(name);
    free(g_saved_text);
    g_saved_text = patch_io_text(g_patch, e);
    g_dirty = false;
}

// A few times a second: whether the patch differs from what was saved.
void update_dirty(Engine* e, f64 now) {
    if now - g_dirty_checked < 0.25 { return; }
    g_dirty_checked = now;
    string text = patch_io_text(g_patch, e);
    defer free(text);
    g_dirty = !str_equal(str_from(text.data, text.len), str_from(g_saved_text.data, g_saved_text.len));
}

void notice_fmt(string msg) {
    ui_notice(g_ui, str_from(msg.data, msg.len));
    free(msg);
}

void save_to(Engine* e, str path) {
    if !patch_io_save(g_patch, e, path) {
        notice_fmt(format("could not write {}", path));
        return;
    }
    set_current(e, path, path_basename(path));
    notice_fmt(format("saved {}", path));
}

void save_as(Engine* e) {
    string suggested = g_file.len > 0 ? format("{}", g_file) : format("{}.patch", g_title);
    defer free(suggested);
    Picked p = file_dialog(dialog_owner(), true, str_from(suggested.data, suggested.len));
    defer free(p.path);
    if p.missing {
        notice_fmt(format("no file dialog on this system (zenity or kdialog); saving to {}", g_patch_path));
        save_to(e, g_patch_path);
        return;
    }
    if p.path.len == 0 { return; }
    string path = with_patch_ext(str_from(p.path.data, p.path.len));
    defer free(path);
    save_to(e, str_from(path.data, path.len));
}

void open_file(Engine* e, str path) {
    PatchLoad r = patch_io_load(g_patch, e, path);
    if !r.ok {
        notice_fmt(format("could not read {} as a patch", path));
        return;
    }
    set_current(e, path, path_basename(path));
    if r.skipped > 0 { notice_fmt(format("opened {}: {} lines skipped", path, r.skipped)); }
    else { notice_fmt(format("opened {}", path)); }
}

void open_dialog(Engine* e) {
    Picked p = file_dialog(dialog_owner(), false, str_from(g_file.data, g_file.len));
    defer free(p.path);
    if p.missing {
        notice_fmt(format("no file dialog on this system (zenity or kdialog); opening {}", g_patch_path));
        open_file(e, g_patch_path);
        return;
    }
    if p.path.len > 0 { open_file(e, str_from(p.path.data, p.path.len)); }
}

// Save, save as, open and a dropped file, asked for by the last events.
// Here, in the frame, rather than inside the event handler: the dialogs
// run a message loop of their own.
void handle_file_requests(Engine* e) {
    when os(wasm) {
        if g_ui.want_save || g_ui.want_save_as {
            g_ui.want_save = false;
            g_ui.want_save_as = false;
            web_save(e);
        }
        if g_ui.want_load {
            g_ui.want_load = false;
            ignore web_load(e, false);
        }
    } else {
        // The requests are cleared before a dialog opens: on macOS the
        // panel's modal loop keeps drawing frames, which come back here.
        bool save = g_ui.want_save;
        bool ask = g_ui.want_save_as || (save && g_file.len == 0);
        g_ui.want_save = false;
        g_ui.want_save_as = false;
        if ask { save_as(e); }
        else if save { save_to(e, str_from(g_file.data, g_file.len)); }
        if g_ui.want_load {
            g_ui.want_load = false;
            open_dialog(e);
        }
        if g_dropped.len > 0 {
            string path = move(g_dropped);
            g_dropped = string("");
            open_file(e, str_from(path.data, path.len));
            free(path);
        }
    }
}

// ---- presets ----

// The preset files: the directory listing, or on the web, where nothing
// can list a directory, the names in patches/index.txt that the build
// staged with the files.
void load_preset_list() {
    g_presets = dir_list_ext(PRESET_DIR, ".patch");
    if g_presets.count > 0 { return; }
    string index = path_join(PRESET_DIR, "index.txt");
    defer free(index);
    g_preset_index = file_read_str(str_from(index.data, index.len));
    str text = str_from(g_preset_index.data, g_preset_index.len);
    i32 n = 0;
    i32 pos = 0;
    while pos < text.len {
        i32 end = pos;
        while end < text.len && text.data[end] != '\n' { end++; }
        if str_trim(str_slice(text, pos, end)).len > 0 { n++; }
        pos = end + 1;
    }
    if n == 0 { return; }
    g_presets.items = alloc<str>(n);
    g_presets._cap = n;
    pos = 0;
    while pos < text.len {
        i32 end = pos;
        while end < text.len && text.data[end] != '\n' { end++; }
        str line = str_trim(str_slice(text, pos, end));
        if line.len > 0 {
            g_presets.items[g_presets.count] = line;
            g_presets.count++;
        }
        pos = end + 1;
    }
}

// Loads the preset `step` places on from the current one, wrapping.
void load_preset(Engine* e, i32 step) {
    i32 n = g_presets.count;
    if n == 0 {
        ui_notice(g_ui, "no presets: patches/ is empty");
        return;
    }
    i32 i = g_preset < 0 ? (step > 0 ? 0 : n - 1) : ((g_preset + step) % n + n) % n;
    string path = path_join(PRESET_DIR, g_presets.items[i]);
    defer free(path);
    PatchLoad r = patch_io_load(g_patch, e, str_from(path.data, path.len));
    string msg = r.ok ? format("preset {}/{}: {} ({} cables)", i + 1, n, path_stem(g_presets.items[i]), r.cables)
                      : format("could not read {}", path);
    defer free(msg);
    ui_notice(g_ui, str_from(msg.data, msg.len));
    if r.ok {
        g_preset = i;
        set_current(e, "", path_stem(g_presets.items[i]));      // an untitled copy: SAVE asks where
    }
}

// ---- input ----

// MIDI note for a key on the two rows, or -1.
i32 note_for_key(i32 key) {
    for i32 i = 0; i < KEYS_LOWER.len; i++ {
        if cast(i32, KEYS_LOWER.data[i]) == key { return 48 + i; }
    }
    for i32 i = 0; i < KEYS_UPPER.len; i++ {
        if cast(i32, KEYS_UPPER.data[i]) == key { return 60 + i; }
    }
    return -1;
}

void on_event(sapp_event* ev) {
    Engine* e = g_engine;
    if e == null { return; }
    UiEvent u;
    u.x = ev.mouse_x;
    u.y = ev.mouse_y;
    u.key = cast(i32, ev.key_code);
    u.repeat = ev.key_repeat;
    u.time = stm_sec(stm_now());
    if (ev.modifiers & SAPP_MODIFIER_SHIFT) != 0 { u.mods |= UIM_SHIFT; }
    if (ev.modifiers & (SAPP_MODIFIER_CTRL | SAPP_MODIFIER_SUPER)) != 0 { u.mods |= UIM_CTRL; }
    if ev.mouse_button == SAPP_MOUSEBUTTON_RIGHT { u.button = UIB_RIGHT; }
    else if ev.mouse_button == SAPP_MOUSEBUTTON_MIDDLE { u.button = UIB_MIDDLE; }
    else { u.button = UIB_LEFT; }

    if ev.type == SAPP_EVENTTYPE_MOUSE_MOVE { u.type = UIE_MOVE; }
    else if ev.type == SAPP_EVENTTYPE_MOUSE_DOWN { u.type = UIE_DOWN; }
    else if ev.type == SAPP_EVENTTYPE_MOUSE_UP { u.type = UIE_UP; }
    else if ev.type == SAPP_EVENTTYPE_MOUSE_SCROLL {
        u.type = UIE_SCROLL;
        u.scroll = ev.scroll_y;
        u.scroll_x = ev.scroll_x;
        u.x = g_ui.mouse.x;
        u.y = g_ui.mouse.y;
    }
    else if ev.type == SAPP_EVENTTYPE_KEY_DOWN { u.type = UIE_KEY_DOWN; }
    else if ev.type == SAPP_EVENTTYPE_KEY_UP { u.type = UIE_KEY_UP; }
    else if ev.type == SAPP_EVENTTYPE_FILES_DROPPED {
        if sapp_get_num_dropped_files() > 0 {
            free(g_dropped);
            g_dropped = format("{}", str_from_cstr(sapp_get_dropped_file_path(0)));
        }
        return;
    }
    else { return; }

    bool used = ui_event(g_ui, g_patch, e, u);
    if g_ui.want_quality {
        g_ui.want_quality = false;
        start_switch();
    }
    if g_ui.want_panic {
        g_ui.want_panic = false;
        ignore engine_send_kind(e, CMD_PANIC, 0, 0, 0.0f);
    }
    if g_ui.want_preset != 0 {
        i32 step = g_ui.want_preset;
        g_ui.want_preset = 0;
        load_preset(e, step);
    }
    if used { return; }

    // Keys the UI left alone: the note rows, and Escape.
    if ev.type == SAPP_EVENTTYPE_KEY_DOWN && ev.key_code == SAPP_KEYCODE_ESCAPE {
        sapp_request_quit();
        return;
    }
    i32 note = note_for_key(u.key);
    if note < 0 { return; }
    if ev.type == SAPP_EVENTTYPE_KEY_DOWN && !ev.key_repeat {
        ignore engine_key_on(e, note);
        g_held[note] = true;
    }
    if ev.type == SAPP_EVENTTYPE_KEY_UP {
        ignore engine_key_off(e, note);
        g_held[note] = false;
    }
}

// ---- lifecycle ----

void init() {
    sg_setup(&sg_desc{ .environment = sglue_environment(), .logger = sg_logger{ .func = slog_func } });
    sgl_setup(&sgl_desc_t{ .max_vertices = 512 * 1024, .max_commands = 64 * 1024,
                           .logger = sgl_logger_t{ .func = slog_func } });
    if !text_setup(FONT_DIR, sapp_dpi_scale()) { eprint("no fonts in {}: using the pixel font\n", FONT_DIR); }
    ui_draw_setup();
    window_setup();
    stm_setup();
    g_start_ticks = stm_now();
    g_pass_action = sg_pass_action{
        .colors[0] = {
            .load_action = SG_LOADACTION_CLEAR,
            .clear_value = { C_BG.r, C_BG.g, C_BG.b, 1.0f }
        },
    };

    // The engine is built for the rate asked of the device; the device
    // opens after the first frame (start_audio), and one that runs at
    // another rate gets an engine of its own then.
    g_device_rate = cast(f32, AUDIO_RATE);
    Engine* e = engine_new_os(g_device_rate, quality_oversample(g_quality));
    rack_build(e);
    g_patch = new(Patch);
    patch_init(g_patch, e);
    patch_load_default(g_patch, e);
    set_current(e, "", "untitled");
    bool loaded = false;
    if path_exists(g_patch_path) {
        PatchLoad r = patch_io_load(g_patch, e, g_patch_path);
        if r.ok {
            set_current(e, g_patch_path, path_basename(g_patch_path));
            loaded = true;
        }
    }
    load_preset_list();
    g_ui = new(Ui);
    ui_init(g_ui, e, sapp_widthf(), sapp_heightf(), sapp_dpi_scale());
    when os(wasm) {
        if web_load(e, true) { loaded = true; }
    }
    // Nothing saved: the first preset, so every start is one PRESET reaches.
    if !loaded { load_preset(e, 1); }
    patch_clear_history(g_patch);                   // the starting state, not an edit
    if g_smoke_seconds > 0.0 {
        ignore engine_key_on(e, SMOKE_NOTE);
        g_held[SMOKE_NOTE] = true;
    }
    atomic_store(&g_engine, e, RELEASE);
}

void frame() {
    if !g_audio_started && sapp_frame_count() > 0 { start_audio(); }
    // The smoke run flips the quality halfway, to exercise the switch.
    f64 elapsed = stm_sec(stm_since(g_start_ticks));
    if g_smoke_seconds > 0.0 && !g_smoke_switched && elapsed >= g_smoke_seconds * 0.5 {
        g_smoke_switched = true;
        start_switch();
    }
    update_switch();
    Engine* e = g_engine;
    handle_file_requests(e);
    when !os(wasm) { update_dirty(e, elapsed); }
    if g_smoke_seconds > 0.0 && elapsed >= g_smoke_seconds { sapp_request_quit(); }

    // Peak hold: jumps up, decays slowly, so short spikes stay readable.
    f32 load = bits_f32(atomic_load(&g_load_bits, RELAXED));
    g_load_shown *= 0.98f;
    if load > g_load_shown { g_load_shown = load; }
    f32 peak = tele_out_peak(&e.tele);
    if elapsed > 1.0 {
        f64 ft = sapp_frame_duration();
        g_frame_sum += ft;
        if ft > g_frame_max { g_frame_max = ft; }
        g_frames++;
    }
    if peak > g_out_peak_max { g_out_peak_max = peak; }

    ui_resize(g_ui, sapp_widthf(), sapp_heightf(), sapp_dpi_scale());
    ui_draw_frame(g_ui, g_patch, e, UiStatus{ g_load_shown, g_audio_ok, g_switching, cast(f32, sapp_frame_duration()), &g_held[0],
                                          str_from(g_title.data, g_title.len), g_dirty });

    sg_swapchain sc = sglue_swapchain();
    sg_begin_pass(&sg_pass{ .action = g_pass_action, .swapchain = sc });
    sgl_draw();
    sg_end_pass();
    sg_commit();
    if g_shot_path.len > 0 && !g_shot_done && elapsed >= SHOT_AT_S {
        g_shot_done = true;
        bool ok = shot_save(g_shot_path, sc);
        print("shot: {} {}\n", g_shot_path, ok ? "saved" : "failed");
        if g_smoke_seconds == 0.0 { sapp_request_quit(); }
    }
}

void cleanup() {
    u32 callbacks = atomic_load(&g_callbacks);
    i32 rate = 0;
    i32 frames = 0;
    if g_audio_started {
        rate = saudio_sample_rate();
        frames = saudio_buffer_frames();
        saudio_shutdown();
    }
    text_shutdown();
    sgl_shutdown();
    sg_shutdown();
    Engine* e = g_engine;
    u32 resets = e.tele.nan_resets;
    i32 os = e.os;
    engine_free(e);
    if g_retired != null { engine_free(g_retired); }
    patch_free(g_patch);
    free(g_patch);
    free(g_ui);
    dir_list_free(&g_presets);
    free(g_file);
    free(g_title);
    free(g_saved_text);
    free(g_dropped);
    free(g_preset_index);
    if g_smoke_seconds > 0.0 {
        // A GUI build on Windows has no console; redirect stdout to see this.
        print("smoke: audio {} ({} Hz, {} frames), engine {}x, {} callbacks, peak load {}%, output peak {}, {} guard resets\n",
              g_audio_ok, rate, frames, os, callbacks, cast(f64, g_load_shown) * 100.0,
              cast(f64, g_out_peak_max), resets);
        if g_frames > 0 {
            print("frames: {} after the first second, {} ms average, {} ms worst, {} cables\n", g_frames,
                  g_frame_sum / cast(f64, g_frames) * 1000.0, g_frame_max * 1000.0, g_patch.n_cables);
        }
        if !g_audio_ok || callbacks == 0 { exit(3); }
        if g_out_peak_max < 0.01f { exit(4); }
        exit(0);
    }
}

// Non-negative integer, or -1.
i32 parse_count(str s) {
    if s.len == 0 { return -1; }
    i32 v = 0;
    for i32 i = 0; i < s.len; i++ {
        u8 c = s.data[i];
        if c < '0' || c > '9' { return -1; }
        v = v * 10 + cast(i32, c - '0');
    }
    return v;
}

void parse_args() {
    i32 argc = get_argc();
    for i32 i = 1; i + 1 < argc; i++ {
        str a = str_from_cstr(get_arg(i));
        str v = str_from_cstr(get_arg(i + 1));
        if str_equal(a, "--smoke") {
            i32 n = parse_count(v);
            if n > 0 { g_smoke_seconds = n; }
        } else if str_equal(a, "--quality") {
            if str_equal(v, "high") { g_quality = QUALITY_HIGH; }
            if str_equal(v, "normal") { g_quality = QUALITY_NORMAL; }
        } else if str_equal(a, "--shot") {
            g_shot_path = v;
        } else if str_equal(a, "--patch") {
            g_patch_path = v;
        }
    }
}

sapp_desc sokol_main() {
    parse_args();
    return sapp_desc{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = on_event,
        .width = 1600,
        .height = 900,
        .high_dpi = true,
        .maximized = true,
        .enable_dragndrop = true,
        .max_dropped_files = 1,
        .max_dropped_file_path_length = 4096,
        .sample_count = 4,
        .window_title = "minc-synth",
        .logger = sapp_logger{ .func = slog_func },
    };
}
