// ui_state.mc: what the mouse and keys do to the rack.
//
// Hover, knob drags, cable drags with snapping, pan and zoom, undo and
// redo, and the bar's buttons. It works on plain events rather than
// sokol's, so tests can play gestures against a real patch and engine.
//
// Mouse:  drag from an output: new cable; from an input: move its cable
//         (or start one backwards); Ctrl-drag from an output: move its
//         newest cable's output plug; drag a cable's body: move the nearer
//         plug; drop on nothing: delete. Right-click a cable or a jack:
//         delete. Shift-click a cable: next colour. Knobs: drag left and
//         right, or the wheel over them, Shift for fine, double-click to
//         reset; switches: click the position, or the wheel. Background,
//         middle button or Space: pan. Wheel elsewhere: zoom.
// Keys:   Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo, F fit, Tab cable
//         visibility, L focus the hovered module's cables, Delete the
//         hovered cable, F1 profile, F2 plugging feel, F3 quality, P panic,
//         Ctrl+S save the patch file, Ctrl+O load it, [ and ] the previous
//         and next preset.
//         Letters on the two note rows play KEYS; main.mc handles those.

import math;
import dsp_math;
import profile;
import engine_core;
import engine_cmd;
import engine;
import patch;
import ui_layout;
import ui_view;
import ui_cables;

enum UiEvType { UIE_DOWN, UIE_UP, UIE_MOVE, UIE_SCROLL, UIE_KEY_DOWN, UIE_KEY_UP }
enum UiButton { UIB_LEFT, UIB_RIGHT, UIB_MIDDLE }
const u32 UIM_SHIFT = 1;
const u32 UIM_CTRL = 2;

// Key codes as sokol_app numbers them: letters are ASCII.
const i32 UIK_SPACE = 32;
const i32 UIK_TAB = 258;
const i32 UIK_BACKSPACE = 259;
const i32 UIK_DELETE = 261;
const i32 UIK_F1 = 290;
const i32 UIK_F2 = 291;
const i32 UIK_F3 = 292;
const i32 UIK_LBRACKET = 91;
const i32 UIK_RBRACKET = 93;
const i32 UIK_RIGHT = 262;
const i32 UIK_LEFT = 263;
const i32 UIK_DOWN = 264;
const i32 UIK_UP = 265;

struct UiEvent {
    i32 type;
    f32 x;                              // screen pixels
    f32 y;
    i32 button;
    u32 mods;
    f32 scroll;                         // up is positive; a mouse wheel notch is 1
    f32 scroll_x;                       // left is positive
    i32 key;
    bool repeat;
    f64 time;                           // seconds
}

enum Hover { HOVER_NONE, HOVER_IN, HOVER_OUT, HOVER_KNOB, HOVER_CABLE, HOVER_BUTTON }
enum DragMode { DRAG_NONE, DRAG_PAN, DRAG_KNOB, DRAG_BUTTON, DRAG_FROM_OUT, DRAG_FROM_IN, DRAG_MOVE_DST, DRAG_MOVE_SRC }
enum BarButton { BAR_PROFILE, BAR_FEEL, BAR_QUALITY, BAR_UNDO, BAR_REDO, BAR_FIT, BAR_SAVE, BAR_LOAD, BAR_PRESET, BAR_HELP }
enum CableVis { VIS_OPAQUE, VIS_TRANSLUCENT, VIS_HIDDEN }
enum ScrollMode { SCROLL_PAN, SCROLL_ZOOM, SCROLL_TURN }

const i32 BAR_COUNT = 10;
const i32 UIK_ESCAPE = 256;
const f32 BAR_H = 32.0f;                // top bar, pixels at dpi 1
const f32 TEXT_PX = 13.0f;              // overlay text size, pixels at dpi 1
const f32 TEXT_EM = 0.5f;               // an average glyph's width as a fraction of the size, for layout
const f32 TEXT_EM_UPPER = 0.7f;         // the same for uppercase labels
const f32 SNAP_PX = 24.0f;              // snapping reach, pixels at dpi 1
const f32 KNOB_DRAG_PX = 200.0f;        // full knob travel, pixels at dpi 1
const f32 FINE = 0.1f;
const f32 WHEEL_STEP = 0.02f;           // of a knob's travel per wheel notch
const f64 DOUBLE_CLICK_S = 0.35;
const f32 MARGIN_PX = 16.0f;
const f64 SCROLL_LATCH_S = 0.3;         // a scroll gesture keeps its kind this long between events
const f32 ARROW_STEP = 0.1f;            // an arrow key pans this share of the window; Shift, four times it

// Pixels (at dpi 1) a touchpad scroll of 1 moves the view. sokol_app
// reports a macOS touchpad in points times 0.1; elsewhere a unit is a
// wheel notch's worth, about 100 pixels (a browser reports pixels / 100).
when os(macos) {
    const f32 SCROLL_PAN_PX = 10.0f;
} else {
    const f32 SCROLL_PAN_PX = 100.0f;
}

// The help window: what each key and gesture does, under headings (a
// row with no key).
struct HelpRow {
    str key;
    str what;
}

// A row keyed HELP_PIANO is the keyboard drawn over HELP_PIANO_ROWS rows.
const str HELP_PIANO = "@piano";
const i32 HELP_PIANO_ROWS = 2;          // what the two text rows took, so the window keeps its height
const f32 HELP_PIANO_FILL = 0.85f;      // of its rows the piano covers

