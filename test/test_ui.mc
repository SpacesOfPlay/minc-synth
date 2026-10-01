// test_ui.mc: layout, view, cable geometry, and gestures played as
// events against a real patch and engine.

import math;
import "util/check.mc";
import "util/rig.mc";

const f32 W = 1600.0f;
const f32 H = 900.0f;

void test_layout() {
    Engine* e = rig_new();
    defer engine_free(e);
    Layout* l = new(Layout);
    defer free(l);
    layout_build(l, e);
    bool apart = true;
    for i32 a = 0; a < l.n_modules; a++ {
        for i32 b = a + 1; b < l.n_modules; b++ {
            Rect ra = l.panels[a];
            Rect rb = l.panels[b];
            if ra.x < rb.x + rb.w && rb.x < ra.x + ra.w && ra.y < rb.y + rb.h && rb.y < ra.y + ra.h { apart = false; }
        }
    }
    check(apart, "panels don't overlap");
    bool inside = true;
    for i32 m = 0; m < e.n_modules; m++ {
        ModuleInfo* info = &e.modules[m];
        Rect r = l.panels[m];
        for i32 i = 0; i < info.desc.n_inputs; i++ { if !rect_contains(r, l.ins[info.base.jack0 + i]) { inside = false; } }
        for i32 i = 0; i < info.desc.n_outputs; i++ {
            if !rect_contains(r, l.outs[info.base.slot0 + i]) { inside = false; }
            if !rect_contains(l.out_bands[m], l.outs[info.base.slot0 + i]) { inside = false; }
        }
        for i32 i = 0; i < info.desc.n_params; i++ { if !rect_contains(r, l.knobs[info.base.param0 + i]) { inside = false; } }
    }
    check(inside, "every knob and jack sits on its own panel; outputs on the band");
    print("rack {} x {} units\n", cast(f64, l.width), cast(f64, l.height));
    check(l.width > 0.0f && l.height > 0.0f, "the rack has a size");
}

void test_view() {
    View v;
    view_init(&v, W, H);
    view_fit(&v, 1000.0f, 500.0f, 30.0f, 20.0f, 16.0f);
    float2 s = float2{ 321.0f, 456.0f };
    float2 back = view_to_screen(&v, view_to_rack(&v, s));
    check(fabsf(back.x - s.x) < 1e-3f && fabsf(back.y - s.y) < 1e-3f, "screen <-> rack round trip");
    float2 anchor = view_to_rack(&v, s);
    view_zoom_at(&v, s, 1.7f);
    float2 moved = view_to_screen(&v, anchor);
    check(fabsf(moved.x - s.x) < 1e-2f && fabsf(moved.y - s.y) < 1e-2f, "zoom keeps the point under the cursor");
    view_fit(&v, 1000.0f, 500.0f, 30.0f, 20.0f, 16.0f);
    float2 tl = view_to_screen(&v, float2{ 0.0f, 0.0f });
    float2 br = view_to_screen(&v, float2{ 1000.0f, 500.0f });
    check(tl.x >= 15.0f && tl.y >= 45.0f && br.x <= W - 15.0f && br.y <= H - 35.0f, "fit puts the rack in the window between the bar and the bottom row");
}

void test_cables() {
    CablePath c;
    float2 a = float2{ 100.0f, 100.0f };
    float2 b = float2{ 400.0f, 120.0f };
    cable_path(&c, a, b);
    check(point_distance(c.pts[0], a) < 1e-4f && point_distance(c.pts[CABLE_SEGS], b) < 1e-4f, "the cable ends at its plugs");
    check(c.pts[CABLE_SEGS / 2].y > 130.0f, "the cable sags below its ends");
    check(cable_distance(&c, c.pts[10]) < 1e-3f, "points on the cable are on it");
    check(cable_distance(&c, float2{ 250.0f, 20.0f }) > 50.0f, "points far off it are not");
}

// ---- gestures ----

struct Rig {
    Engine* e;
    Patch* p;
    Ui* ui;
    f64 t;
}

Rig rig_ui() {
    Rig r;
    r.e = rig_new();
    r.p = new(Patch);
    r.ui = new(Ui);
    patch_init(r.p, r.e);
    ui_init(r.ui, r.e, W, H, 1.0f);
    r.t = 1.0;
    return r;
}

void rig_ui_free(Rig* r) {
    patch_free(r.p);
    free(r.p);
    free(r.ui);
    engine_free(r.e);
}

void send(Rig* r, i32 type, float2 s, i32 button, u32 mods) {
    r.t += 0.5;                                   // far enough apart to never count as a double click
    UiEvent ev = UiEvent{ .type = type, .x = s.x, .y = s.y, .button = button, .mods = mods, .time = r.t };
    ignore ui_event(r.ui, r.p, r.e, ev);
}

void key(Rig* r, i32 k, u32 mods) {
    UiEvent ev = UiEvent{ .type = UIE_KEY_DOWN, .key = k, .mods = mods, .time = r.t };
    ignore ui_event(r.ui, r.p, r.e, ev);
}

// A left-button drag from a to b, through a midpoint.
void drag(Rig* r, float2 a, float2 b, u32 mods) {
    send(r, UIE_MOVE, a, 0, mods);
    send(r, UIE_DOWN, a, UIB_LEFT, mods);
    send(r, UIE_MOVE, (a + b) * 0.5f, 0, mods);
    send(r, UIE_MOVE, b, 0, mods);
    send(r, UIE_UP, b, UIB_LEFT, mods);
}

float2 out_s(Rig* r, str ref) { return view_to_screen(&r.ui.view, r.ui.layout.outs[engine_output_ref(r.e, ref)]); }
float2 in_s(Rig* r, str ref) { return view_to_screen(&r.ui.view, r.ui.layout.ins[engine_input_ref(r.e, ref)]); }
float2 knob_s(Rig* r, str ref) { return view_to_screen(&r.ui.view, r.ui.layout.knobs[engine_param_ref(r.e, ref)]); }

