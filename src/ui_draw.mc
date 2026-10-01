// ui_draw.mc: the rack on screen.
//
// Panels, knobs, jacks and cables are drawn with sokol_gl in rack units
// under the view transform, so they scale with zoom. Text is drawn in
// screen pixels through ui_text at a size taken from the zoom, so it
// stays sharp; the bar, tooltips and help line are screen pixels too.
//
// The look: black, white and one red. Flat panels a little lighter than
// the canvas, white type, grey for what is secondary, red for values,
// activity and the plug in hand. Cables are the one place with a range
// of colours, and they stay within reds and greys.

import sokol_all;
import sokol_gl;
import math;
import str;
import dsp_math;
import profile;
import engine_core;
import engine_cmd;
import engine;
import patch;
import ui_layout;
import ui_view;
import ui_cables;
import ui_state;
import ui_text;

// ---- palette ----

const float3 C_BG         = float3{ 0.07f, 0.07f, 0.07f };
const float3 C_PANEL      = float3{ 0.125f, 0.125f, 0.125f };
const float3 C_PANEL_EDGE = float3{ 0.22f, 0.22f, 0.22f };
const float3 C_BAND       = float3{ 0.09f, 0.09f, 0.09f };  // the outputs' band
const float3 C_BAR        = float3{ 0.0f, 0.0f, 0.0f };
const float3 C_BUTTON     = float3{ 0.15f, 0.15f, 0.15f };
const float3 C_BUTTON_HOT = float3{ 0.26f, 0.26f, 0.26f };
const float3 C_TEXT       = float3{ 0.96f, 0.96f, 0.96f };  // titles, values, button labels
const float3 C_LABEL      = float3{ 0.66f, 0.66f, 0.66f };  // knob and jack names, status
const float3 C_QUIET      = float3{ 0.40f, 0.40f, 0.40f };  // help, inactive positions, disabled buttons
const float3 C_KNOB       = float3{ 0.19f, 0.19f, 0.19f };
const float3 C_TRACK      = float3{ 0.30f, 0.30f, 0.30f };
const float3 C_RED        = float3{ 0.90f, 0.13f, 0.15f };
const float3 C_RED_DARK   = float3{ 0.55f, 0.08f, 0.10f };
const float3 C_WHITE      = float3{ 1.0f, 1.0f, 1.0f };
const float3 C_BLACK      = float3{ 0.0f, 0.0f, 0.0f };
const float3 C_ACCENT = C_RED;
const float3 C_WARN = C_RED;

// Jacks by class: white for audio, red for pitch, greys for CV, salmon
// for triggers.
float3 class_color(i32 cls) {
    if cls == CLS_AUDIO { return C_TEXT; }
    if cls == CLS_PITCH { return C_RED; }
    if cls == CLS_CV_UNI { return float3{ 0.72f, 0.72f, 0.72f }; }
    if cls == CLS_CV_BI { return float3{ 0.50f, 0.50f, 0.50f }; }
    return float3{ 0.95f, 0.45f, 0.42f };
}

// Text sizes in rack units at zoom 1.
const f32 T_TITLE = 13.0f;
const f32 T_LABEL = 12.5f;
const f32 T_LABEL_W = U_CELL - 4.0f;    // a label shrinks to fit its cell

// What the bar shows besides the patch.
struct UiStatus {
    f32 cpu;                            // callback load, 0..1
    bool audio_ok;
    bool switching;
    f32 dt;                             // seconds since the last frame
    bool* held;                         // per MIDI note, down on the computer keyboard (128), or null
    str file;                           // the patch's name, for the status row
    bool dirty;                         // it has changes not saved
}

sgl_pipeline g_ui_pip;

void ui_draw_setup() {
    // sokol_gl's default pipeline doesn't blend; cables and highlights do.
    g_ui_pip = sgl_make_pipeline(&sg_pipeline_desc{
        .colors[0].blend.enabled = true,
        .colors[0].blend.src_factor_rgb = SG_BLENDFACTOR_SRC_ALPHA,
        .colors[0].blend.dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
    });
}

// ---- primitives, in the current sokol_gl space ----

private void color(float3 c, f32 a) { sgl_c4f(c.r, c.g, c.b, a); }

void fill_rect(f32 x, f32 y, f32 w, f32 h, float3 c, f32 a) {
    sgl_begin_quads();
    color(c, a);
    sgl_v2f(x, y);
    sgl_v2f(x + w, y);
    sgl_v2f(x + w, y + h);
    sgl_v2f(x, y + h);
    sgl_end();
}

// A one-unit outline just inside r.
void stroke_rect(Rect r, f32 t, float3 c, f32 a) {
    fill_rect(r.x, r.y, r.w, t, c, a);
    fill_rect(r.x, r.y + r.h - t, r.w, t, c, a);
    fill_rect(r.x, r.y + t, t, r.h - 2.0f * t, c, a);
    fill_rect(r.x + r.w - t, r.y + t, t, r.h - 2.0f * t, c, a);
}

private void fan(float2 c, f32 r, f32 a0, f32 a1, i32 segs, float3 col, f32 a) {
    sgl_begin_triangles();
    color(col, a);
    for i32 i = 0; i < segs; i++ {
        f32 t0 = a0 + (a1 - a0) * cast(f32, i) / cast(f32, segs);
        f32 t1 = a0 + (a1 - a0) * cast(f32, i + 1) / cast(f32, segs);
        sgl_v2f(c.x, c.y);
        sgl_v2f(c.x + cosf(t0) * r, c.y + sinf(t0) * r);
        sgl_v2f(c.x + cosf(t1) * r, c.y + sinf(t1) * r);
    }
    sgl_end();
}

void fill_disc(float2 c, f32 r, float3 col, f32 a) { fan(c, r, 0.0f, TWO_PI, 32, col, a); }