const i32 HELP_ROWS_N = 30;
HelpRow[30] HELP_ROWS = {
    HelpRow{ "", "PATCHING" },
    HelpRow{ "drag from a jack", "patch a cable; the jacks it can go to light up" },
    HelpRow{ "drag a plug", "move that end of the cable" },
    HelpRow{ "Ctrl + drag from an output", "move the source of its newest cable" },
    HelpRow{ "right-click, double-click, Delete", "remove a cable" },
    HelpRow{ "Shift + click a cable", "change its colour" },
    HelpRow{ "Tab", "cables solid, see-through or hidden" },
    HelpRow{ "L", "focus: the cables of the module under the cursor on top" },
    HelpRow{ "", "CONTROLS" },
    HelpRow{ "drag sideways", "turn a knob; Shift for fine" },
    HelpRow{ "scroll up or down on a control", "turn it; Shift for fine (a wheel or two fingers)" },
    HelpRow{ "double-click", "back to the default" },
    HelpRow{ "click a switch", "the position under the cursor" },
    HelpRow{ "hold a button", "on while held" },
    HelpRow{ "", "VIEW" },
    HelpRow{ "wheel", "zoom at the cursor" },
    HelpRow{ "two fingers on a touchpad", "pan, unless the scroll starts on a control; pinch or Ctrl + scroll to zoom" },
    HelpRow{ "arrow keys", "pan; Shift for bigger steps" },
    HelpRow{ "drag the background", "pan; also the middle button, or Space + drag" },
    HelpRow{ "F", "fit the rack to the window" },
    HelpRow{ "", "PLAYING" },
    HelpRow{ "@piano", "C3 to C5; the comma key is C4 too" },
    HelpRow{ "P", "panic: silence and reset every module" },
    HelpRow{ "", "PATCH" },
    HelpRow{ "Ctrl + Z, Ctrl + Y", "undo, redo" },
    HelpRow{ "Ctrl + S (+ Shift), Ctrl + O", "save in place (save as, like SAVE), open; or drop a file" },
    HelpRow{ "[  ]", "previous, next preset; also PRESET, Shift + click for the previous" },
    HelpRow{ "F1, F2, F3", "profile, plugging feel, quality" },
    HelpRow{ "", "WINDOW" },
    HelpRow{ "Esc", "quit, when this help is closed" },
};

// Where the help window's parts sit, in screen pixels.
struct HelpLayout {
    Rect box;
    f32 key_x;                          // the key column's left edge
    f32 what_x;                         // the description column's left edge
    f32 top;                            // the first row's middle line
    f32 row;                            // row height
}

struct Ui {
    View view;
    Layout layout;
    f32 dpi;
    float2 mouse;                       // screen pixels
    u32 mods;
    i32 hover;                          // Hover
    i32 hover_index;                    // jack, slot, param, cable or button
    i32 drag;                           // DragMode
    float2 drag_mouse0;
    float2 drag_pan0;
    i32 knob;
    f32 knob_norm0;
    i32 wheel_knob;                     // the knob the wheel is turning, or -1; one undo step until the cursor leaves
    f32 wheel_norm0;
    f64 scroll_time;                    // the last scroll event
    i32 scroll_mode;                    // ScrollMode of the gesture it belongs to
    i32 scroll_knob;                    // SCROLL_TURN: the control it turns
    f32 scroll_accum;                   // SCROLL_TURN on a switch: notches not yet stepped
    i32 fixed;                          // FROM_OUT: slot; FROM_IN: jack; MOVE_*: cable
    float2 loose;                       // the plug in hand, virtual
    i32 snap;                           // the jack or slot it would land on, or -1
    bool space;
    i32 cable_vis;                      // CableVis
    bool focus;
    f64 last_click;
    float2 last_click_pos;
    bool want_quality;                  // the bar asked for a quality switch; main does it
    bool want_panic;
    bool want_save;                     // Ctrl+S or the bar: main writes the patch file
    bool want_save_as;                  // Ctrl+Shift+S or the SAVE button: main asks where first
    bool want_load;                     // Ctrl+O or the bar: main reads it
    i32 want_preset;                    // [ or ], or PRESET: -1 or +1, main loads the preset
    u8[96] notice;                      // a line under the bar, for a moment
    i32 notice_len;
    f32 notice_left;                    // seconds
    Rect[BAR_COUNT] buttons;            // bar buttons, screen pixels
    f32 text_px;                        // overlay text size, pixels
    bool help_open;                     // the help window is showing
    f32 help_key_w;                     // its columns' widths as drawn; 0 until measured
    f32 help_what_w;
    Rope[256] ropes;                    // per cable, its shape while it moves (PATCH_MAX_CABLES)
    f32[256] wobble;                    // seconds of motion left per cable; 0 is at rest on the Bezier
    i32[256] rope_src;                  // the cable each rope belonged to last frame
    i32[256] rope_dst;
    i32 n_ropes;
    Rope[256] ropes_tmp;                // scratch for matching ropes to this frame's cables
    f32[256] wobble_tmp;
    f32[256] pulse;                     // per cable, a pulse's place along it, 0..1, or -1 for none
    f32[256] pulse_tmp;
    Rope hand;                          // the cable in hand
    bool hand_live;
    float2 hand_a;                      // its ends last frame, output end first
    float2 hand_b;
    f32[512] glow;                      // per output slot, 0..1: how lit its cables are (MAX_SLOTS)
    bool[512] flash;                    // per output slot: a change was seen this frame
    f32[512] seen;                      // each slot's last telemetry peak, to spot changes
    f32[512] seen_value;                // and its last value
    f32[1024] seen_param;               // each knob's last value, likewise (MAX_PARAMS)
    u32[64] seen_events;                // each module's last key-press count (MAX_MODULES)
}

f32 ui_bar_height(Ui* ui) { return floorf(BAR_H * ui.dpi + 0.5f); }

// One line of overlay text, with room around it.
f32 ui_row_height(Ui* ui) { return floorf(ui.text_px * 1.7f + 0.5f); }

// The bar and the status row under it.
f32 ui_top_height(Ui* ui) { return ui_bar_height(ui) + ui_row_height(ui); }

// Estimated width of overlay text, for layout that runs without the font.
f32 ui_text_w(Ui* ui, str s) { return cast(f32, s.len) * TEXT_EM * ui.text_px; }

// Where status text `chars` long starts, right-aligned on the row under
// the bar: its left edge (estimated) and its middle line.
float2 ui_status_pos(Ui* ui, i32 chars) {
    f32 w = cast(f32, chars) * TEXT_EM * ui.text_px;
    return float2{ ui.view.screen_w - w - ui.text_px, ui_bar_height(ui) + 0.5f * ui_row_height(ui) };
}

// Rows the help window takes: its entries, the title and a gap, and half
// a row before every heading after the first.
f32 ui_help_rows() {
    f32 rows = cast(f32, HELP_ROWS_N) + 2.0f;
    for i32 i = 1; i < HELP_ROWS_N; i++ {
        if HELP_ROWS[i].key.len == 0 { rows += 0.5f; }
        if str_equal(HELP_ROWS[i].key, HELP_PIANO) { rows += cast(f32, HELP_PIANO_ROWS - 1); }
    }
    return rows;
}