void test_patching_gestures() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    i32 saw = engine_output_ref(r.e, "osc.saw");
    i32 in1 = engine_input_ref(r.e, "lowpass.in1");
    i32 in2 = engine_input_ref(r.e, "lowpass.in2");

    // While the plug is in hand, the hover is the jack it would land on,
    // not the one it came from.
    send(&r, UIE_MOVE, out_s(&r, "osc.saw"), 0, 0);
    send(&r, UIE_DOWN, out_s(&r, "osc.saw"), UIB_LEFT, 0);
    send(&r, UIE_MOVE, in_s(&r, "lowpass.in1") + float2{ 3.0f, 2.0f }, 0, 0);
    check(r.ui.hover == HOVER_IN && r.ui.hover_index == in1, "dragging a cable, the hover is the input it would land on");
    send(&r, UIE_MOVE, float2{ 30.0f, 60.0f }, 0, 0);
    check(r.ui.hover == HOVER_NONE, "and nothing when it would land nowhere");
    send(&r, UIE_UP, float2{ 30.0f, 60.0f }, UIB_LEFT, 0);

    // Drop a few pixels off the jack: the plug snaps.
    drag(&r, out_s(&r, "osc.saw"), in_s(&r, "lowpass.in1") + float2{ 7.0f, -5.0f }, 0);
    check(patch_find(r.p, saw, in1) >= 0, "dragging output -> input makes a cable");
    ignore rig_run(r.e, 1);
    check(rig_jack(r.e, "lowpass.in1").n_src == 1, "the engine got the cable");

    drag(&r, in_s(&r, "lowpass.in1"), in_s(&r, "lowpass.in2"), 0);
    check(patch_find(r.p, saw, in2) >= 0 && patch_count_into(r.p, in1) == 0, "dragging an input plug moves it");

    drag(&r, in_s(&r, "lowpass.in2"), float2{ 20.0f, H - 20.0f }, 0);
    check(r.p.n_cables == 0, "dropping a plug on nothing deletes the cable");
    key(&r, 'Z', UIM_CTRL);
    check(patch_find(r.p, saw, in2) >= 0, "Ctrl+Z brings it back");
    key(&r, 'Y', UIM_CTRL);
    check(r.p.n_cables == 0, "Ctrl+Y deletes it again");
    key(&r, 'Z', UIM_CTRL);

    // Backwards: from an empty input to an output.
    drag(&r, in_s(&r, "amp1.in1"), out_s(&r, "lowpass.out"), 0);
    check(patch_find(r.p, engine_output_ref(r.e, "lowpass.out"), engine_input_ref(r.e, "amp1.in1")) >= 0,
          "dragging input -> output makes a cable too");

    // Right-click deletes; Shift-click recolours.
    i32 n = r.p.n_cables;
    send(&r, UIE_MOVE, in_s(&r, "amp1.in1"), 0, 0);
    send(&r, UIE_DOWN, in_s(&r, "amp1.in1"), UIB_RIGHT, 0);
    send(&r, UIE_UP, in_s(&r, "amp1.in1"), UIB_RIGHT, 0);
    check(r.p.n_cables == n - 1, "right-click on a jack deletes its cable");

    i32 c = patch_find(r.p, saw, in2);
    CablePath path;
    cable_path(&path, r.ui.layout.outs[saw], r.ui.layout.ins[in2]);
    float2 mid = view_to_screen(&r.ui.view, path.pts[CABLE_SEGS / 2]);
    i32 color = r.p.cables[c].color;
    send(&r, UIE_MOVE, mid, 0, UIM_SHIFT);
    check(r.ui.hover == HOVER_CABLE, "hovering a cable finds it");
    send(&r, UIE_DOWN, mid, UIB_LEFT, UIM_SHIFT);
    send(&r, UIE_UP, mid, UIB_LEFT, UIM_SHIFT);
    check(r.p.cables[c].color == (color + 1) % PATCH_COLORS, "Shift-click cycles the cable's colour");

    // A drag that ends away from any valid jack makes nothing.
    n = r.p.n_cables;
    drag(&r, out_s(&r, "osc.tri"), float2{ 30.0f, 60.0f }, 0);
    check(r.p.n_cables == n, "dropping a new cable on nothing makes nothing");
}

void test_vintage_snap() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    ui_toggle_profile(r.p, r.e);
    check(r.p.profile == PROFILE_VINTAGE, "F1 path switches to VINTAGE");
    drag(&r, out_s(&r, "keys.gate"), in_s(&r, "amp1.cv1"), 0);
    check(r.p.n_cables == 0, "VINTAGE: a trigger plug won't land on a signal input");
    drag(&r, out_s(&r, "keys.gate"), in_s(&r, "env1.retrig"), 0);
    check(r.p.n_cables == 1, "VINTAGE: it lands on a trigger input");
}