void fill_arc(float2 c, f32 r0, f32 r1, f32 a0, f32 a1, float3 col, f32 a) {
    i32 segs = cast(i32, fabsf(a1 - a0) / TWO_PI * 48.0f) + 2;
    sgl_begin_triangle_strip();
    color(col, a);
    for i32 i = 0; i <= segs; i++ {
        f32 t = a0 + (a1 - a0) * cast(f32, i) / cast(f32, segs);
        sgl_v2f(c.x + cosf(t) * r0, c.y + sinf(t) * r0);
        sgl_v2f(c.x + cosf(t) * r1, c.y + sinf(t) * r1);
    }
    sgl_end();
}

void fill_ring(float2 c, f32 r0, f32 r1, float3 col, f32 a) { fill_arc(c, r0, r1, 0.0f, TWO_PI, col, a); }

void fill_round_rect(Rect r, f32 rad, float3 c, f32 a) {
    fill_rect(r.x + rad, r.y, r.w - 2.0f * rad, r.h, c, a);
    fill_rect(r.x, r.y + rad, rad, r.h - 2.0f * rad, c, a);
    fill_rect(r.x + r.w - rad, r.y + rad, rad, r.h - 2.0f * rad, c, a);
    fan(float2{ r.x + rad, r.y + rad }, rad, PI, 1.5f * PI, 6, c, a);
    fan(float2{ r.x + r.w - rad, r.y + rad }, rad, 1.5f * PI, TWO_PI, 6, c, a);
    fan(float2{ r.x + r.w - rad, r.y + r.h - rad }, rad, 0.0f, 0.5f * PI, 6, c, a);
    fan(float2{ r.x + rad, r.y + r.h - rad }, rad, 0.5f * PI, PI, 6, c, a);
}

// A polyline `w` wide as one triangle strip, with each joint on the
// average of its segments' normals.
void stroke_path(float2* pts, i32 n, f32 w, float3 col, f32 a) {
    if n < 2 { return; }
    sgl_begin_triangle_strip();
    color(col, a);
    f32 hw = 0.5f * w;
    for i32 i = 0; i < n; i++ {
        float2 d = float2{ 0.0f, 0.0f };
        if i > 0 { d = d + (pts[i] - pts[i - 1]); }
        if i + 1 < n { d = d + (pts[i + 1] - pts[i]); }
        f32 len = sqrtf(d.x * d.x + d.y * d.y);
        float2 nrm = float2{ 0.0f, 1.0f };
        if len > 0.0f { nrm = float2{ -d.y / len, d.x / len }; }
        sgl_v2f(pts[i].x + nrm.x * hw, pts[i].y + nrm.y * hw);
        sgl_v2f(pts[i].x - nrm.x * hw, pts[i].y - nrm.y * hw);
    }
    sgl_end();
}

void stroke_line(float2 p0, float2 p1, f32 w, float3 col, f32 a) {
    float2[2] pts = { p0, p1 };
    stroke_path(&pts[0], 2, w, col, a);
}

// ---- text on the rack ----

// Text at a rack position, `size` units tall at zoom 1, drawn in screen
// pixels so it stays sharp at any zoom. With max_w > 0 the text shrinks
// until it fits that many units.
private void rack_text(Ui* ui, float2 pos, str s, f32 size, f32 max_w, i32 weight, float3 col, f32 a, i32 align) {
    float2 sp = view_to_screen(&ui.view, pos);
    f32 px = size * ui.view.zoom;
    if max_w > 0.0f {
        f32 w = text_width(s, px, weight);
        if w > max_w * ui.view.zoom { px *= max_w * ui.view.zoom / w; }
    }
    sgl_push_matrix();
    sgl_load_identity();
    text_draw(sp.x, sp.y, s, px, weight, col, a, align);
    sgl_pop_matrix();
}

// A port or knob name for display: underscores read as spaces.
private str display_name(str name, u8* buf, i32 cap) {
    i32 n = 0;
    for i32 i = 0; i < name.len && n < cap; i++ {
        buf[n] = name.data[i] == '_' ? ' ' : name.data[i];
        n++;
    }
    return str_from(buf, n);
}

// ---- names ----

// A panel's title: its kind, with the instance number when the id ends in
// one ("ENV 2").
str panel_title(ModuleInfo* info, u8* buf, i32 cap) {
    str k = info.desc.kind;
    i32 n = 0;
    for i32 i = 0; i < k.len && n < cap; i++ {
        buf[n] = k.data[i];
        n++;
    }
    u8 last = info.id.data[info.id.len - 1];
    if last >= '0' && last <= '9' && n + 2 <= cap {
        buf[n] = ' ';
        buf[n + 1] = last;
        n += 2;
    }
    return str_from(buf, n);
}

i32 module_of_param(Engine* e, i32 k) {
    for i32 m = 0; m < e.n_modules; m++ {
        ModuleInfo* info = &e.modules[m];
        if k >= info.base.param0 && k < info.base.param0 + info.desc.n_params { return m; }
    }
    return -1;
}

str in_name(Engine* e, i32 j) {
    ModuleInfo* info = &e.modules[e.core.jacks[j].module];
    return info.desc.inputs[j - info.base.jack0].name;
}

str out_name(Engine* e, i32 s) {
    ModuleInfo* info = &e.modules[e.core.slot_module[s]];
    return info.desc.outputs[s - info.base.slot0].name;
}

// ---- rack parts ----

const f32 KNOB_START = 2.35619449f;     // 0.75 pi: bottom left
const f32 KNOB_SWEEP = 4.71238898f;     // 1.5 pi, clockwise on screen

private f32 knob_angle(f32 n) { return KNOB_START + n * KNOB_SWEEP; }