// The help window, centred below the bar: a title row, then the rows in
// two columns sized by their longest entries. The drawing measures the
// columns with the font; until it has (and in tests, which run without
// one) the widths are estimated. Rows tighten a little in short windows.
HelpLayout ui_help_layout(Ui* ui) {
    f32 px = ui.text_px;
    f32 key_w = ui.help_key_w;
    f32 what_w = ui.help_what_w;
    if key_w <= 0.0f || what_w <= 0.0f {
        for i32 i = 0; i < HELP_ROWS_N; i++ {
            if str_equal(HELP_ROWS[i].key, HELP_PIANO) { continue; }
            key_w = maxf(key_w, ui_text_w(ui, HELP_ROWS[i].key));
            what_w = maxf(what_w, ui_text_w(ui, HELP_ROWS[i].what));
        }
    }
    f32 pad = 1.5f * px;
    f32 gap = 2.5f * px;
    f32 top = ui_bar_height(ui);
    f32 room = ui.view.screen_h - top - 2.0f * px - 2.0f * pad;
    f32 row = floorf(clampf(room / ui_help_rows(), 1.2f * px, 1.55f * px) + 0.5f);
    f32 w = floorf(pad + key_w + gap + what_w + pad);
    f32 h = floorf(pad + ui_help_rows() * row + pad);
    f32 x = floorf(0.5f * (ui.view.screen_w - w));
    f32 y = floorf(top + maxf(0.5f * (ui.view.screen_h - top - h), px));
    HelpLayout l;
    l.box = Rect{ maxf(x, 0.0f), y, w, h };
    l.key_x = l.box.x + pad;
    l.what_x = l.key_x + key_w + gap;
    l.row = row;
    l.top = y + pad + 2.5f * row;            // under the title row and a gap
    return l;
}

// The bar: the title, then buttons sized by their longest label.
private void layout_bar(Ui* ui) {
    ui.text_px = floorf(TEXT_PX * ui.dpi + 0.5f);
    f32 px = ui.text_px;
    i32[10] chars = { 7, 9, 9, 4, 4, 3, 4, 4, 6, 4 };
    f32 x = 9.0f * px;
    f32 h = ui_bar_height(ui);
    for i32 i = 0; i < BAR_COUNT; i++ {
        f32 w = (cast(f32, chars[i]) * TEXT_EM_UPPER + 1.6f) * px;
        ui.buttons[i] = Rect{ x, 0.0f, w, h };
        x += w + 0.4f * px;
    }
}

void ui_fit(Ui* ui) {
    view_fit(&ui.view, ui.layout.width, ui.layout.height, ui_top_height(ui), 0.0f, MARGIN_PX * ui.dpi);
}

void ui_init(Ui* ui, Engine* e, f32 w, f32 h, f32 dpi) {
    *ui = Ui{};
    ui.dpi = dpi;
    ui.snap = -1;
    ui.wheel_knob = -1;
    ui.last_click = -10.0;
    ui.scroll_time = -10.0;
    layout_build(&ui.layout, e);
    view_init(&ui.view, w, h);
    layout_bar(ui);
    ui_fit(ui);
}

void ui_resize(Ui* ui, f32 w, f32 h, f32 dpi) {
    bool changed = w != ui.view.screen_w || h != ui.view.screen_h || dpi != ui.dpi;
    ui.view.screen_w = w;
    ui.view.screen_h = h;
    ui.dpi = dpi;
    layout_bar(ui);
    if changed { ui_fit(ui); }
}

// ---- where things are ----

float2 ui_in_pos(Ui* ui, i32 jack) { return ui.layout.ins[jack]; }
float2 ui_out_pos(Ui* ui, i32 slot) { return ui.layout.outs[slot]; }

// Hit reach for a jack or knob: its radius, and never under a few pixels.
private f32 reach(Ui* ui, f32 radius) {
    f32 r = radius + 3.0f;
    f32 min = 8.0f * ui.dpi / ui.view.zoom;
    if r < min { r = min; }
    return r;
}

private i32 nearest_in(Ui* ui, Engine* e, float2 v, f32 r) {
    i32 best = -1;
    f32 bd = r;
    for i32 j = 0; j < e.core.n_jacks; j++ {
        f32 d = point_distance(ui.layout.ins[j], v);
        if d <= bd {
            bd = d;
            best = j;
        }
    }
    return best;
}

private i32 nearest_out(Ui* ui, Engine* e, float2 v, f32 r) {
    i32 best = -1;
    f32 bd = r;
    for i32 s = 0; s < e.core.n_slots; s++ {
        f32 d = point_distance(ui.layout.outs[s], v);
        if d <= bd {
            bd = d;
            best = s;
        }
    }
    return best;
}

// The control at v: a knob or button by its disc, a switch by its pill.
private i32 knob_at(Ui* ui, Engine* e, float2 v) {
    f32 r = reach(ui, KNOB_R);
    for i32 k = 0; k < e.core.n_params; k++ {
        float2 c = ui.layout.knobs[k];
        i32 steps = e.core.params[k].steps;
        if steps > 1 {
            f32 half_w = 0.5f * SWITCH_GAP * cast(f32, steps - 1) + SWITCH_R;
            if fabsf(v.x - c.x) <= half_w + 3.0f && fabsf(v.y - c.y) <= SWITCH_R + 3.0f { return k; }
        } else if point_distance(c, v) <= r {
            return k;
        }
    }
    return -1;
}

// The wheel's turn of a knob ends as one undo step when the cursor
// leaves it or a click comes.
private void wheel_settle(Ui* ui, Patch* p) {
    if ui.wheel_knob < 0 { return; }
    patch_param_commit(p, ui.wheel_knob, ui.wheel_norm0);
    ui.wheel_knob = -1;
}

// The topmost cable under v, or -1. Cables drawn later sit on top.
i32 ui_cable_at(Ui* ui, Patch* p, float2 v) {
    f32 r = CABLE_W * 0.5f + 4.0f / ui.view.zoom;
    CablePath path;
    for i32 i = p.n_cables - 1; i >= 0; i-- {
        ignore ui_cable_shape(ui, p, i, &path);
        if cable_distance(&path, v) <= r { return i; }
    }
    return -1;
}