void test_knobs() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    i32 res = engine_param_ref(r.e, "lowpass.res");
    f32 start = r.p.params[res];
    float2 k = knob_s(&r, "lowpass.res");
    drag(&r, k, k + float2{ 100.0f, 0.0f }, 0);          // right by half the travel
    check(fabsf(r.p.params[res] - (start + 0.5f)) < 1e-4f, "dragging a knob right turns it up");
    check(r.p.n_undo == 1, "the drag is one undo step");
    drag(&r, k, k + float2{ 100.0f, 0.0f }, UIM_SHIFT);
    check(fabsf(r.p.params[res] - (start + 0.55f)) < 1e-4f, "Shift makes the drag fine");

    // The wheel over a knob turns it, one undo step until the cursor leaves.
    f32 at = r.p.params[res];
    i32 undo0 = r.p.n_undo;
    send(&r, UIE_MOVE, k, 0, 0);
    UiEvent w = UiEvent{ .type = UIE_SCROLL, .x = k.x, .y = k.y, .scroll = 1.0f };
    ignore ui_event(r.ui, r.p, r.e, w);
    ignore ui_event(r.ui, r.p, r.e, w);
    w.scroll = -1.0f;
    ignore ui_event(r.ui, r.p, r.e, w);
    check(fabsf(r.p.params[res] - (at + WHEEL_STEP)) < 1e-5f, "three wheel notches net one step up");
    check(r.p.n_undo == undo0, "not an undo step yet");
    f32 z = r.ui.view.zoom;
    send(&r, UIE_MOVE, k + float2{ 300.0f, 300.0f }, 0, 0);
    check(r.p.n_undo == undo0 + 1 && r.ui.view.zoom == z, "leaving the knob ends the step; the view did not zoom");
    check(patch_undo(r.p, r.e) && fabsf(r.p.params[res] - at) < 1e-6f, "undo returns the knob to before the wheel");

    // Double-click resets.
    send(&r, UIE_MOVE, k, 0, 0);
    UiEvent d1 = UiEvent{ .type = UIE_DOWN, .x = k.x, .y = k.y, .button = UIB_LEFT, .time = 100.0 };
    UiEvent u1 = UiEvent{ .type = UIE_UP, .x = k.x, .y = k.y, .button = UIB_LEFT, .time = 100.05 };
    UiEvent d2 = UiEvent{ .type = UIE_DOWN, .x = k.x, .y = k.y, .button = UIB_LEFT, .time = 100.2 };
    UiEvent u2 = UiEvent{ .type = UIE_UP, .x = k.x, .y = k.y, .button = UIB_LEFT, .time = 100.25 };
    ignore ui_event(r.ui, r.p, r.e, d1);
    ignore ui_event(r.ui, r.p, r.e, u1);
    ignore ui_event(r.ui, r.p, r.e, d2);
    ignore ui_event(r.ui, r.p, r.e, u2);
    check(fabsf(r.p.params[res] - r.p.defaults[res]) < 1e-6f, "double-click resets a knob");

    // A click on a switch picks the position under the cursor: one right
    // of the centre of the seven-position octave switch is +1.
    i32 oct = engine_param_ref(r.e, "osc.octave");
    f32 before = r.p.params[oct];
    float2 s = knob_s(&r, "osc.octave");
    float2 right = s + float2{ SWITCH_GAP * r.ui.view.zoom, 0.0f };
    send(&r, UIE_MOVE, right, 0, 0);
    send(&r, UIE_DOWN, right, UIB_LEFT, 0);
    send(&r, UIE_UP, right, UIB_LEFT, 0);
    check(fabsf(r.p.params[oct] - (before + 1.0f / 6.0f)) < 1e-5f, "clicking a switch picks the position under the cursor");
    send(&r, UIE_MOVE, right, 0, 0);
    send(&r, UIE_DOWN, right, UIB_LEFT, 0);
    send(&r, UIE_UP, right, UIB_LEFT, 0);
    check(fabsf(r.p.params[oct] - (before + 1.0f / 6.0f)) < 1e-5f, "clicking the same position again changes nothing");
    ignore rig_run(r.e, 1);
    check(param(&r.e.core, oct) == 1.0f, "the engine's octave went up one");
    UiEvent sw = UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll = -1.0f };
    ignore ui_event(r.ui, r.p, r.e, sw);
    check(fabsf(r.p.params[oct] - before) < 1e-5f, "the wheel steps a switch back");
    float2 edge = s + float2{ 9.0f * r.ui.view.zoom, 0.0f };
    send(&r, UIE_MOVE, edge, 0, 0);
    check(r.ui.hover == HOVER_KNOB && r.ui.hover_index == oct, "the switch's pill is its hit area");
    send(&r, UIE_MOVE, s, 0, 0);

    // A button is down while held and never an undo step.
    i32 undo = r.p.n_undo;
    float2 b = knob_s(&r, "gates.button1");
    send(&r, UIE_MOVE, b, 0, 0);
    send(&r, UIE_DOWN, b, UIB_LEFT, 0);
    ignore rig_run(r.e, 1);
    f32 held = rig_value(r.e, "gates.b1");
    send(&r, UIE_UP, b, UIB_LEFT, 0);
    ignore rig_run(r.e, 1);
    check(held == 1.0f && rig_value(r.e, "gates.b1") == 0.0f, "a button is on while held, off when let go");
    check(r.p.n_undo == undo, "pressing a button is not an undo step");
}

void test_view_gestures() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    float2 s = float2{ 800.0f, 450.0f };
    float2 anchor = view_to_rack(&r.ui.view, s);
    send(&r, UIE_MOVE, s, 0, 0);
    UiEvent wheel = UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll = 2.0f };
    ignore ui_event(r.ui, r.p, r.e, wheel);
    float2 moved = view_to_screen(&r.ui.view, anchor);
    check(fabsf(moved.x - s.x) < 0.5f && fabsf(moved.y - s.y) < 0.5f, "the wheel zooms about the cursor");

    // Drag on the background pans.
    float2 empty = float2{ W - 5.0f, H - 5.0f };
    float2 pan0 = r.ui.view.pan;
    drag(&r, empty, empty - float2{ 100.0f, 50.0f }, 0);
    float2 d = (r.ui.view.pan - pan0) * r.ui.view.zoom;
    check(fabsf(d.x - 100.0f) < 0.5f && fabsf(d.y - 50.0f) < 0.5f, "dragging the background pans");
    key(&r, 'F', 0);
    View fresh;
    view_init(&fresh, W, H);
    view_fit(&fresh, r.ui.layout.width, r.ui.layout.height, ui_top_height(r.ui), 0.0f, MARGIN_PX);
    check(r.ui.view.zoom == fresh.zoom && point_distance(r.ui.view.pan, fresh.pan) < 1e-3f, "F fits the rack again");
}