private void draw_knob(Ui* ui, Patch* p, Engine* e, i32 k, float2 c, str name) {
    Param* q = &e.core.params[k];
    f32 n = p.params[k];
    bool hot = (ui.hover == HOVER_KNOB && ui.hover_index == k) || (ui.drag == DRAG_KNOB && ui.knob == k);
    if q.steps == 1 {
        // A button: a ring, filled red while held.
        fill_ring(c, KNOB_R * 0.6f, KNOB_R * 0.72f, C_TRACK, 1.0f);
        fill_disc(c, KNOB_R * 0.6f, n > 0.5f ? C_RED : C_KNOB, 1.0f);
    } else if q.steps > 1 {
        // A switch: a pill with one dot per position, the current one red.
        i32 idx = cast(i32, floorf(n * cast(f32, q.steps - 1) + 0.5f));
        f32 gap = SWITCH_GAP;
        f32 x0 = c.x - 0.5f * gap * cast(f32, q.steps - 1);
        Rect pill = Rect{ x0 - SWITCH_R, c.y - SWITCH_R, gap * cast(f32, q.steps - 1) + 2.0f * SWITCH_R, 2.0f * SWITCH_R };
        if hot { fill_round_rect(Rect{ pill.x - 2.5f, pill.y - 2.5f, pill.w + 5.0f, pill.h + 5.0f }, SWITCH_R + 2.5f, C_WHITE, 0.35f); }
        fill_round_rect(pill, SWITCH_R, C_KNOB, 1.0f);
        for i32 i = 0; i < q.steps; i++ {
            float2 d = float2{ x0 + gap * cast(f32, i), c.y };
            if i == idx { fill_disc(d, 3.4f, C_RED, 1.0f); }
            else { fill_disc(d, 1.8f, C_QUIET, 1.0f); }
        }
    } else {
        // A knob: a dark disc, a grey track, the value in red, a white pointer.
        fill_disc(c, KNOB_R * 0.76f, C_KNOB, 1.0f);
        fill_arc(c, KNOB_R * 0.86f, KNOB_R, KNOB_START, KNOB_START + KNOB_SWEEP, C_TRACK, 1.0f);
        // Bipolar knobs fill from their zero; the rest from the bottom.
        f32 zero = 0.0f;
        if q.lo < 0.0f && q.hi > 0.0f { zero = param_unmap(q, 0.0f); }
        f32 a0 = knob_angle(zero);
        f32 a1 = knob_angle(n);
        if a1 < a0 {
            f32 t = a0;
            a0 = a1;
            a1 = t;
        }
        fill_arc(c, KNOB_R * 0.86f, KNOB_R, a0, a1, C_RED, 1.0f);
        f32 an = knob_angle(n);
        stroke_line(c + float2{ cosf(an), sinf(an) } * (KNOB_R * 0.3f), c + float2{ cosf(an), sinf(an) } * (KNOB_R * 0.72f), 2.2f, C_WHITE, 1.0f);
    }
    if hot && q.steps == 1 { fill_ring(c, KNOB_R * 0.72f + 1.0f, KNOB_R * 0.72f + 2.5f, C_WHITE, 0.35f); }
    if hot && q.steps == 0 { fill_ring(c, KNOB_R + 1.5f, KNOB_R + 3.0f, C_WHITE, 0.35f); }
    u8[32] buf;
    rack_text(ui, c + float2{ 0.0f, KNOB_R + 9.0f }, display_name(name, &buf[0], 32), T_LABEL, T_LABEL_W, TEXT_REGULAR, C_LABEL, 1.0f, TEXT_CENTER);
}

// How a jack should look right now: dimmed while it can't take the plug
// in hand, lit when it can.
private f32 jack_state(Ui* ui, Patch* p, Engine* e, bool input, i32 index) {
    if !ui_dragging_cable(ui) { return 0.0f; }
    if ui_loose_is_input(ui) != input { return -1.0f; }
    bool ok = false;
    if input { ok = ui_valid_in(ui, p, e, index); } else { ok = ui_valid_out(ui, p, e, index); }
    if ok { return 1.0f; }
    return -1.0f;
}

private void draw_jack(Ui* ui, Patch* p, Engine* e, bool input, i32 index, float2 c, i32 cls, str name) {
    float3 col = class_color(cls);
    f32 st = jack_state(ui, p, e, input, index);
    f32 a = 1.0f;
    if st < 0.0f { a = 0.3f; }
    bool square = p.profile == PROFILE_VINTAGE && cls == CLS_TRIG;
    if square {
        Rect r = Rect{ c.x - JACK_R, c.y - JACK_R, 2.0f * JACK_R, 2.0f * JACK_R };
        if input {
            fill_round_rect(r, 2.5f, col, a);
            fill_round_rect(Rect{ r.x + 2.5f, r.y + 2.5f, r.w - 5.0f, r.h - 5.0f }, 1.5f, C_BLACK, a);
        } else {
            fill_round_rect(r, 2.5f, col, a);
            fill_round_rect(Rect{ c.x - 2.0f, c.y - 2.0f, 4.0f, 4.0f }, 1.0f, C_BLACK, a);
        }
    } else if input {
        fill_ring(c, JACK_R - 2.5f, JACK_R, col, a);
        fill_disc(c, JACK_R - 2.5f, C_BLACK, a);
    } else {
        fill_disc(c, JACK_R, col, a);
        fill_disc(c, 2.2f, C_BLACK, a);
    }
    bool hovered = (input && ui.hover == HOVER_IN && ui.hover_index == index) || (!input && ui.hover == HOVER_OUT && ui.hover_index == index);
    bool snapped = ui_dragging_cable(ui) && ui.snap == index && ui_loose_is_input(ui) == input;
    if st > 0.0f { fill_ring(c, JACK_R + 2.0f, JACK_R + 3.5f, C_RED, 0.7f); }
    if hovered || snapped { fill_ring(c, JACK_R + 2.0f, JACK_R + 3.5f, C_WHITE, 0.85f); }
    u8[32] buf;
    rack_text(ui, c + float2{ 0.0f, JACK_R + 8.0f }, display_name(name, &buf[0], 32), T_LABEL, T_LABEL_W, TEXT_REGULAR, C_LABEL, a, TEXT_CENTER);
}

// The sounding step's column, behind its knobs.
private void draw_seq_step(Ui* ui, Engine* e, ModuleInfo* info) {
    i32 step = clampi(tele_state(&e.tele, info.base.id), 0, SEQ_STEPS - 1);
    float2 top = ui.layout.knobs[info.base.param0 + SEQ_P_A1 + step];
    float2 bottom = ui.layout.knobs[info.base.param0 + SEQ_P_MODE1 + step];
    Rect r = Rect{ top.x - 0.5f * U_CELL + 3.0f, top.y - KNOB_R - 5.0f, U_CELL - 6.0f, bottom.y - top.y + 2.0f * KNOB_R + 10.0f };
    fill_round_rect(r, 4.0f, C_RED, 0.18f);
}