private i32 button_at(Ui* ui, float2 s) {
    for i32 i = 0; i < BAR_COUNT; i++ {
        if rect_contains(ui.buttons[i], s) { return i; }
    }
    return -1;
}

void ui_update_hover(Ui* ui, Patch* p, Engine* e) {
    ui.hover = HOVER_NONE;
    ui.hover_index = -1;
    if ui.mouse.y < ui_bar_height(ui) {
        i32 b = button_at(ui, ui.mouse);
        if b >= 0 {
            ui.hover = HOVER_BUTTON;
            ui.hover_index = b;
        }
        return;
    }
    if ui.help_open { return; }                 // the rack is behind the help window
    float2 v = view_to_rack(&ui.view, ui.mouse);
    f32 jr = reach(ui, JACK_R);
    i32 j = nearest_in(ui, e, v, jr);
    if j >= 0 {
        ui.hover = HOVER_IN;
        ui.hover_index = j;
        return;
    }
    i32 s = nearest_out(ui, e, v, jr);
    if s >= 0 {
        ui.hover = HOVER_OUT;
        ui.hover_index = s;
        return;
    }
    i32 k = knob_at(ui, e, v);
    if k >= 0 {
        ui.hover = HOVER_KNOB;
        ui.hover_index = k;
        if ui.wheel_knob != k { wheel_settle(ui, p); }
        return;
    }
    wheel_settle(ui, p);
    if ui.cable_vis != VIS_HIDDEN {
        i32 c = ui_cable_at(ui, p, v);
        if c >= 0 {
            ui.hover = HOVER_CABLE;
            ui.hover_index = c;
        }
    }
}

// ---- valid targets for the plug in hand ----

private bool input_takes(Patch* p, Engine* e, i32 src, i32 jack) {
    if !patch_can_connect(p, e, src, jack) || patch_find(p, src, jack) >= 0 { return false; }
    i32 max = profile_max_sources(p.profile, e.core.jacks[jack].cls);
    return max == 1 || patch_count_into(p, jack) < max;
}

// While dragging: can the loose plug go into input `jack`?
bool ui_valid_in(Ui* ui, Patch* p, Engine* e, i32 jack) {
    if ui.drag == DRAG_FROM_OUT { return input_takes(p, e, ui.fixed, jack); }
    if ui.drag == DRAG_MOVE_DST {
        Cable c = p.cables[ui.fixed];
        return jack == c.dst || input_takes(p, e, c.src, jack);
    }
    return false;
}

// While dragging: can the loose plug go onto output `slot`?
bool ui_valid_out(Ui* ui, Patch* p, Engine* e, i32 slot) {
    if ui.drag == DRAG_FROM_IN { return input_takes(p, e, slot, ui.fixed); }
    if ui.drag == DRAG_MOVE_SRC {
        Cable c = p.cables[ui.fixed];
        return slot == c.src || (patch_can_connect(p, e, slot, c.dst) && patch_find(p, slot, c.dst) < 0);
    }
    return false;
}

bool ui_dragging_cable(Ui* ui) {
    return ui.drag == DRAG_FROM_OUT || ui.drag == DRAG_FROM_IN || ui.drag == DRAG_MOVE_DST || ui.drag == DRAG_MOVE_SRC;
}

// Whether the loose plug is an input plug (so it lands on inputs).
bool ui_loose_is_input(Ui* ui) { return ui.drag == DRAG_FROM_OUT || ui.drag == DRAG_MOVE_DST; }

// The nearest valid target within snapping reach of the mouse, or -1.
private void update_snap(Ui* ui, Patch* p, Engine* e) {
    ui.snap = -1;
    f32 best = SNAP_PX * ui.dpi;
    if ui_loose_is_input(ui) {
        for i32 j = 0; j < e.core.n_jacks; j++ {
            f32 d = point_distance(view_to_screen(&ui.view, ui.layout.ins[j]), ui.mouse);
            if d <= best && ui_valid_in(ui, p, e, j) {
                best = d;
                ui.snap = j;
            }
        }
    } else {
        for i32 s = 0; s < e.core.n_slots; s++ {
            f32 d = point_distance(view_to_screen(&ui.view, ui.layout.outs[s]), ui.mouse);
            if d <= best && ui_valid_out(ui, p, e, s) {
                best = d;
                ui.snap = s;
            }
        }
    }
}

// ---- actions ----

void ui_toggle_profile(Patch* p, Engine* e) { ignore patch_set_profile(p, e, 1 - p.profile); }
void ui_toggle_feel(Patch* p, Engine* e) { patch_set_feel(p, e, 1 - p.feel); }

// A line under the bar for a few seconds: what a save or a load did.
void ui_notice(Ui* ui, str s) {
    ui.notice_len = 0;
    for i32 i = 0; i < s.len && i < 96; i++ {
        ui.notice[i] = s.data[i];
        ui.notice_len++;
    }
    ui.notice_left = 4.0f;
}

private void press_button(Ui* ui, Patch* p, Engine* e, i32 b) {
    if b == BAR_PROFILE { ui_toggle_profile(p, e); }
    else if b == BAR_FEEL { ui_toggle_feel(p, e); }
    else if b == BAR_QUALITY { ui.want_quality = true; }
    else if b == BAR_UNDO { ignore patch_undo(p, e); }
    else if b == BAR_REDO { ignore patch_redo(p, e); }
    else if b == BAR_SAVE { ui.want_save_as = true; }          // the button always asks; Ctrl+S saves in place
    else if b == BAR_LOAD { ui.want_load = true; }
    else if b == BAR_PRESET { ui.want_preset = (ui.mods & UIM_SHIFT) != 0 ? -1 : 1; }
    else if b == BAR_HELP { ui.help_open = !ui.help_open; }
    else { ui_fit(ui); }
}

// A click on a switch picks the position nearest the click.
private void pick_switch(Ui* ui, Patch* p, Engine* e, i32 k) {
    Param* q = &e.core.params[k];
    i32 steps = q.steps;
    float2 c = ui.layout.knobs[k];
    float2 v = view_to_rack(&ui.view, ui.mouse);
    f32 x0 = c.x - 0.5f * SWITCH_GAP * cast(f32, steps - 1);
    i32 idx = clampi(cast(i32, floorf((v.x - x0) / SWITCH_GAP + 0.5f)), 0, steps - 1);
    ignore patch_set_param(p, e, k, cast(f32, idx) / cast(f32, steps - 1));
}