// Frames of 1/60 s: the engine runs a frame's worth, then the glow updates.
// Returns the brightest glow slot `s` reached, or the last when s < 0.
private f32 glow_frames(Ui* ui, Patch* p, Engine* e, i32 frames, i32 s) {
    f32 most = 0.0f;
    for i32 f = 0; f < frames; f++ {
        ignore rig_run(e, 800);
        ui_update_glow(ui, p, e, 1.0f / 60.0f);
        if s >= 0 && ui.glow[s] > most { most = ui.glow[s]; }
    }
    return most;
}

// The dimmest of the default cables' brightest glows over some frames.
private f32 glow_all_frames(Ui* ui, Patch* p, Engine* e, i32 frames) {
    f32[16] most;
    for i32 i = 0; i < p.n_cables; i++ { most[i] = 0.0f; }
    for i32 f = 0; f < frames; f++ {
        ignore rig_run(e, 800);
        ui_update_glow(ui, p, e, 1.0f / 60.0f);
        for i32 i = 0; i < p.n_cables; i++ {
            f32 g = ui.glow[p.cables[i].src];
            if g > most[i] { most[i] = g; }
        }
    }
    f32 dimmest = 1.0f;
    for i32 i = 0; i < p.n_cables; i++ { if most[i] < dimmest { dimmest = most[i]; } }
    return dimmest;
}

// Every cable of the default patch reacts to playing: a key lights them
// all, steady signals glow dimly enough that a change shows, a new note
// lights the oscillator's audio though its level stays the same, and the
// pitch cable lights on a change even to 0 V.
void test_glow() {
    Engine* e = engine_new_os(48000.0f, 2);
    defer engine_free(e);
    rack_build(e);
    Patch* p = new(Patch);
    defer free(p);
    Ui* ui = new(Ui);
    defer free(ui);
    patch_init(p, e);
    patch_load_default(p, e);
    ui_init(ui, e, W, H, 1.0f);
    i32 pitch = engine_output_ref(e, "keys.pitch");
    i32 saw = engine_output_ref(e, "osc.saw");

    // A note played and let go, then quiet: steady signals settle dim.
    ignore engine_key_on(e, 48);
    ignore glow_frames(ui, p, e, 10, -1);
    ignore engine_key_off(e, 48);
    ignore glow_frames(ui, p, e, 120, -1);
    f32 rest_pitch = ui.glow[pitch];
    f32 rest_saw = ui.glow[saw];
    print("at rest: pitch cable {}, saw cable {}\n", cast(f64, rest_pitch), cast(f64, rest_saw));
    check(rest_pitch <= GLOW_STEADY + 0.01f && rest_saw <= GLOW_STEADY + 0.01f,
          "steady signals glow dimly, leaving room for a change to show");

    // C1's period (31 ms) outlasts a frame's audio; its level still reads steady.
    ignore engine_key_on(e, 24);
    ignore glow_frames(ui, p, e, 120, -1);
    f32 bass_saw = glow_frames(ui, p, e, 60, saw);
    ignore engine_key_off(e, 24);
    ignore glow_frames(ui, p, e, 120, -1);
    print("C1 held: saw cable at most {}\n", cast(f64, bass_saw));
    check(bass_saw <= GLOW_STEADY + 0.01f, "a steady bass note reads steady, though its period outlasts a block");

    ignore engine_key_on(e, 50);
    f32 dimmest = glow_all_frames(ui, p, e, 12);
    print("key pressed: dimmest cable's brightest glow {}\n", cast(f64, dimmest));
    check(dimmest > 0.9f, "a key press lights every default cable");

    ignore glow_frames(ui, p, e, 120, -1);
    f32 held_saw = ui.glow[saw];
    ignore engine_key_on(e, 52);
    f32 new_saw = glow_frames(ui, p, e, 2, saw);
    f32 new_pitch = ui.glow[pitch];
    print("new note: saw cable {} -> {}, pitch cable {}\n", cast(f64, held_saw), cast(f64, new_saw), cast(f64, new_pitch));
    check(held_saw <= GLOW_STEADY + 0.01f, "a held note's audio settles dim");
    check(new_saw > 0.9f && new_pitch > 0.9f, "a new note lights the pitch cable and the oscillator's audio");

    // The same key again and again: nothing KEYS sends to the oscillator
    // changes, but each press still lights the pitch cable and the audio.
    ignore engine_key_off(e, 52);
    ignore engine_key_off(e, 50);
    ignore glow_frames(ui, p, e, 120, -1);
    f32 repeat_pitch = 1.0f;
    f32 repeat_saw = 1.0f;
    for i32 n = 0; n < 4; n++ {
        ignore engine_key_on(e, 52);
        f32 gs = glow_frames(ui, p, e, 1, saw);
        f32 gp = ui.glow[pitch];
        ignore glow_frames(ui, p, e, 10, -1);
        ignore engine_key_off(e, 52);
        ignore glow_frames(ui, p, e, 50, -1);
        if gs < repeat_saw { repeat_saw = gs; }
        if gp < repeat_pitch { repeat_pitch = gp; }
    }
    print("same key four times: dimmest press lit pitch {}, saw {}\n", cast(f64, repeat_pitch), cast(f64, repeat_saw));
    check(repeat_pitch > 0.9f && repeat_saw > 0.9f, "every press of the same key lights the pitch cable and the audio");

    ignore glow_frames(ui, p, e, 120, -1);
    patch_param_live(p, e, engine_param_ref(e, "osc.fine"), 0.6f);
    f32 turned = glow_frames(ui, p, e, 2, saw);
    check(turned > 0.9f, "turning a knob lights its module's outputs");
    ignore engine_key_off(e, 52);
    ignore engine_key_off(e, 50);

    // Hold C4, where pitch is exactly 0 V, until its glow fades; then go
    // to B3 (below, so low-note priority plays it) and back. The return
    // to 0 V lights the cable by the change.
    ignore engine_key_on(e, 60);
    ignore glow_frames(ui, p, e, 120, -1);
    f32 settled = ui.glow[pitch];
    ignore engine_key_on(e, 59);
    ignore glow_frames(ui, p, e, 60, -1);
    ignore engine_key_off(e, 59);
    f32 back = glow_frames(ui, p, e, 1, pitch);
    print("pitch cable at a steady 0 V: {}; back to 0 V from B3: {}\n", cast(f64, settled), cast(f64, back));
    check(settled < 0.05f, "a steady 0 V pitch lets the cable go dark");
    check(back > 0.9f, "a change of note lights the pitch cable, even to 0 V");
    patch_free(p);
}