// The step switch's stage: rings on its A, B or C input and output.
private void draw_stage(Ui* ui, Engine* e, ModuleInfo* info) {
    i32 st = clampi(tele_state(&e.tele, info.base.id), 0, 2);
    fill_ring(ui.layout.ins[info.base.jack0 + STEPSW_IN_A + st], JACK_R + 2.5f, JACK_R + 4.0f, C_RED, 0.9f);
    fill_ring(ui.layout.outs[info.base.slot0 + STEPSW_OUT_A + st], JACK_R + 2.5f, JACK_R + 4.0f, C_RED, 0.9f);
}

// The scope's screen: the newest full screen that starts on a rising
// crossing of LEVEL on channel A, or the newest screen when none does.
// The level is drawn as a red line, so the knob is seen to move; at the
// bottom of its travel the trigger is off and the trace runs free. A is
// always drawn (the output until a cable goes in); B when patched.
private void draw_scope(Ui* ui, Patch* p, Engine* e, ModuleInfo* info, Rect r) {
    fill_rect(r.x, r.y, r.w, r.h, C_BLACK, 1.0f);
    stroke_rect(r, 1.0f, C_PANEL_EDGE, 1.0f);
    f32 mid = r.y + 0.5f * r.h;
    f32 half = 0.5f * r.h - 5.0f;
    fill_rect(r.x + 4.0f, mid, r.w - 8.0f, 1.0f, C_QUIET, 0.7f);
    fill_rect(r.x + 4.0f, mid - half, r.w - 8.0f, 1.0f, C_QUIET, 0.3f);
    fill_rect(r.x + 4.0f, mid + half, r.w - 8.0f, 1.0f, C_QUIET, 0.3f);
    Telemetry* t = &e.tele;
    u32 w = atomic_load(&t.scope_w, ACQUIRE);
    i32 p0 = info.base.param0;
    f32 level = param_map(&e.core.params[p0 + SCOPE_P_LEVEL], p.params[p0 + SCOPE_P_LEVEL]);
    f32 range = SCOPE_RANGES[clampi(cast(i32, param_map(&e.core.params[p0 + SCOPE_P_RANGE], p.params[p0 + SCOPE_P_RANGE]) + 0.5f), 0, 2)];
    bool trig = p.params[p0 + SCOPE_P_LEVEL] > 0.0f;
    u32 start = w - cast(u32, SCOPE_SCREEN);
    if trig {
        for i32 back = 0; back < SCOPE_LEN - 2 * SCOPE_SCREEN; back++ {
            u32 s = w - cast(u32, SCOPE_SCREEN + back);
            if t.scope[0][(s - 1) & SCOPE_MASK] < level && t.scope[0][s & SCOPE_MASK] >= level {
                start = s;
                break;
            }
        }
        f32 ly = mid - clampf(level / range, -1.0f, 1.0f) * half;
        fill_rect(r.x + 4.0f, ly - 0.5f, r.w - 8.0f, 1.0f, C_RED, 0.55f);
    }
    float2[257] pts;
    for i32 ch = 0; ch < 2; ch++ {
        if ch == 1 && patch_count_into(p, info.base.jack0 + ch) == 0 { continue; }
        for i32 i = 0; i <= 256; i++ {
            f32 v = t.scope[ch][(start + cast(u32, i * SCOPE_SCREEN / 256)) & SCOPE_MASK];
            pts[i] = float2{ r.x + 4.0f + (r.w - 8.0f) * cast(f32, i) / 256.0f, mid - clampf(v / range, -1.0f, 1.0f) * half };
        }
        float3 col = C_TEXT;
        if ch == 1 { col = C_RED; }
        stroke_path(&pts[0], 257, 1.5f, col, 1.0f);
    }
}

private void draw_panels(Ui* ui, Patch* p, Engine* e, bool* held) {
    u8[32] buf;
    for i32 m = 0; m < e.n_modules; m++ {
        ModuleInfo* info = &e.modules[m];
        Rect r = ui.layout.panels[m];
        fill_rect(r.x, r.y, r.w, r.h, C_PANEL, 1.0f);
        stroke_rect(r, 1.0f, C_PANEL_EDGE, 1.0f);
        if info.desc.n_outputs > 0 {
            Rect b = ui.layout.out_bands[m];
            fill_rect(r.x + 1.0f, b.y, r.w - 2.0f, r.y + r.h - 1.0f - b.y, C_BAND, 1.0f);
            fill_rect(r.x + 1.0f, b.y, r.w - 2.0f, 1.0f, C_PANEL_EDGE, 1.0f);
        }
        rack_text(ui, float2{ r.x + U_PAD, r.y + 0.5f * U_HEAD }, panel_title(info, &buf[0], 32), T_TITLE, 0.0f, TEXT_BOLD, C_TEXT, 1.0f, TEXT_LEFT);
        if info.kind == KIND_SEQ { draw_seq_step(ui, e, info); }
        if info.kind == KIND_KEYS { draw_keys_piano(ui, info, held); }
        for i32 i = 0; i < info.desc.n_params; i++ {
            i32 k = info.base.param0 + i;
            draw_knob(ui, p, e, k, ui.layout.knobs[k], info.desc.params[i].name);
        }
        for i32 i = 0; i < info.desc.n_inputs; i++ {
            i32 j = info.base.jack0 + i;
            draw_jack(ui, p, e, true, j, ui.layout.ins[j], info.desc.inputs[i].cls, info.desc.inputs[i].name);
        }
        for i32 i = 0; i < info.desc.n_outputs; i++ {
            i32 s = info.base.slot0 + i;
            draw_jack(ui, p, e, false, s, ui.layout.outs[s], info.desc.outputs[i].cls, info.desc.outputs[i].name);
        }
        if info.kind == KIND_STEPSW { draw_stage(ui, e, info); }
        if info.kind == KIND_SCOPE { draw_scope(ui, p, e, info, ui.layout.displays[m]); }
    }
}