// What a scroll gesture does, decided by its first event and kept while
// its events keep coming (SCROLL_LATCH_S apart at most). Starting over a
// control and moving up or down, it turns that control, from a wheel or
// a touchpad. Elsewhere, or sideways, a wheel zooms and a touchpad pans:
// a wheel moves up and down by whole notches (a browser: 100 pixels or
// more), a touchpad in small steps. So a pan that brings a control under
// the cursor goes on panning; turning starts only with a new gesture.
private i32 scroll_mode(Ui* ui, UiEvent ev) {
    bool fresh = ev.time - ui.scroll_time >= SCROLL_LATCH_S;
    ui.scroll_time = ev.time;
    if !fresh { return ui.scroll_mode; }
    ui.scroll_accum = 0.0f;
    bool vertical = fabsf(ev.scroll) > fabsf(ev.scroll_x);
    if ui.hover == HOVER_KNOB && ui.drag == DRAG_NONE && vertical {
        ui.scroll_mode = SCROLL_TURN;
        ui.scroll_knob = ui.hover_index;
    } else if ev.scroll_x == 0.0f && fabsf(ev.scroll) >= 0.99f {
        ui.scroll_mode = SCROLL_ZOOM;
    } else {
        ui.scroll_mode = SCROLL_PAN;
    }
    return ui.scroll_mode;
}

// An arrow key's step: the view moves that way by a share of the window.
private void arrow_pan(Ui* ui, f32 dx, f32 dy, bool big) {
    f32 share = ARROW_STEP;
    if big { share *= 4.0f; }
    view_pan_by(&ui.view, float2{ -dx * ui.view.screen_w, -dy * ui.view.screen_h } * share);
}

// The wheel over a control: a knob turns by a notch (fine with Shift), a
// switch steps without wrapping, a button does nothing.
private void wheel_turn(Ui* ui, Patch* p, Engine* e, i32 k, f32 scroll, bool fine) {
    Param* q = &e.core.params[k];
    if q.steps == 1 || scroll == 0.0f { return; }
    i32 dir = scroll > 0.0f ? 1 : -1;
    if q.steps > 1 {
        i32 idx = cast(i32, floorf(p.params[k] * cast(f32, q.steps - 1) + 0.5f));
        idx = clampi(idx + dir, 0, q.steps - 1);
        ignore patch_set_param(p, e, k, cast(f32, idx) / cast(f32, q.steps - 1));
        return;
    }
    if ui.wheel_knob != k {
        wheel_settle(ui, p);
        ui.wheel_knob = k;
        ui.wheel_norm0 = p.params[k];
    }
    f32 step = WHEEL_STEP * fabsf(scroll);
    if fine { step *= FINE; }
    patch_param_live(p, e, k, p.params[k] + cast(f32, dir) * step);
}

private void begin_drag(Ui* ui, i32 mode) {
    ui.drag = mode;
    ui.drag_mouse0 = ui.mouse;
    ui.drag_pan0 = ui.view.pan;
    ui.loose = view_to_rack(&ui.view, ui.mouse);
    ui.snap = -1;
}

private void left_down(Ui* ui, Patch* p, Engine* e, bool dbl) {
    if ui.space {
        begin_drag(ui, DRAG_PAN);
        return;
    }
    if ui.hover == HOVER_BUTTON {
        press_button(ui, p, e, ui.hover_index);
        return;
    }
    bool ctrl = (ui.mods & UIM_CTRL) != 0;
    bool shift = (ui.mods & UIM_SHIFT) != 0;
    if ui.hover == HOVER_OUT {
        i32 last = patch_last_from(p, ui.hover_index);
        if ctrl && last >= 0 {
            begin_drag(ui, DRAG_MOVE_SRC);
            ui.fixed = last;
        } else {
            begin_drag(ui, DRAG_FROM_OUT);
            ui.fixed = ui.hover_index;
        }
    } else if ui.hover == HOVER_IN {
        i32 last = patch_last_into(p, ui.hover_index);
        if last >= 0 {
            begin_drag(ui, DRAG_MOVE_DST);
            ui.fixed = last;
        } else {
            begin_drag(ui, DRAG_FROM_IN);
            ui.fixed = ui.hover_index;
        }
    } else if ui.hover == HOVER_KNOB {
        i32 k = ui.hover_index;
        if e.core.params[k].steps == 1 {
            // A button: down while held, never an undo step.
            patch_param_live(p, e, k, 1.0f);
            begin_drag(ui, DRAG_BUTTON);
            ui.knob = k;
        } else if dbl {
            ignore patch_set_param(p, e, k, p.defaults[k]);
        } else if e.core.params[k].steps > 1 {
            pick_switch(ui, p, e, k);
        } else {
            begin_drag(ui, DRAG_KNOB);
            ui.knob = k;
            ui.knob_norm0 = p.params[k];
        }
    } else if ui.hover == HOVER_CABLE {
        i32 c = ui.hover_index;
        if shift {
            patch_cycle_color(p, c);
        } else if dbl {
            ignore patch_remove(p, e, c);
        } else {
            // Pick up the nearer plug.
            float2 v = view_to_rack(&ui.view, ui.mouse);
            f32 ds = point_distance(v, ui.layout.outs[p.cables[c].src]);
            f32 dd = point_distance(v, ui.layout.ins[p.cables[c].dst]);
            begin_drag(ui, ds < dd ? DRAG_MOVE_SRC : DRAG_MOVE_DST);
            ui.fixed = c;
        }
    } else {
        begin_drag(ui, DRAG_PAN);
    }
    if ui_dragging_cable(ui) { update_snap(ui, p, e); }
}

private void right_down(Ui* ui, Patch* p, Engine* e) {
    i32 c = -1;
    if ui.hover == HOVER_CABLE { c = ui.hover_index; }
    else if ui.hover == HOVER_IN { c = patch_last_into(p, ui.hover_index); }
    else if ui.hover == HOVER_OUT { c = patch_last_from(p, ui.hover_index); }
    if c >= 0 { ignore patch_remove(p, e, c); }
}