// The bar, the status row, the help window and the fitted rack keep
// clear of each other at common dpi scales, in wide, narrow and short
// windows.
void test_overlays() {
    Engine* e = rig_new();
    defer engine_free(e);
    Ui* ui = new(Ui);
    defer free(ui);
    f32[4] dpis = { 1.0f, 1.25f, 1.5f, 2.0f };
    f32[3] widths = { W, 1000.0f, 1280.0f };
    f32[3] heights = { H, H, 700.0f };
    bool scale_ok = true;
    bool status_clear = true;
    bool buttons_inside = true;
    bool help_inside = true;
    bool rack_clear = true;
    for i32 d = 0; d < 4; d++ {
        for i32 k = 0; k < 3; k++ {
            f32 dpi = dpis[d];
            f32 w = widths[k] * dpi;
            f32 h = heights[k] * dpi;
            ui_init(ui, e, w, h, dpi);
            f32 px = ui.text_px;
            f32 cw = TEXT_EM * px;
            if fabsf(px - TEXT_PX * dpi) > 0.5f { scale_ok = false; }

            // The longest status: "cpu 100%  256 cables".
            float2 s = ui_status_pos(ui, 20);
            Rect sr = Rect{ s.x, s.y - 0.5f * px, 20.0f * cw, px };
            if sr.x < px || sr.y < ui_bar_height(ui) || sr.y + sr.h > ui_top_height(ui) { status_clear = false; }
            for i32 b = 0; b < BAR_COUNT; b++ {
                Rect br = ui.buttons[b];
                if sr.x < br.x + br.w && br.x < sr.x + sr.w && sr.y < br.y + br.h && br.y < sr.y + sr.h { status_clear = false; }
            }

            Rect last = ui.buttons[BAR_COUNT - 1];
            if last.x + last.w > w - px { buttons_inside = false; }

            HelpLayout hl = ui_help_layout(ui);
            Rect hb = hl.box;
            if hb.x < 0.0f || hb.x + hb.w > w || hb.y < ui_bar_height(ui) || hb.y + hb.h > h { help_inside = false; }
            f32 bottom = hl.top + (ui_help_rows() - 2.0f) * hl.row;
            if bottom > hb.y + hb.h || hl.row < px { help_inside = false; }

            float2 tl = view_to_screen(&ui.view, float2{ 0.0f, 0.0f });
            float2 br = view_to_screen(&ui.view, float2{ ui.layout.width, ui.layout.height });
            if tl.y < ui_top_height(ui) || br.y > h || tl.x < 0.0f || br.x > w { rack_clear = false; }
        }
    }
    check(scale_ok, "screen text scales with the dpi");
    check(status_clear, "the status sits on its own row, right-aligned, clear of the buttons");
    check(buttons_inside, "every bar button fits the window");
    check(help_inside, "the help window and all its rows fit below the bar");
    check(rack_clear, "the fitted rack stays clear of the status row");
}

// PRESET asks main for the next preset; with Shift, the previous one.
void test_preset_button() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    Rect b = r.ui.buttons[BAR_PRESET];
    float2 button = float2{ b.x + 0.5f * b.w, b.y + 0.5f * b.h };
    send(&r, UIE_MOVE, button, 0, 0);
    send(&r, UIE_DOWN, button, UIB_LEFT, 0);
    send(&r, UIE_UP, button, UIB_LEFT, 0);
    check(r.ui.want_preset == 1, "PRESET asks for the next preset");
    r.ui.want_preset = 0;
    send(&r, UIE_DOWN, button, UIB_LEFT, UIM_SHIFT);
    send(&r, UIE_UP, button, UIB_LEFT, UIM_SHIFT);
    check(r.ui.want_preset == -1, "Shift + PRESET asks for the previous one");
}