// ---- cables ----

const f32 RIM_W = 2.0f;                 // the white rim's width beyond the cable, each side
const f32 PULSE_LEN = 0.22f;            // a pulse's length as a fraction of the cable
const f32 PULSE_W = 0.4f;               // and its width, as a fraction of the cable's

// A cable: its shadow, a white rim while hovered, the cable itself, and a
// thin white line where a pulse is passing (a change at its source). A
// cable carrying voices is drawn wider.
const f32 POLY_W = 1.7f;

// The cable between positions t0 and t1, measured in segments from its
// output end (fractions allowed), stroked w wide.
private void stroke_span(CablePath* path, f32 t0, f32 t1, f32 w, float3 col, f32 a) {
    f32 n = cast(f32, CABLE_SEGS);
    t0 = clampf(t0, 0.0f, n);
    t1 = clampf(t1, 0.0f, n);
    if t1 - t0 < 0.05f { return; }
    float2[CABLE_SEGS + 2] pts;
    i32 k0 = cast(i32, floorf(t0));
    i32 k1 = cast(i32, ceilf(t1));
    i32 m = 0;
    for i32 k = k0; k <= k1; k++ {
        f32 t = clampf(cast(f32, k), t0, t1);
        i32 i = clampi(cast(i32, floorf(t)), 0, CABLE_SEGS - 1);
        f32 f = t - cast(f32, i);
        pts[m] = path.pts[i] + (path.pts[i + 1] - path.pts[i]) * f;
        m++;
    }
    stroke_path(&pts[0], m, w, col, a);
}                // width of a poly cable, in mono widths

private void draw_cable_path(CablePath* path, float3 col, f32 alpha, f32 glow, f32 pulse, bool hot, bool poly) {
    f32 cw = poly ? POLY_W * CABLE_W : CABLE_W;
    float2[CABLE_SEGS + 1] shadow;
    for i32 i = 0; i <= CABLE_SEGS; i++ { shadow[i] = path.pts[i] + float2{ 1.0f, 2.5f }; }
    stroke_path(&shadow[0], CABLE_SEGS + 1, cw + 1.0f, C_BLACK, 0.4f * alpha);
    ignore glow;
    if hot { stroke_path(&path.pts[0], CABLE_SEGS + 1, cw + 2.0f * RIM_W, C_WHITE, 0.9f * alpha); }
    float3 edge = cable_edge(col, CABLE_EDGE_MIN);
    if edge.r != col.r { stroke_path(&path.pts[0], CABLE_SEGS + 1, cw + 1.6f, edge, alpha); }
    stroke_path(&path.pts[0], CABLE_SEGS + 1, cw, col, alpha);
    if pulse >= 0.0f {
        // A thin white line along the middle of the cable, its ends placed
        // between points so it glides rather than steps: dim at full length,
        // with a brighter core over the middle half for soft ends.
        f32 at = pulse * cast(f32, CABLE_SEGS);
        f32 half = 0.5f * PULSE_LEN * cast(f32, CABLE_SEGS);
        f32 w = PULSE_W * cw;
        stroke_span(path, at - half, at + half, w, C_WHITE, 0.5f * alpha);
        stroke_span(path, at - 0.5f * half, at + 0.5f * half, w, C_WHITE, 0.6f * alpha);
    }
}

private void draw_plug(float2 c, float3 col, f32 alpha) {
    fill_disc(c, PLUG_R, cable_edge(col * 0.5f, 0.8f * CABLE_EDGE_MIN), alpha);
    fill_disc(c, PLUG_R - 2.0f, col, alpha);
}

// Whether cable i is drawn this pass, and how bright: everything dims
// but the focused module's cables, which come on top.
private bool cable_visible(Ui* ui, Patch* p, Engine* e, i32 i, i32 focus, i32 pass, f32* a) {
    if cable_in_hand(ui, i) { return false; }
    Cable c = p.cables[i];
    bool mine = focus >= 0 && (e.core.slot_module[c.src] == focus || e.core.jacks[c.dst].module == focus);
    if focus >= 0 && (pass == 1) != mine { return false; }
    if focus < 0 && pass == 1 { return false; }
    if focus >= 0 && !mine { *a *= 0.25f; }
    return true;
}

private bool cable_in_hand(Ui* ui, i32 i) {
    return (ui.drag == DRAG_MOVE_DST || ui.drag == DRAG_MOVE_SRC) && ui.fixed == i;
}