private void left_up(Ui* ui, Patch* p, Engine* e) {
    i32 mode = ui.drag;
    ui.drag = DRAG_NONE;
    if mode == DRAG_KNOB {
        patch_param_commit(p, ui.knob, ui.knob_norm0);
    } else if mode == DRAG_BUTTON {
        patch_param_live(p, e, ui.knob, 0.0f);
    } else if mode == DRAG_FROM_OUT {
        if ui.snap >= 0 { ignore patch_connect(p, e, ui.fixed, ui.snap); }
    } else if mode == DRAG_FROM_IN {
        if ui.snap >= 0 { ignore patch_connect(p, e, ui.snap, ui.fixed); }
    } else if mode == DRAG_MOVE_DST {
        Cable c = p.cables[ui.fixed];
        if ui.snap < 0 { ignore patch_remove(p, e, ui.fixed); }
        else if ui.snap != c.dst { ignore patch_move_dst(p, e, ui.fixed, ui.snap); }
    } else if mode == DRAG_MOVE_SRC {
        Cable c = p.cables[ui.fixed];
        if ui.snap < 0 { ignore patch_remove(p, e, ui.fixed); }
        else if ui.snap != c.src { ignore patch_move_src(p, e, ui.fixed, ui.snap); }
    }
    ui.snap = -1;
}

private void drag_move(Ui* ui, Patch* p, Engine* e) {
    if ui.drag == DRAG_PAN {
        ui.view.pan = ui.drag_pan0 - (ui.mouse - ui.drag_mouse0) / ui.view.zoom;
    } else if ui.drag == DRAG_KNOB {
        f32 travel = KNOB_DRAG_PX * ui.dpi;
        f32 scale = 1.0f;
        if (ui.mods & UIM_SHIFT) != 0 { scale = FINE; }
        f32 n = ui.knob_norm0 + (ui.mouse.x - ui.drag_mouse0.x) / travel * scale;
        patch_param_live(p, e, ui.knob, n);
    } else if ui_dragging_cable(ui) {
        ui.loose = view_to_rack(&ui.view, ui.mouse);
        update_snap(ui, p, e);
        // The hover, and its tooltip, is the jack the plug would land on.
        ui.hover = HOVER_NONE;
        ui.hover_index = -1;
        if ui.snap >= 0 {
            ui.hover = ui_loose_is_input(ui) ? HOVER_IN : HOVER_OUT;
            ui.hover_index = ui.snap;
        }
    }
}

// Handles one event. Returns true when the UI used it; key events it
// doesn't use are left for the note keys.
bool ui_event(Ui* ui, Patch* p, Engine* e, UiEvent ev) {
    ui.mods = ev.mods;
    switch ev.type {
        case UIE_MOVE: {
            // Moving the pointer ends a scroll gesture: the next scroll
            // decides afresh. (While two fingers scroll, it stays put.)
            if ev.x != ui.mouse.x || ev.y != ui.mouse.y { ui.scroll_time = -10.0; }
            ui.mouse = float2{ ev.x, ev.y };
            if ui.drag == DRAG_NONE { ui_update_hover(ui, p, e); } else { drag_move(ui, p, e); }
            return true;
        }
        case UIE_DOWN: {
            ui.mouse = float2{ ev.x, ev.y };
            if ui.drag != DRAG_NONE { return true; }
            // With help open, the bar still works; a click anywhere else
            // outside the window closes it, and one inside does nothing.
            if ui.help_open && ui.mouse.y >= ui_bar_height(ui) {
                if !rect_contains(ui_help_layout(ui).box, ui.mouse) { ui.help_open = false; }
                ui_update_hover(ui, p, e);
                return true;
            }
            ui_update_hover(ui, p, e);
            if ev.button == UIB_LEFT {
                bool dbl = ev.time - ui.last_click < DOUBLE_CLICK_S
                        && point_distance(ui.mouse, ui.last_click_pos) < 6.0f * ui.dpi;
                ui.last_click = ev.time;
                ui.last_click_pos = ui.mouse;
                if dbl { ui.last_click = -10.0; }
                left_down(ui, p, e, dbl);
            } else if ev.button == UIB_RIGHT {
                right_down(ui, p, e);
            } else {
                begin_drag(ui, DRAG_PAN);
            }
            return true;
        }
        case UIE_UP: {
            ui.mouse = float2{ ev.x, ev.y };
            if ui.drag == DRAG_PAN && ev.button != UIB_LEFT && ev.button != UIB_MIDDLE { return true; }
            if ev.button == UIB_LEFT || ui.drag == DRAG_PAN { left_up(ui, p, e); }
            ui_update_hover(ui, p, e);
            return true;
        }
        case UIE_SCROLL: {
            if ui.help_open { return true; }
            // A browser reports pixels, so one event counts for at most a notch.
            f32 notch = clampf(ev.scroll, -1.0f, 1.0f);
            // Ctrl + scroll zooms: a pinch arrives that way on Windows, in
            // browsers and from the macOS touchpad. The zoom follows the
            // scroll smoothly. It is not a gesture of its own: a two-finger
            // scroll right after a pinch decides afresh, and pans.
            if (ev.mods & UIM_CTRL) != 0 {
                ui.scroll_time = -10.0;
                view_zoom_at(&ui.view, ui.mouse, exp2_fast(notch * 0.25f));
                return true;
            }
            i32 mode = scroll_mode(ui, ev);
            if mode == SCROLL_TURN {
                // A switch moves a position per notch's worth of scrolling,
                // so a touchpad's small steps add up before it moves.
                i32 k = ui.scroll_knob;
                bool fine = (ev.mods & UIM_SHIFT) != 0;
                if e.core.params[k].steps > 1 {
                    ui.scroll_accum += notch;
                    while fabsf(ui.scroll_accum) >= 1.0f {
                        f32 dir = ui.scroll_accum > 0.0f ? 1.0f : -1.0f;
                        wheel_turn(ui, p, e, k, dir, fine);
                        ui.scroll_accum -= dir;
                    }
                } else {
                    wheel_turn(ui, p, e, k, notch, fine);
                }
            } else if mode == SCROLL_PAN {
                wheel_settle(ui, p);
                view_pan_by(&ui.view, float2{ ev.scroll_x, ev.scroll } * (SCROLL_PAN_PX * ui.dpi));
                ui_update_hover(ui, p, e);
            } else {
                view_zoom_at(&ui.view, ui.mouse, exp2_fast(notch * 0.25f));
            }
            return true;
        }
        case UIE_KEY_UP: {
            if ev.key == UIK_SPACE {
                ui.space = false;
                return true;
            }
            return false;
        }
        default: {}
    }
    // Key down. Escape closes the help window; with it closed, Escape is
    // left for the app, which quits.
    if ev.key == UIK_ESCAPE {
        if !ui.help_open { return false; }
        ui.help_open = false;
        ui_update_hover(ui, p, e);
        return true;
    }
    bool ctrl = (ev.mods & UIM_CTRL) != 0;
    bool shift = (ev.mods & UIM_SHIFT) != 0;
    if ctrl && ev.key == 'Z' {
        if shift { ignore patch_redo(p, e); } else { ignore patch_undo(p, e); }
        return true;
    }
    if ctrl && ev.key == 'Y' {
        ignore patch_redo(p, e);
        return true;
    }
    if ctrl && ev.key == 'S' {
        if shift { ui.want_save_as = true; } else { ui.want_save = true; }
        return true;
    }
    if ctrl && ev.key == 'O' {
        ui.want_load = true;
        return true;
    }
    if ctrl { return true; }                    // no notes while Ctrl is down
    // Arrows move the view that way, again while held; Shift for bigger steps.
    if ev.key == UIK_LEFT || ev.key == UIK_RIGHT || ev.key == UIK_UP || ev.key == UIK_DOWN {
        f32 dx = 0.0f;
        f32 dy = 0.0f;
        if ev.key == UIK_LEFT { dx = -1.0f; }
        else if ev.key == UIK_RIGHT { dx = 1.0f; }
        else if ev.key == UIK_UP { dy = -1.0f; }
        else { dy = 1.0f; }
        arrow_pan(ui, dx, dy, shift);
        ui_update_hover(ui, p, e);
        return true;
    }
    if ev.repeat { return ev.key == UIK_SPACE; }
    if ev.key == UIK_SPACE { ui.space = true; }
    else if ev.key == 'F' { ui_fit(ui); }
    else if ev.key == UIK_TAB { ui.cable_vis = (ui.cable_vis + 1) % 3; }
    else if ev.key == 'L' { ui.focus = !ui.focus; }
    else if ev.key == 'P' { ui.want_panic = true; }
    else if ev.key == UIK_F1 { ui_toggle_profile(p, e); }
    else if ev.key == UIK_F2 { ui_toggle_feel(p, e); }
    else if ev.key == UIK_F3 { ui.want_quality = true; }
    else if ev.key == UIK_LBRACKET { ui.want_preset = -1; }
    else if ev.key == UIK_RBRACKET { ui.want_preset = 1; }
    else if ev.key == UIK_DELETE || ev.key == UIK_BACKSPACE {
        if ui.hover == HOVER_CABLE { ignore patch_remove(p, e, ui.hover_index); }
    } else {
        return false;
    }
    ui_update_hover(ui, p, e);
    return true;
}

