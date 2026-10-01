// ui_text.mc: text on screen.
//
// Anti-aliased TrueType text through fontstash, drawn as sokol_gl quads
// so it lands in the same command stream as the shapes. Sizes are in
// screen pixels; rack labels pick theirs from the zoom. The faces are
// Liberation Sans Regular and Bold from fonts/, read at start; without
// them the 8x8 pixel font stands in, so the app still runs.
//
// The glyph atlas holds every size drawn so far. Sizes are rounded to
// whole pixels to keep that set small, and when the atlas fills it is
// reset, which costs one frame of re-rasterising.

import sokol_all;
import sokol_gl;
import fontstash;
import sokol_fontstash;
import sokol_debugtext_font;
import file;
import str;
import math;

enum TextWeight { TEXT_REGULAR, TEXT_BOLD }
enum TextAlign { TEXT_LEFT, TEXT_CENTER, TEXT_RIGHT }

const f32 TEXT_MIN_PX = 4.0f;           // smaller than this is not drawn
const i32 TEXT_ATLAS = 1024;            // at dpi 1; doubled for high dpi

private {
    FONScontext* g_fons = null;
    i32[2] g_font = { -1, -1 };
    FileData[2] g_font_data;
    i32 g_atlas = 0;

    void on_error(void* uptr, i32 error, i32 val) {
        ignore uptr;
        ignore val;
        if error == FONS_ATLAS_FULL && g_fons != null { ignore fonsResetAtlas(g_fons, g_atlas, g_atlas); }
    }

    i32 load_face(str dir, str file, str name, i32 slot) {
        string path = path_join(dir, file);
        defer free(path);
        g_font_data[slot] = file_read(str_from(path.data, path.len));
        if g_font_data[slot].data == null { return -1; }
        return fonsAddFontMem(g_fons, str_to_cstr(name), g_font_data[slot].data, cast(i32, g_font_data[slot].len), 0);
    }

    u32 rgba(float3 c, f32 a) {
        return sfons_rgba(cast(u8, c.r * 255.0f + 0.5f), cast(u8, c.g * 255.0f + 0.5f),
                          cast(u8, c.b * 255.0f + 0.5f), cast(u8, a * 255.0f + 0.5f));
    }

    f32 quantize(f32 px) {
        f32 q = floorf(px + 0.5f);
        if q < 1.0f { q = 1.0f; }
        return q;
    }

    // The 8x8 font, one quad per horizontal run of lit pixels, `cell`
    // pixels per glyph pixel. The glyphs are 6 wide in their 8 cells and
    // 7 tall, so a cell of size / 10 gives roughly the font's proportions.
    void pixel_text(f32 x, f32 y, str s, f32 px, float3 col, f32 a, i32 align) {
        f32 cell = px * 0.1f;
        f32 w = cast(f32, s.len) * 8.0f * cell;
        f32 x0 = x;
        if align == TEXT_CENTER { x0 = x - 0.5f * w; }
        else if align == TEXT_RIGHT { x0 = x - w; }
        f32 y0 = y - 4.0f * cell;
        sgl_begin_quads();
        sgl_c4f(col.r, col.g, col.b, a);
        for i32 k = 0; k < s.len; k++ {
            i32 ch = cast(i32, s.data[k]);
            if ch < 32 || ch > 127 { continue; }
            i32 idx = (ch - 32) * 8;
            f32 bx = x0 + cast(f32, k) * 8.0f * cell;
            for i32 row = 0; row < 8; row++ {
                i32 bits = cast(i32, font_data[idx + row]);
                i32 c = 0;
                while c < 8 {
                    if (bits & (128 >> c)) != 0 {
                        i32 run = c;
                        while c < 8 && (bits & (128 >> c)) != 0 { c++; }
                        f32 rx0 = bx + cast(f32, run) * cell;
                        f32 rx1 = bx + cast(f32, c) * cell;
                        f32 ry0 = y0 + cast(f32, row) * cell;
                        sgl_v2f(rx0, ry0);
                        sgl_v2f(rx1, ry0);
                        sgl_v2f(rx1, ry0 + cell);
                        sgl_v2f(rx0, ry0 + cell);
                    } else {
                        c++;
                    }
                }
            }
        }
        sgl_end();
    }
}