private void draw_cables(Ui* ui, Patch* p, Engine* e) {
    if ui.cable_vis == VIS_HIDDEN && !ui_dragging_cable(ui) { return; }
    f32 alpha = 1.0f;
    if ui.cable_vis == VIS_TRANSLUCENT { alpha = 0.35f; }
    i32 focus = -1;
    if ui.focus { focus = layout_module_at(&ui.layout, view_to_rack(&ui.view, ui.mouse)); }
    CablePath path;
    // Two passes when focusing: everything else dim, then the focused
    // module's cables on top. Every plug is drawn before any cable, so the
    // cables run over the plugs.
    for i32 pass = 0; pass < 2; pass++ {
        for i32 i = 0; i < p.n_cables; i++ {
            f32 a = alpha;
            if !cable_visible(ui, p, e, i, focus, pass, &a) { continue; }
            Cable c = p.cables[i];
            draw_plug(ui.layout.outs[c.src], CABLE_COLORS[c.color], a);
            draw_plug(ui.layout.ins[c.dst], CABLE_COLORS[c.color], a);
        }
        for i32 i = 0; i < p.n_cables; i++ {
            f32 a = alpha;
            if !cable_visible(ui, p, e, i, focus, pass, &a) { continue; }
            Cable c = p.cables[i];
            bool hot = ui.hover == HOVER_CABLE && ui.hover_index == i;
            f32 pulse = i < ui.n_ropes ? ui.pulse[i] : -1.0f;
            ignore ui_cable_shape(ui, p, i, &path);
            draw_cable_path(&path, CABLE_COLORS[c.color], a, ui.glow[c.src], pulse, hot, tele_channels(&e.tele, c.src) > 1);
        }
    }

    // The cable in hand runs from its fixed end to the mouse, or to the
    // jack it will land on.
    if !ui_dragging_cable(ui) { return; }
    float2 fixed_pos = float2{ 0.0f, 0.0f };
    float3 col = CABLE_COLORS[p.next_color];
    if ui.drag == DRAG_FROM_OUT { fixed_pos = ui.layout.outs[ui.fixed]; }
    else if ui.drag == DRAG_FROM_IN { fixed_pos = ui.layout.ins[ui.fixed]; }
    else if ui.drag == DRAG_MOVE_DST {
        fixed_pos = ui.layout.outs[p.cables[ui.fixed].src];
        col = CABLE_COLORS[p.cables[ui.fixed].color];
    } else {
        fixed_pos = ui.layout.ins[p.cables[ui.fixed].dst];
        col = CABLE_COLORS[p.cables[ui.fixed].color];
    }
    float2 loose = ui.loose;
    if ui.snap >= 0 {
        if ui_loose_is_input(ui) { loose = ui.layout.ins[ui.snap]; } else { loose = ui.layout.outs[ui.snap]; }
    }
    if ui.hand_live { ui_hand_shape(ui, &path); }
    else if ui_loose_is_input(ui) { cable_path(&path, fixed_pos, loose); }
    else { cable_path(&path, loose, fixed_pos); }
    draw_plug(fixed_pos, col, 1.0f);
    draw_plug(loose, col, 1.0f);
    draw_cable_path(&path, col, 1.0f, 0.0f, -1.0f, false, false);
}

// ---- screen overlays ----

private void draw_bar(Ui* ui, Patch* p, Engine* e, UiStatus st) {
    f32 w = ui.view.screen_w;
    f32 h = ui_bar_height(ui);
    f32 px = ui.text_px;
    fill_rect(0.0f, 0.0f, w, h, C_BAR, 1.0f);
    fill_rect(0.0f, h - 1.0f, w, 1.0f, C_PANEL_EDGE, 1.0f);
    text_draw(px, 0.5f * h, "minc-synth", px, TEXT_BOLD, C_TEXT, 1.0f, TEXT_LEFT);

    str[10] labels = { "MODERN", "SMOOTH", "2X NORMAL", "UNDO", "REDO", "FIT", "SAVE", "LOAD", "PRESET", "HELP" };
    if p.profile == PROFILE_VINTAGE { labels[0] = "VINTAGE"; }
    if p.feel == FEEL_AUTHENTIC { labels[1] = "AUTHENTIC"; }
    if e.os == 4 { labels[2] = "4X HIGH"; }
    else if e.os == 1 { labels[2] = "1X"; }
    for i32 i = 0; i < BAR_COUNT; i++ {
        Rect r = ui.buttons[i];
        bool hot = (ui.hover == HOVER_BUTTON && ui.hover_index == i) || (i == BAR_HELP && ui.help_open);
        bool off = (i == BAR_UNDO && p.n_undo == 0) || (i == BAR_REDO && p.n_redo == 0);
        f32 inset = floorf(0.2f * h);
        fill_round_rect(Rect{ r.x, r.y + inset, r.w, r.h - 2.0f * inset }, 3.0f * ui.dpi, hot ? C_BUTTON_HOT : C_BUTTON, 1.0f);
        float3 col = C_TEXT;
        if off { col = C_QUIET; }
        if i == BAR_QUALITY && st.switching { col = C_RED; }
        text_draw(r.x + 0.5f * r.w, 0.5f * h, labels[i], px * 0.85f, TEXT_BOLD, col, 1.0f, TEXT_CENTER);
    }

    // Status on the row under the bar, right-aligned; a notice on the left.
    string status = format("cpu {}%   {} cables", cast(i32, st.cpu * 100.0f + 0.5f), p.n_cables);
    defer free(status);
    str s = str_from(status.data, status.len);
    float2 at = ui_status_pos(ui, s.len);
    f32 right = w - px;
    text_draw(right, at.y, s, px, TEXT_REGULAR, C_LABEL, 1.0f, TEXT_RIGHT);
    // On the left the patch's name, a dot after it while changes are
    // unsaved; a notice takes its place for a moment.
    if ui.notice_left > 0.0f {
        ui.notice_left -= st.dt;
        text_draw(px, at.y, str_from(&ui.notice[0], ui.notice_len), px, TEXT_REGULAR, C_LABEL, 1.0f, TEXT_LEFT);
    } else if st.file.len > 0 {
        text_draw(px, at.y, st.file, px, TEXT_REGULAR, C_LABEL, 1.0f, TEXT_LEFT);
        if st.dirty {
            f32 fw = text_width(st.file, px, TEXT_REGULAR);
            fill_disc(float2{ px + fw + 0.6f * px, at.y }, 0.22f * px, C_RED, 1.0f);
        }
    }
    u32 resets = atomic_load(&e.tele.nan_resets, RELAXED);
    if !st.audio_ok || resets > 0 {
        str warn = "NO AUDIO";
        if st.audio_ok { warn = "GUARD RESET"; }
        f32 sw = text_width(s, px, TEXT_REGULAR);
        text_draw(right - sw - 2.0f * px, at.y, warn, px, TEXT_BOLD, C_RED, 1.0f, TEXT_RIGHT);
    }
}

// The two octaves the computer keyboard plays, C3 to C5, as piano keys
// with their letters: white keys along Z to comma and Q to I, sharps on
// the row above each. `w` is a white key's width; the rest follows from
// it. In rack units under the view transform when `rack`, else in screen
// pixels. The note `lit` (MIDI, or -1) is drawn red.
const str KEYS_WHITE_LOWER = "ZXCVBNM";
const str KEYS_WHITE_UPPER = "QWERTYUI";
const str KEYS_BLACK_LOWER = "SDGHJ";
const str KEYS_BLACK_UPPER = "23567";
const f32 PIANO_KEYS = 15.0f;           // white keys, C3 to C5
const f32 PIANO_H = 2.8f;               // a white key's height, in widths
const float3 C_PIANO_WHITE = float3{ 0.80f, 0.80f, 0.80f };   // a little under the text's white

