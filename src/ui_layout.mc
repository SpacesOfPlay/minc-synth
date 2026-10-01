// ui_layout.mc: where everything sits on the rack, in virtual units.
//
// Built once from the engine's module descriptors and the rack rows.
// Each module is a panel as wide as its contents need: the label strip,
// a grid of knobs, the inputs, and the outputs on a darker band at the
// bottom. Panels in one row share its height. One virtual unit is one
// screen pixel at zoom 1.

import engine_core;
import engine;
import rack;

const f32 U_CELL = 52.0f;               // grid cell width
const f32 U_HEAD = 28.0f;               // label strip
const f32 U_KNOB_H = 62.0f;             // knob cell: knob and its label
const f32 U_JACK_H = 46.0f;             // jack cell: jack and its label
const f32 U_PAD = 8.0f;
const f32 U_GAP = 10.0f;                // between panels
const f32 U_ROW_GAP = 20.0f;            // between rows
const f32 U_DISPLAY_H = 150.0f;         // the scope's screen
const f32 KNOB_R = 15.0f;
const f32 JACK_R = 9.0f;
const f32 SWITCH_GAP = 7.5f;            // between a switch's positions
const f32 SWITCH_R = 7.0f;              // half the height of its pill
const i32 LAYOUT_MAX_COLS = 8;

struct Rect {
    f32 x;
    f32 y;
    f32 w;
    f32 h;
}

bool rect_contains(Rect r, float2 p) {
    return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h;
}

struct Layout {
    Rect[64] panels;                    // by module (MAX_MODULES)
    Rect[64] out_bands;                 // the outputs' band, by module
    Rect[64] displays;                  // a module's screen, by module; 0 wide when it has none
    i32[64] cols;
    i32 n_modules;
    float2[1024] knobs;                 // knob centres, by param (MAX_PARAMS)
    float2[512] ins;                    // input centres, by jack (MAX_JACKS)
    float2[512] outs;                   // output centres, by slot (MAX_SLOTS)
    f32 width;                          // the whole rack
    f32 height;
}

private i32 ceil_div(i32 a, i32 b) { return (a + b - 1) / b; }

// Grid columns a module needs: room for its knobs in three rows and its
// jacks in two, at least two wide.
i32 layout_cols(ModuleDesc* d) {
    i32 c = 2;
    if ceil_div(d.n_params, 3) > c { c = ceil_div(d.n_params, 3); }
    if ceil_div(d.n_inputs, 2) > c { c = ceil_div(d.n_inputs, 2); }
    if ceil_div(d.n_outputs, 2) > c { c = ceil_div(d.n_outputs, 2); }
    if c > LAYOUT_MAX_COLS { c = LAYOUT_MAX_COLS; }
    return c;
}

// Columns for a module: set per kind where the grid should follow the
// panel's meaning (a bank core per output row, a sequencer step per
// column), otherwise from its contents.
i32 module_cols(ModuleInfo* info) {
    switch info.kind {
        case KIND_BANK, KIND_OFFSETS, KIND_SCOPE: { return 4; }
        case KIND_SEQ: { return 8; }
        case KIND_SPECTRUM: { return 7; }
        case KIND_GATES, KIND_STEPSW, KIND_ATTEN, KIND_MULT, KIND_KEYS: { return 3; }   // KEYS: room for VOICES and its key map
        default: { return layout_cols(&info.desc); }
    }
}

// Height of a module's screen, above its knobs.
f32 module_display_h(ModuleInfo* info) {
    if info.kind == KIND_SCOPE { return U_DISPLAY_H; }
    return 0.0f;
}

private f32 content_height(ModuleInfo* info, i32 cols) {
    ModuleDesc* d = &info.desc;
    return U_HEAD + module_display_h(info) + cast(f32, ceil_div(d.n_params, cols)) * U_KNOB_H
         + cast(f32, ceil_div(d.n_inputs, cols)) * U_JACK_H
         + cast(f32, ceil_div(d.n_outputs, cols)) * U_JACK_H + U_PAD;
}