// The HELP button opens the help window; Esc, a click outside it, or the
// button again close it. While it's open the rack behind takes no clicks
// or wheel turns, and Esc goes to the window, not to quitting.
void test_help() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    Rect b = r.ui.buttons[BAR_HELP];
    float2 button = float2{ b.x + 0.5f * b.w, b.y + 0.5f * b.h };
    send(&r, UIE_MOVE, button, 0, 0);
    send(&r, UIE_DOWN, button, UIB_LEFT, 0);
    send(&r, UIE_UP, button, UIB_LEFT, 0);
    check(r.ui.help_open, "the HELP button opens the help window");

    Rect box = ui_help_layout(r.ui).box;
    float2 inside = float2{ box.x + 0.5f * box.w, box.y + 0.5f * box.h };
    i32 undo = r.p.n_undo;
    f32 zoom = r.ui.view.zoom;
    send(&r, UIE_MOVE, inside, 0, 0);
    send(&r, UIE_DOWN, inside, UIB_LEFT, 0);
    send(&r, UIE_UP, inside, UIB_LEFT, 0);
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = inside.x, .y = inside.y, .scroll = 1.0f, .time = r.t });
    check(r.ui.help_open && r.ui.hover == HOVER_NONE, "a click inside keeps it open; nothing behind is hovered");
    check(r.p.n_undo == undo && r.ui.view.zoom == zoom, "the rack behind takes no clicks or wheel turns");

    bool used = ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_KEY_DOWN, .key = UIK_ESCAPE, .time = r.t });
    check(used && !r.ui.help_open, "Esc closes the help window, and doesn't reach the app");
    used = ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_KEY_DOWN, .key = UIK_ESCAPE, .time = r.t });
    check(!used, "with help closed, Esc goes on to the app (which quits)");

    send(&r, UIE_DOWN, button, UIB_LEFT, 0);
    send(&r, UIE_UP, button, UIB_LEFT, 0);
    float2 outside = float2{ 0.5f * box.x, box.y + 0.5f * box.h };
    send(&r, UIE_MOVE, outside, 0, 0);
    send(&r, UIE_DOWN, outside, UIB_LEFT, 0);
    send(&r, UIE_UP, outside, UIB_LEFT, 0);
    check(!r.ui.help_open && r.ui.drag == DRAG_NONE, "a click outside closes it, and does nothing else");

    send(&r, UIE_DOWN, button, UIB_LEFT, 0);
    send(&r, UIE_UP, button, UIB_LEFT, 0);
    send(&r, UIE_DOWN, button, UIB_LEFT, 0);
    send(&r, UIE_UP, button, UIB_LEFT, 0);
    check(!r.ui.help_open, "the button closes it again");
}

// A new cable drops in as a rope, swings, and comes to rest where it
// hangs; the hit test follows it there.
void test_rope() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    i32 saw = engine_output_ref(r.e, "osc.saw");
    i32 in4 = engine_input_ref(r.e, "mix2.in4");
    ignore patch_connect(r.p, r.e, saw, in4);
    i32 i = patch_find(r.p, saw, in4);
    float2 a = r.ui.layout.outs[saw];
    float2 b = r.ui.layout.ins[in4];
    CablePath bez;
    cable_path(&bez, a, b);
    CablePath shape;
    ui_update_ropes(r.ui, r.p, 1.0f / 60.0f);
    check(ui_cable_shape(r.ui, r.p, i, &shape), "a new cable is in motion");
    f32 dev = 0.0f;
    for i32 k = 0; k <= CABLE_SEGS; k++ { if cable_distance(&bez, shape.pts[k]) > dev { dev = cable_distance(&bez, shape.pts[k]); } }
    check(dev > 5.0f, "it starts well off the Bezier");
    check(point_distance(shape.pts[0], a) < 1e-3f && point_distance(shape.pts[CABLE_SEGS], b) < 1e-3f, "its ends stay on the plugs");

    for i32 f = 0; f < 48; f++ { ui_update_ropes(r.ui, r.p, 1.0f / 60.0f); }
    check(ui_cable_shape(r.ui, r.p, i, &shape), "still in motion at 0.8 s");
    dev = 0.0f;
    for i32 k = 0; k <= CABLE_SEGS; k++ { if cable_distance(&bez, shape.pts[k]) > dev { dev = cable_distance(&bez, shape.pts[k]); } }
    f32 len = 0.0f;
    for i32 k = 0; k < ROPE_N - 1; k++ { len += point_distance(r.ui.ropes[i].p[k], r.ui.ropes[i].p[k + 1]); }
    f32 rest = r.ui.ropes[i].rest * cast(f32, ROPE_N - 1);
    print("rope at 0.8 s: {} units from the Bezier, length {} of {}\n", cast(f64, dev), cast(f64, len), cast(f64, rest));
    check(dev < 60.0f, "by then it hangs near the Bezier, its own way");
    check(fabsf(len / rest - 1.0f) < 0.01f, "at its rest length within 1 %");

    for i32 f = 0; f < 40; f++ { ui_update_ropes(r.ui, r.p, 1.0f / 60.0f); }
    check(!ui_cable_shape(r.ui, r.p, i, &shape), "after 1.5 s it is at rest");
    CablePath again;
    ui_update_ropes(r.ui, r.p, 1.0f / 60.0f);
    ignore ui_cable_shape(r.ui, r.p, i, &again);
    dev = 0.0f;
    for i32 k = 0; k <= CABLE_SEGS; k++ { if point_distance(shape.pts[k], again.pts[k]) > dev { dev = point_distance(shape.pts[k], again.pts[k]); } }
    check(dev < 1e-4f, "and it holds still");
    check(ui_cable_at(r.ui, r.p, shape.pts[CABLE_SEGS / 2]) == i, "the hit test follows the rope");

    // A change at its source sends a pulse down it, once. The engine has to
    // have run for the source to carry signal.
    ignore rig_run(r.e, 4800);
    ui_update_glow(r.ui, r.p, r.e, 1.0f / 60.0f);
    ui_update_ropes(r.ui, r.p, 1.0f / 60.0f);
    ignore patch_set_param(r.p, r.e, engine_param_ref(r.e, "osc.fine"), 0.7f);
    ui_update_glow(r.ui, r.p, r.e, 1.0f / 60.0f);
    ui_update_ropes(r.ui, r.p, 1.0f / 60.0f);
    check(r.ui.pulse[i] >= 0.0f && r.ui.pulse[i] < 0.1f, "turning a knob on OSC starts a pulse on its cable");
    for i32 f = 0; f < 30; f++ {
        ui_update_glow(r.ui, r.p, r.e, 1.0f / 60.0f);
        ui_update_ropes(r.ui, r.p, 1.0f / 60.0f);
    }
    check(r.ui.pulse[i] < 0.0f, "half a second on, the pulse has passed");

    // Removing another cable does not disturb it.
    i32 tri = engine_output_ref(r.e, "osc.tri");
    i32 in3 = engine_input_ref(r.e, "mix2.in3");
    ignore patch_connect(r.p, r.e, tri, in3);
    ui_update_ropes(r.ui, r.p, 1.0f / 60.0f);
    check(ui_cable_shape(r.ui, r.p, patch_find(r.p, tri, in3), &shape), "the second cable is in motion");
    ignore patch_remove(r.p, r.e, patch_find(r.p, tri, in3));
    ui_update_ropes(r.ui, r.p, 1.0f / 60.0f);
    i32 j = patch_find(r.p, saw, in4);
    check(j >= 0 && !ui_cable_shape(r.ui, r.p, j, &shape), "a cable at rest stays at rest when the list shifts");
}