// sokol_debugtext_font draws its glyph runs through this; the fallback
// path above draws its own quads, so it is never called.
void draw_rect(f32 x, f32 y, f32 w, f32 h, f32 r, f32 g, f32 b) {
    sgl_begin_quads();
    sgl_c4f(r, g, b, 1.0f);
    sgl_v2f(x, y);
    sgl_v2f(x + w, y);
    sgl_v2f(x + w, y + h);
    sgl_v2f(x, y + h);
    sgl_end();
}

// Creates the font context and reads the faces. False when a face is
// missing; text then falls back to the pixel font.
bool text_setup(str dir, f32 dpi) {
    g_atlas = TEXT_ATLAS;
    if dpi > 1.5f { g_atlas = 2 * TEXT_ATLAS; }
    g_fons = sfons_create(&sfons_desc_t{ .width = g_atlas, .height = g_atlas });
    fonsSetErrorCallback(g_fons, on_error, null);
    g_font[TEXT_REGULAR] = load_face(dir, "LiberationSans-Regular.ttf", "sans", TEXT_REGULAR);
    g_font[TEXT_BOLD] = load_face(dir, "LiberationSans-Bold.ttf", "sans-bold", TEXT_BOLD);
    if g_font[TEXT_BOLD] < 0 { g_font[TEXT_BOLD] = g_font[TEXT_REGULAR]; }
    return g_font[TEXT_REGULAR] >= 0;
}

void text_shutdown() {
    if g_fons != null { sfons_destroy(g_fons); }
    g_fons = null;
    for i32 i = 0; i < 2; i++ {
        if g_font_data[i].data != null { free(g_font_data[i].data); }
        g_font_data[i].data = null;
    }
}

bool text_ready() { return g_fons != null && g_font[TEXT_REGULAR] >= 0; }

private void select(f32 px, i32 weight) {
    fonsSetFont(g_fons, g_font[weight]);
    fonsSetSize(g_fons, quantize(px));
}

// Width of s at `px`, measured when the font is loaded, estimated otherwise.
f32 text_width(str s, f32 px, i32 weight) {
    if !text_ready() { return cast(f32, s.len) * px * 0.8f; }
    select(px, weight);
    fonsSetAlign(g_fons, FONS_ALIGN_LEFT | FONS_ALIGN_MIDDLE);
    f32[4] bounds;
    return fonsTextBounds(g_fons, 0.0f, 0.0f, s.data, s.data + s.len, &bounds[0]);
}

// Draws s at size `px` with its left, centre or right at x and its
// middle on y, in the current sokol_gl space (screen pixels).
void text_draw(f32 x, f32 y, str s, f32 px, i32 weight, float3 col, f32 a, i32 align) {
    if s.len == 0 || px < TEXT_MIN_PX { return; }
    if !text_ready() {
        pixel_text(x, y, s, px, col, a, align);
        return;
    }
    select(px, weight);
    i32 h = FONS_ALIGN_LEFT;
    if align == TEXT_CENTER { h = FONS_ALIGN_CENTER; }
    else if align == TEXT_RIGHT { h = FONS_ALIGN_RIGHT; }
    fonsSetAlign(g_fons, h | FONS_ALIGN_MIDDLE);
    fonsSetColor(g_fons, rgba(col, a));
    ignore fonsDrawText(g_fons, floorf(x + 0.5f), floorf(y + 0.5f), s.data, s.data + s.len);
}

// Uploads the atlas; once per frame, after the last text and before sgl_draw.
void text_flush() {
    if g_fons != null { sfons_flush(g_fons); }
}