void layout_build(Layout* l, Engine* e) {
    *l = Layout{};
    l.n_modules = e.n_modules;
    // Each row's natural width, so a row holding a screen can stretch that
    // module until its right edge lines up with the widest row.
    f32[3] row_w;                                   // RACK_ROWS
    f32 widest = 0.0f;
    for i32 row = 0; row < RACK_ROWS; row++ {
        row_w[row] = -U_GAP;
        for i32 m = 0; m < e.n_modules; m++ {
            if rack_row(m) != row { continue; }
            row_w[row] += cast(f32, module_cols(&e.modules[m])) * U_CELL + 2.0f * U_PAD + U_GAP;
        }
        if row_w[row] > widest { widest = row_w[row]; }
    }
    f32 y = 0.0f;
    for i32 row = 0; row < RACK_ROWS; row++ {
        // The row is as tall as its tallest panel.
        f32 row_h = 0.0f;
        for i32 m = 0; m < e.n_modules; m++ {
            if rack_row(m) != row { continue; }
            i32 c = module_cols(&e.modules[m]);
            f32 h = content_height(&e.modules[m], c);
            if h > row_h { row_h = h; }
        }
        f32 x = 0.0f;
        for i32 m = 0; m < e.n_modules; m++ {
            if rack_row(m) != row { continue; }
            ModuleInfo* info = &e.modules[m];
            ModuleDesc* d = &info.desc;
            i32 c = module_cols(info);
            l.cols[m] = c;
            f32 w = cast(f32, c) * U_CELL + 2.0f * U_PAD;
            f32 disp = module_display_h(info);
            if disp > 0.0f {
                // A module with a screen takes the row's spare width and
                // height for it.
                w += widest - row_w[row];
                disp = row_h - (content_height(info, c) - disp);
            }
            l.panels[m] = Rect{ x, y, w, row_h };
            f32 left = x + U_PAD;
            if disp > 0.0f { l.displays[m] = Rect{ left, y + U_HEAD, w - 2.0f * U_PAD, disp - U_PAD }; }
            f32 top = y + U_HEAD + disp;

            for i32 i = 0; i < d.n_params; i++ {
                f32 cx = left + (cast(f32, i % c) + 0.5f) * U_CELL;
                f32 cy = top + cast(f32, i / c) * U_KNOB_H + KNOB_R + 6.0f;
                l.knobs[info.base.param0 + i] = float2{ cx, cy };
            }
            // KEYS' VOICES switch is wider than a cell: its left end lines up
            // with the left edge of the knob above it, clear of the panel's edge.
            if info.kind == KIND_KEYS {
                f32 half = 0.5f * SWITCH_GAP * cast(f32, MAX_VOICES - 1) + SWITCH_R;
                l.knobs[info.base.param0 + KEYS_P_VOICES].x = left + 0.5f * U_CELL - KNOB_R + half;
            }
            f32 in_top = top + cast(f32, ceil_div(d.n_params, c)) * U_KNOB_H;
            for i32 i = 0; i < d.n_inputs; i++ {
                f32 cx = left + (cast(f32, i % c) + 0.5f) * U_CELL;
                f32 cy = in_top + cast(f32, i / c) * U_JACK_H + JACK_R + 6.0f;
                l.ins[info.base.jack0 + i] = float2{ cx, cy };
            }
            // Outputs sit at the bottom of the panel, on their own band.
            i32 out_rows = ceil_div(d.n_outputs, c);
            f32 out_top = y + row_h - U_PAD - cast(f32, out_rows) * U_JACK_H;
            l.out_bands[m] = Rect{ x + 3.0f, out_top - 2.0f, w - 6.0f, cast(f32, out_rows) * U_JACK_H + U_PAD - 1.0f };
            for i32 i = 0; i < d.n_outputs; i++ {
                f32 cx = left + (cast(f32, i % c) + 0.5f) * U_CELL;
                f32 cy = out_top + cast(f32, i / c) * U_JACK_H + JACK_R + 6.0f;
                l.outs[info.base.slot0 + i] = float2{ cx, cy };
            }
            x += w + U_GAP;
        }
        if x - U_GAP > l.width { l.width = x - U_GAP; }
        y += row_h + U_ROW_GAP;
    }
    l.height = y - U_ROW_GAP;
}

// The module whose panel holds p, or -1.
i32 layout_module_at(Layout* l, float2 p) {
    for i32 m = 0; m < l.n_modules; m++ {
        if rect_contains(l.panels[m], p) { return m; }
    }
    return -1;
}
