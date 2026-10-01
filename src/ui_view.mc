// ui_view.mc: the window onto the rack.
//
// A point on the rack (virtual units) appears on screen at
// (point - pan) * zoom, below the top bar. Zooming keeps the point under
// the cursor where it is.

const f32 VIEW_MIN_ZOOM = 0.2f;
const f32 VIEW_MAX_ZOOM = 4.0f;

struct View {
    f32 zoom;
    float2 pan;                         // virtual point at the screen's top-left
    f32 screen_w;                       // pixels
    f32 screen_h;
}

void view_init(View* v, f32 w, f32 h) {
    v.zoom = 1.0f;
    v.pan = float2{ 0.0f, 0.0f };
    v.screen_w = w;
    v.screen_h = h;
}

float2 view_to_screen(View* v, float2 p) { return (p - v.pan) * v.zoom; }
float2 view_to_rack(View* v, float2 s) { return s / v.zoom + v.pan; }

// Zooms by `factor` about the screen point s.
void view_zoom_at(View* v, float2 s, f32 factor) {
    float2 anchor = view_to_rack(v, s);
    f32 z = v.zoom * factor;
    if z < VIEW_MIN_ZOOM { z = VIEW_MIN_ZOOM; }
    if z > VIEW_MAX_ZOOM { z = VIEW_MAX_ZOOM; }
    v.zoom = z;
    v.pan = anchor - s / z;
}

void view_pan_by(View* v, float2 screen_delta) { v.pan = v.pan - screen_delta / v.zoom; }

// Fits a w x h rack between `top` and `bottom` pixels kept for overlays at
// the window's edges, with a margin, centred.
void view_fit(View* v, f32 w, f32 h, f32 top, f32 bottom, f32 margin) {
    f32 zx = (v.screen_w - 2.0f * margin) / w;
    f32 zy = (v.screen_h - top - bottom - 2.0f * margin) / h;
    f32 z = zx;
    if zy < z { z = zy; }
    if z < VIEW_MIN_ZOOM { z = VIEW_MIN_ZOOM; }
    if z > VIEW_MAX_ZOOM { z = VIEW_MAX_ZOOM; }
    v.zoom = z;
    f32 ox = (v.screen_w - w * z) * 0.5f;
    f32 oy = top + (v.screen_h - top - bottom - h * z) * 0.5f;
    v.pan = float2{ -ox / z, -oy / z };
}