private void piano_letter(Ui* ui, bool rack, f32 x, f32 y, str s, f32 size, float3 col) {
    if rack { rack_text(ui, float2{ x, y }, s, size, 0.0f, TEXT_BOLD, col, 1.0f, TEXT_CENTER); }
    else { text_draw(x, y, s, size, TEXT_BOLD, col, 1.0f, TEXT_CENTER); }
}

private void draw_piano(Ui* ui, bool rack, f32 x0, f32 y0, f32 w, i32 lit) {
    f32 h = PIANO_H * w;
    f32 bw = 0.63f * w;
    f32 bh = 0.6f * h;
    f32 gap = rack ? 0.5f : 1.0f;
    i32[7] white_note = { 0, 2, 4, 5, 7, 9, 11 };
    bool[7] has_black = { true, true, false, true, true, true, false };
    for i32 i = 0; i < 15; i++ {
        bool down = 48 + 12 * (i / 7) + white_note[i % 7] == lit;
        f32 x = x0 + cast(f32, i) * w;
        fill_rect(x, y0, w - gap, h, down ? C_RED : C_PIANO_WHITE, 1.0f);
        str letter = i < 7 ? str_from(KEYS_WHITE_LOWER.data + i, 1) : str_from(KEYS_WHITE_UPPER.data + (i - 7), 1);
        piano_letter(ui, rack, x + 0.5f * (w - gap), y0 + h - 0.36f * w, letter, 0.53f * w, down ? C_WHITE : C_BLACK);
    }
    i32 k = 0;
    for i32 i = 0; i < 14; i++ {
        if !has_black[i % 7] { continue; }
        bool down = 48 + 12 * (i / 7) + white_note[i % 7] + 1 == lit;
        f32 x = x0 + cast(f32, i + 1) * w - 0.5f * bw - 0.5f * gap;
        fill_rect(x, y0, bw, bh, down ? C_RED : C_BLACK, 1.0f);
        str letter = k < 5 ? str_from(KEYS_BLACK_LOWER.data + k % 5, 1) : str_from(KEYS_BLACK_UPPER.data + k % 5, 1);
        piano_letter(ui, rack, x + 0.5f * bw, y0 + bh - 0.3f * w, letter, 0.47f * w, C_WHITE);
        k++;
    }
}

// One octave of eight white keys, C to C, with the letters of one row of
// the computer keyboard: `whites` on the white keys, `blacks` on the
// sharps. In rack units under the view transform. The notes down in
// `held` (128 entries, or null) are drawn red.
private void draw_octave(Ui* ui, f32 x0, f32 y0, f32 w, i32 base, str whites, str blacks, bool* held) {
    f32 h = PIANO_H * w;
    f32 bw = 0.63f * w;
    f32 bh = 0.6f * h;
    i32[8] white_note = { 0, 2, 4, 5, 7, 9, 11, 12 };
    bool[7] has_black = { true, true, false, true, true, true, false };
    for i32 i = 0; i < 8; i++ {
        bool down = held != null && held[base + white_note[i]];
        f32 x = x0 + cast(f32, i) * w;
        fill_rect(x, y0, w - 0.5f, h, down ? C_RED : C_PIANO_WHITE, 1.0f);
        piano_letter(ui, true, x + 0.5f * (w - 0.5f), y0 + h - 0.36f * w, str_from(whites.data + i, 1), 0.53f * w,
                     down ? C_WHITE : C_BLACK);
    }
    i32 k = 0;
    for i32 i = 0; i < 7; i++ {
        if !has_black[i] { continue; }
        bool down = held != null && held[base + white_note[i] + 1];
        f32 x = x0 + cast(f32, i + 1) * w - 0.5f * bw - 0.25f;
        fill_rect(x, y0, bw, bh, down ? C_RED : C_BLACK, 1.0f);
        piano_letter(ui, true, x + 0.5f * bw, y0 + bh - 0.3f * w, str_from(blacks.data + k, 1), 0.47f * w, C_WHITE);
        k++;
    }
}

// The key map on the KEYS panel, over its outputs: the two rows of the
// computer keyboard stacked as they sit, Q to I (C4) above Z to comma
// (C3), with every key that is down lit.
private void draw_keys_piano(Ui* ui, ModuleInfo* info, bool* held) {
    Rect r = ui.layout.panels[info.base.id];
    i32 cols = ui.layout.cols[info.base.id];
    i32 rows = (info.desc.n_params + cols - 1) / cols;
    // At the bottom of the panel, over the outputs, in a dark inset framed
    // like the scope's screen: eight keys with a key's width of margin.
    ignore rows;
    f32 w = r.w / 10.0f;
    f32 gap = 0.3f * w;
    f32 h = 2.0f * PIANO_H * w + gap;
    f32 band = ui.layout.out_bands[info.base.id].y;
    f32 y = band - w - h;                       // the inset's margin below matches the sides
    Rect inset = Rect{ r.x + 0.6f * w, y - 0.4f * w, 8.8f * w, h + 0.8f * w };
    fill_rect(inset.x, inset.y, inset.w, inset.h, C_BLACK, 1.0f);
    stroke_rect(inset, 0.7f, C_PANEL_EDGE, 1.0f);
    draw_octave(ui, r.x + w, y, w, 60, "QWERTYUI", "23567", held);
    draw_octave(ui, r.x + w, y + PIANO_H * w + gap, w, 48, "ZXCVBNM,", "SDGHJ", held);
}