// The file and preset shortcuts hand main a request rather than acting.
void test_file_keys() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    key(&r, 'S', UIM_CTRL);
    check(r.ui.want_save && !r.ui.want_load, "Ctrl+S asks for a save");
    r.ui.want_save = false;
    key(&r, 'O', UIM_CTRL);
    check(r.ui.want_load, "Ctrl+O asks for a load");
    key(&r, UIK_RBRACKET, 0);
    check(r.ui.want_preset == 1, "] asks for the next preset");
    key(&r, UIK_LBRACKET, 0);
    check(r.ui.want_preset == -1, "[ asks for the previous one");
    i32 cables = r.p.n_cables;
    key(&r, 'S', 0);
    check(r.p.n_cables == cables && !r.ui.want_save, "a plain S is a note, not a save");
}

// A mouse wheel zooms, or turns the control under it; a touchpad pans,
// sideways too, and never turns what slides under the cursor; Ctrl +
// scroll (a pinch) zooms; the arrow keys move the view.
void test_scroll_and_arrows() {
    Rig r = rig_ui();
    defer rig_ui_free(&r);
    float2 s = float2{ 5.0f, H - 5.0f };                  // the background, left of the rack
    send(&r, UIE_MOVE, s, 0, 0);
    f32 zoom = r.ui.view.zoom;
    float2 pan0 = r.ui.view.pan;
    r.t += 1.0;
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll = 0.25f, .time = r.t });
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll_x = -0.5f, .time = r.t + 0.02 });
    float2 d = (r.ui.view.pan - pan0) * r.ui.view.zoom;
    check(r.ui.view.zoom == zoom, "a touchpad doesn't zoom");
    check(fabsf(d.x - 0.5f * SCROLL_PAN_PX) < 1e-3f && fabsf(d.y + 0.25f * SCROLL_PAN_PX) < 1e-3f,
          "a touchpad pans, up and down and sideways");
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll = 1.0f, .time = r.t + 0.04 });
    check(r.ui.view.zoom == zoom, "a flick reaching a notch's size within the gesture still pans");

    // A scroll that starts on a knob, up or down, turns it; the view stays.
    i32 res = engine_param_ref(r.e, "lowpass.res");
    float2 k = knob_s(&r, "lowpass.res");
    send(&r, UIE_MOVE, k, 0, 0);
    f32 before = r.p.params[res];
    pan0 = r.ui.view.pan;
    r.t += 1.0;
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = k.x, .y = k.y, .scroll = 0.3f, .time = r.t });
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = k.x, .y = k.y, .scroll = 0.2f, .time = r.t + 0.02 });
    check(fabsf(r.p.params[res] - (before + 0.5f * WHEEL_STEP)) < 1e-5f && point_distance(r.ui.view.pan, pan0) == 0.0f,
          "a touchpad scroll that starts on a knob turns it, and the view stays");

    // A sideways scroll that starts on a knob pans.
    before = r.p.params[res];
    r.t += 1.0;
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = k.x, .y = k.y, .scroll_x = 0.4f, .scroll = 0.1f, .time = r.t });
    check(r.p.params[res] == before && r.ui.view.pan.x != pan0.x, "a sideways scroll that starts on a knob pans");

    // A pan started beside a knob slides the knob under the still cursor,
    // and goes on panning without turning it.
    key(&r, 'F', 0);
    k = knob_s(&r, "lowpass.res");
    float2 c = k + float2{ 0.0f, 20.0f };                 // below the knob, off it
    send(&r, UIE_MOVE, c, 0, 0);
    check(r.ui.hover != HOVER_KNOB, "the cursor starts beside the knob");
    before = r.p.params[res];
    r.t += 1.0;
    // The scroll that pans those 20 px, in touchpad-sized events: a first
    // event of a notch or more reads as a wheel, and would zoom.
    f32 left = 20.0f / SCROLL_PAN_PX;
    while left > 0.0f {
        f32 part = left < 0.9f ? left : 0.9f;
        ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = c.x, .y = c.y, .scroll = part, .time = r.t });
        left -= part;
        r.t += 0.02;
    }
    check(r.ui.hover == HOVER_KNOB && r.ui.hover_index == res, "the pan brings the knob under the cursor");
    pan0 = r.ui.view.pan;
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = c.x, .y = c.y, .scroll = 0.3f, .time = r.t + 0.02 });
    check(r.p.params[res] == before && r.ui.view.pan.y != pan0.y, "a pan that reaches a knob goes on panning");
    // Moving the pointer ends the gesture: a scroll there now turns the knob.
    send(&r, UIE_MOVE, view_to_screen(&r.ui.view, r.ui.layout.knobs[res]), 0, 0);
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = c.x, .y = c.y, .scroll = 0.5f, .time = r.t + 0.04 });
    check(r.p.params[res] > before, "after the pointer moves, a new scroll on the knob turns it");

    // On a switch, a touchpad's small steps add up to one position a notch.
    key(&r, 'F', 0);
    i32 oct = engine_param_ref(r.e, "osc.octave");
    float2 sw = knob_s(&r, "osc.octave");
    send(&r, UIE_MOVE, sw, 0, 0);
    f32 oct0 = r.p.params[oct];
    r.t += 1.0;
    for i32 i = 0; i < 3; i++ {
        ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = sw.x, .y = sw.y, .scroll = 0.3f, .time = r.t + 0.02 * cast(f64, i) });
    }
    check(r.p.params[oct] == oct0, "a switch holds until the scroll adds up to a notch");
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = sw.x, .y = sw.y, .scroll = 0.3f, .time = r.t + 0.06 });
    check(fabsf(r.p.params[oct] - (oct0 + 1.0f / 6.0f)) < 1e-5f, "then it moves one position");

    // A wheel notch, a new gesture: zooms at the cursor.
    key(&r, 'F', 0);
    send(&r, UIE_MOVE, s, 0, 0);
    zoom = r.ui.view.zoom;
    r.t += 1.0;
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll = 1.0f, .time = r.t });
    check(r.ui.view.zoom > zoom, "a wheel notch zooms");
    zoom = r.ui.view.zoom;
    r.t += 1.0;
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll = -0.2f, .mods = UIM_CTRL, .time = r.t });
    check(fabsf(r.ui.view.zoom / zoom - exp2_fast(-0.05f)) < 1e-4f, "Ctrl + small steps (a pinch) zoom smoothly");

    // Arrows: the view moves a tenth of the window, Shift four times that,
    // again while a key is held.
    key(&r, 'F', 0);
    pan0 = r.ui.view.pan;
    f32 z = r.ui.view.zoom;
    key(&r, UIK_LEFT, 0);
    check(fabsf((r.ui.view.pan.x - pan0.x) * z + 0.1f * W) < 1e-2f, "Left moves the view left");
    key(&r, UIK_RIGHT, 0);
    check(fabsf(r.ui.view.pan.x - pan0.x) * z < 1e-2f, "Right moves it back");
    key(&r, UIK_DOWN, UIM_SHIFT);
    check(fabsf((r.ui.view.pan.y - pan0.y) * z - 0.4f * H) < 1e-2f, "Shift + Down moves it down by four steps");
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_KEY_DOWN, .key = UIK_UP, .repeat = true, .time = r.t });
    check(fabsf((r.ui.view.pan.y - pan0.y) * z - 0.3f * H) < 1e-2f, "a held Up keeps moving it up");

    // A pinch (Ctrl + scroll) zooms, and a two-finger scroll right after
    // it pans rather than going on zooming.
    send(&r, UIE_MOVE, s, 0, 0);
    zoom = r.ui.view.zoom;
    r.t += 1.0;
    for i32 i = 0; i < 5; i++ {
        ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll = 0.16f, .mods = UIM_CTRL, .time = r.t + 0.01 * cast(f64, i) });
    }
    check(r.ui.view.zoom > zoom, "a pinch zooms");
    zoom = r.ui.view.zoom;
    pan0 = r.ui.view.pan;
    ignore ui_event(r.ui, r.p, r.e, UiEvent{ .type = UIE_SCROLL, .x = s.x, .y = s.y, .scroll = 0.3f, .time = r.t + 0.06 });
    check(r.ui.view.zoom == zoom && r.ui.view.pan.y != pan0.y, "a two-finger scroll right after a pinch pans");
}