// ---- cable motion ----

// The ends of the cable in hand, output end first; false when none is.
bool ui_hand_ends(Ui* ui, Patch* p, float2* a, float2* b) {
    if !ui_dragging_cable(ui) { return false; }
    float2 fixed_pos = float2{ 0.0f, 0.0f };
    if ui.drag == DRAG_FROM_OUT { fixed_pos = ui.layout.outs[ui.fixed]; }
    else if ui.drag == DRAG_FROM_IN { fixed_pos = ui.layout.ins[ui.fixed]; }
    else if ui.drag == DRAG_MOVE_DST { fixed_pos = ui.layout.outs[p.cables[ui.fixed].src]; }
    else { fixed_pos = ui.layout.ins[p.cables[ui.fixed].dst]; }
    float2 loose = ui.loose;
    if ui.snap >= 0 {
        if ui_loose_is_input(ui) { loose = ui.layout.ins[ui.snap]; } else { loose = ui.layout.outs[ui.snap]; }
    }
    if ui_loose_is_input(ui) {
        *a = fixed_pos;
        *b = loose;
    } else {
        *a = loose;
        *b = fixed_pos;
    }
    return true;
}

// Once a frame: every cable that moved keeps swinging as a rope for a
// while, and the cable in hand swings from the cursor. A cable that just
// landed takes the hand's rope with it, so nothing jumps.
void ui_update_ropes(Ui* ui, Patch* p, f32 dt) {
    for i32 i = 0; i < p.n_cables; i++ {
        Cable c = p.cables[i];
        float2 a = ui.layout.outs[c.src];
        float2 b = ui.layout.ins[c.dst];
        i32 j = -1;
        for i32 k = 0; k < ui.n_ropes; k++ {
            if ui.rope_src[k] == c.src && ui.rope_dst[k] == c.dst {
                j = k;
                break;
            }
        }
        f32 w = 0.0f;
        f32 pulse = -1.0f;
        if j >= 0 {
            ui.ropes_tmp[i] = ui.ropes[j];
            w = ui.wobble[j];
            pulse = ui.pulse[j];
        } else {
            w = ROPE_WOBBLE_S;
            bool from_hand = ui.hand_live && (point_distance(ui.hand_a, a) < 0.5f || point_distance(ui.hand_b, b) < 0.5f);
            if from_hand { ui.ropes_tmp[i] = ui.hand; } else { rope_init_line(&ui.ropes_tmp[i], a, b); }
        }
        if w > 0.0f {
            rope_step(&ui.ropes_tmp[i], a, b, dt);
            w -= dt;
            if w < 0.0f { w = 0.0f; }
        }
        ui.wobble_tmp[i] = w;
        // A change at the source sends a pulse down the cable (ui_update_glow
        // runs first); one at a time, so a stream of changes reads as a flow.
        if pulse >= 0.0f {
            pulse += dt / PULSE_S;
            if pulse > 1.0f { pulse = -1.0f; }
        }
        if pulse < 0.0f && ui.flash[c.src] { pulse = 0.0f; }
        ui.pulse_tmp[i] = pulse;
    }
    ui.n_ropes = p.n_cables;
    for i32 i = 0; i < p.n_cables; i++ {
        ui.ropes[i] = ui.ropes_tmp[i];
        ui.wobble[i] = ui.wobble_tmp[i];
        ui.pulse[i] = ui.pulse_tmp[i];
        ui.rope_src[i] = p.cables[i].src;
        ui.rope_dst[i] = p.cables[i].dst;
    }

    float2 a = float2{ 0.0f, 0.0f };
    float2 b = float2{ 0.0f, 0.0f };
    if ui_hand_ends(ui, p, &a, &b) {
        if !ui.hand_live {
            rope_init_line(&ui.hand, a, b);
            ui.hand_live = true;
        }
        rope_step(&ui.hand, a, b, dt);
        ui.hand_a = a;
        ui.hand_b = b;
    } else {
        ui.hand_live = false;
    }
}