private void draw_tooltip(Ui* ui, Patch* p, Engine* e) {
    if ui.drag == DRAG_PAN { return; }
    string t = string("");
    i32 k = -1;
    if ui.drag == DRAG_KNOB { k = ui.knob; }
    else if ui.hover == HOVER_KNOB { k = ui.hover_index; }
    if k >= 0 {
        i32 m = module_of_param(e, k);
        free(t);
        t = format("{}.{}  {}", e.modules[m].id, e.modules[m].desc.params[k - e.modules[m].base.param0].name,
                   cast(f64, param_map(&e.core.params[k], p.params[k])));
    } else if ui.hover == HOVER_IN {
        i32 j = ui.hover_index;
        free(t);
        t = format("{}.{}  in", e.modules[e.core.jacks[j].module].id, in_name(e, j));
    } else if ui.hover == HOVER_OUT {
        i32 s = ui.hover_index;
        free(t);
        t = format("{}.{}  out", e.modules[e.core.slot_module[s]].id, out_name(e, s));
    } else if ui.hover == HOVER_CABLE {
        Cable c = p.cables[ui.hover_index];
        free(t);
        t = format("{}.{} -> {}.{}", e.modules[e.core.slot_module[c.src]].id, out_name(e, c.src),
                   e.modules[e.core.jacks[c.dst].module].id, in_name(e, c.dst));
    }
    defer free(t);
    if t.len == 0 { return; }
    f32 px = ui.text_px;
    str s = str_from(t.data, t.len);
    f32 tw = text_width(s, px, TEXT_REGULAR);
    f32 x = ui.mouse.x + 14.0f * ui.dpi;
    f32 y = ui.mouse.y + 22.0f * ui.dpi;
    if x + tw + 2.0f * px > ui.view.screen_w { x = ui.view.screen_w - tw - 2.0f * px; }
    Rect box = Rect{ x - 0.6f * px, y - 0.85f * px, tw + 1.2f * px, 1.7f * px };
    fill_rect(box.x, box.y, box.w, box.h, C_BLACK, 0.94f);
    stroke_rect(box, 1.0f, C_PANEL_EDGE, 1.0f);
    text_draw(x, y, s, px, TEXT_REGULAR, C_TEXT, 1.0f, TEXT_LEFT);
}

// The help window from the bar's HELP button, over the dimmed rack.
private void draw_help(Ui* ui) {
    if !ui.help_open { return; }
    f32 px = ui.text_px;
    // The columns as the font sets them, for this layout and the clicks.
    ui.help_key_w = 0.0f;
    ui.help_what_w = 0.0f;
    for i32 i = 0; i < HELP_ROWS_N; i++ {
        if str_equal(HELP_ROWS[i].key, HELP_PIANO) { continue; }
        ui.help_key_w = maxf(ui.help_key_w, text_width(HELP_ROWS[i].key, px, TEXT_BOLD));
        ui.help_what_w = maxf(ui.help_what_w, text_width(HELP_ROWS[i].what, px, TEXT_REGULAR));
    }
    f32 bar = ui_bar_height(ui);
    fill_rect(0.0f, bar, ui.view.screen_w, ui.view.screen_h - bar, C_BLACK, 0.6f);
    HelpLayout l = ui_help_layout(ui);
    fill_rect(l.box.x, l.box.y, l.box.w, l.box.h, C_PANEL, 1.0f);
    stroke_rect(l.box, 1.0f, C_PANEL_EDGE, 1.0f);
    f32 title_y = l.top - 2.0f * l.row;
    text_draw(l.key_x, title_y, "HELP", px, TEXT_BOLD, C_TEXT, 1.0f, TEXT_LEFT);
    text_draw(l.box.x + l.box.w - (l.key_x - l.box.x), title_y, "Esc or a click outside closes", px, TEXT_REGULAR,
              C_QUIET, 1.0f, TEXT_RIGHT);
    f32 y = l.top;
    for i32 i = 0; i < HELP_ROWS_N; i++ {
        HelpRow r = HELP_ROWS[i];
        if str_equal(r.key, HELP_PIANO) {
            // The keyboard over its rows, with what it plays beside it.
            f32 pw = HELP_PIANO_FILL * cast(f32, HELP_PIANO_ROWS) * l.row / PIANO_H;
            draw_piano(ui, false, l.key_x, y - 0.5f * l.row, pw, -1);
            text_draw(maxf(l.what_x, l.key_x + PIANO_KEYS * pw + 1.5f * px), y - 0.5f * l.row + 0.5f * PIANO_H * pw, r.what, px,
                      TEXT_REGULAR, C_LABEL, 1.0f, TEXT_LEFT);
            y += cast(f32, HELP_PIANO_ROWS) * l.row;
            continue;
        }
        if r.key.len == 0 {
            if i > 0 { y += 0.5f * l.row; }
            text_draw(l.key_x, y, r.what, 0.85f * px, TEXT_BOLD, C_ACCENT, 1.0f, TEXT_LEFT);
        } else {
            text_draw(l.key_x, y, r.key, px, TEXT_BOLD, C_TEXT, 1.0f, TEXT_LEFT);
            text_draw(l.what_x, y, r.what, px, TEXT_REGULAR, C_LABEL, 1.0f, TEXT_LEFT);
        }
        y += l.row;
    }
}

// ---- the frame ----

void ui_draw_frame(Ui* ui, Patch* p, Engine* e, UiStatus st) {
    ui_update_glow(ui, p, e, st.dt);
    ui_update_ropes(ui, p, st.dt);
    f32 w = ui.view.screen_w;
    f32 h = ui.view.screen_h;
    sgl_defaults();
    sgl_load_pipeline(g_ui_pip);
    sgl_matrix_mode_projection();
    sgl_ortho(0.0f, w, h, 0.0f, -1.0f, 1.0f);
    sgl_matrix_mode_modelview();
    sgl_load_identity();
    sgl_scale(ui.view.zoom, ui.view.zoom, 1.0f);
    sgl_translate(-ui.view.pan.x, -ui.view.pan.y, 0.0f);
    draw_panels(ui, p, e, st.held);
    draw_cables(ui, p, e);

    sgl_load_identity();
    draw_bar(ui, p, e, st);
    draw_tooltip(ui, p, e);
    draw_help(ui);
    text_flush();
}