private f64 srgb_linear(f32 c) {
    if c <= 0.04045f { return cast(f64, c) / 12.92; }
    return pow((cast(f64, c) + 0.055) / 1.055, 2.4);
}

private f64 luminance(float3 c) { return 0.2126 * srgb_linear(c.r) + 0.7152 * srgb_linear(c.g) + 0.0722 * srgb_linear(c.b); }

// No cable colour is brighter than a 50 % grey; there's a black, and it
// gets an edge that shows on the dark panels.
void test_cable_colours() {
    f64 grey = luminance(float3{ 0.5f, 0.5f, 0.5f });
    f64 brightest = 0.0;
    i32 black = -1;
    for i32 i = 0; i < PATCH_COLORS; i++ {
        float3 c = CABLE_COLORS[i];
        if luminance(c) > brightest { brightest = luminance(c); }
        if fmaxf(c.r, fmaxf(c.g, c.b)) < 0.15f { black = i; }
    }
    print("brightest cable colour: luminance {} (50 % grey: {})\n", brightest, grey);
    check(brightest <= grey + 1e-4, "no cable colour is brighter than a 50 % grey");
    check(black >= 0, "one cable colour is black");
    float3 edge = cable_edge(CABLE_COLORS[black], CABLE_EDGE_MIN);
    check(fmaxf(edge.r, fmaxf(edge.g, edge.b)) >= CABLE_EDGE_MIN - 1e-4f, "the black cable gets a lighter edge");
    float3 red = CABLE_COLORS[0];
    float3 red_edge = cable_edge(red, CABLE_EDGE_MIN);
    check(red_edge.r == red.r && red_edge.g == red.g, "brighter cables are their own edge");
}

i32 main() {
    test_rope();
    test_file_keys();
    test_overlays();
    test_preset_button();
    test_help();
    test_scroll_and_arrows();
    test_cable_colours();
    test_glow();
    test_layout();
    test_view();
    test_cables();
    test_patching_gestures();
    test_vintage_snap();
    test_knobs();
    test_view_gestures();
    return check_done();
}