// Cable i's shape now: its rope, or the Bezier before any frame has run.
// True while it is still moving.
bool ui_cable_shape(Ui* ui, Patch* p, i32 i, CablePath* out) {
    if i >= ui.n_ropes {
        Cable c = p.cables[i];
        cable_path(out, ui.layout.outs[c.src], ui.layout.ins[c.dst]);
        return false;
    }
    rope_path(&ui.ropes[i], out);
    return ui.wobble[i] > 0.0f;
}

// The cable in hand's shape, once ui_update_ropes has run this frame.
void ui_hand_shape(Ui* ui, CablePath* out) { rope_path(&ui.hand, out); }

// ---- cable glow ----

const f32 GLOW_FLOOR_DB = -40.0f;       // quieter than this: dark
const f32 GLOW_STEADY = 0.4f;           // the most a steady signal lights its cables
const f32 GLOW_DECAY_S = 0.25f;         // time constant of the fade after a change
const f32 GLOW_AUDIO_STEP = 0.06f;      // audio level change that counts, relative (~0.5 dB)
const f32 PULSE_S = 0.4f;               // a change's pulse travels the cable in this long

// Marks every output of module `m` that carries signal as changed; true
// when one wasn't already.
private bool glow_through(Engine* e, i32 m, bool* changed, bool* present) {
    ModuleInfo* info = &e.modules[m];
    bool more = false;
    for i32 o = 0; o < info.desc.n_outputs; o++ {
        i32 s = info.base.slot0 + o;
        if present[s] && !changed[s] {
            changed[s] = true;
            more = true;
        }
    }
    return more;
}

// Updates how lit each output's cables are. A steady signal lights them
// dimly, by its level in dB against its class's full scale. A change
// lights them fully, then fades: a change in the signal's own level, a
// knob turned or a key pressed on its module, or a change arriving at one
// of its module's inputs. So every key press lights the pitch cable and
// the oscillator's audio after it, though neither may change.
void ui_update_glow(Ui* ui, Patch* p, Engine* e, f32 dt) {
    f32 keep = 0.0f;
    if dt > 0.0f { keep = exp2_fast(-dt / GLOW_DECAY_S * 1.442695f); }
    Core* c = &e.core;
    f32 floor_level = exp2_fast(GLOW_FLOOR_DB / 6.0206f);
    noinit f32[MAX_SLOTS] steady;
    noinit bool[MAX_SLOTS] changed;
    noinit bool[MAX_SLOTS] present;
    for i32 s = 0; s < c.n_slots; s++ {
        f32 peak = tele_peak(&e.tele, s);
        f32 scale = c.out_scale[s];
        f32 level = peak / scale;
        steady[s] = 0.0f;
        if level > floor_level { steady[s] = GLOW_STEADY * (1.0f - 6.0206f * log2(level) / GLOW_FLOOR_DB); }
        steady[s] = clampf(steady[s], 0.0f, GLOW_STEADY);
        present[s] = level > floor_level;
        // Audio changes by its level; a peak wanders a little with the
        // phase its samples land on, so only a real step counts. Control
        // signals change by their value, or by a peak that a trigger
        // shorter than a frame leaves behind.
        f32 step = 1e-3f * scale;
        if c.slot_cls[s] == CLS_AUDIO {
            changed[s] = fabsf(peak - ui.seen[s]) > step + GLOW_AUDIO_STEP * fmaxf(peak, ui.seen[s]);
        } else {
            f32 value = tele_value(&e.tele, s);
            changed[s] = fabsf(value - ui.seen_value[s]) > step || fabsf(peak - ui.seen[s]) > step;
            ui.seen_value[s] = value;
        }
        ui.seen[s] = peak;
    }
    for i32 m = 0; m < e.n_modules; m++ {
        ModuleInfo* info = &e.modules[m];
        bool turned = false;
        for i32 i = 0; i < info.desc.n_params; i++ {
            i32 k = info.base.param0 + i;
            if p.params[k] != ui.seen_param[k] { turned = true; }
            ui.seen_param[k] = p.params[k];
        }
        if turned { ignore glow_through(e, m, &changed[0], &present[0]); }
        // A key press lights every output of the module that took it, even
        // a repeat of the same note, where nothing it sends changes.
        u32 events = tele_events(&e.tele, m);
        if events != ui.seen_events[m] {
            for i32 o = 0; o < info.desc.n_outputs; o++ { changed[info.base.slot0 + o] = true; }
        }
        ui.seen_events[m] = events;
    }

    // Changes pass on through modules, around feedback loops too; each
    // pass lights at least one more output or ends it.
    noinit bool[MAX_JACKS] patched;
    for i32 j = 0; j < c.n_jacks; j++ { patched[j] = false; }
    for i32 i = 0; i < p.n_cables; i++ { patched[p.cables[i].dst] = true; }
    bool more = true;
    while more {
        more = false;
        for i32 i = 0; i < p.n_cables; i++ {
            Cable cb = p.cables[i];
            if changed[cb.src] && glow_through(e, c.jacks[cb.dst].module, &changed[0], &present[0]) { more = true; }
        }
        for i32 j = 0; j < c.n_jacks; j++ {
            i32 n = c.jacks[j].normal_src;
            if n >= 0 && !patched[j] && changed[n] && glow_through(e, c.jacks[j].module, &changed[0], &present[0]) {
                more = true;
            }
        }
    }

    for i32 s = 0; s < c.n_slots; s++ {
        f32 act = steady[s];
        if changed[s] { act = 1.0f; }
        f32 held = ui.glow[s] * keep;
        ui.glow[s] = act;
        if held > act { ui.glow[s] = held; }
        ui.flash[s] = changed[s];
    }
}
