// ui_cables.mc: cable geometry.
//
// A cable hangs between its plugs as a cubic Bezier whose control points
// sit below each end, so it sags in proportion to its length, like a
// catenary. The curve is cut into straight segments for drawing and for
// hit testing.

import math;

const i32 CABLE_SEGS = 64;              // straight pieces a cable is drawn and hit-tested with
const f32 CABLE_SLACK = 0.18f;          // sag as a fraction of the span
const f32 CABLE_MIN_SAG = 12.0f;
const f32 CABLE_W = 5.0f;               // drawn width, virtual units
const f32 PLUG_R = 7.0f;

// Cable colours, reds, greys and black, by the patch's colour index
// (PATCH_COLORS). None is brighter than a 50 % grey (relative luminance
// 0.214), so cables stay under the white text and the activity rim still
// stands out on them.
float3[9] CABLE_COLORS = {
    float3{ 0.90f, 0.13f, 0.15f },      // red
    float3{ 0.50f, 0.50f, 0.50f },      // grey
    float3{ 0.38f, 0.40f, 0.44f },      // cool grey
    float3{ 0.80f, 0.36f, 0.33f },      // salmon
    float3{ 0.58f, 0.10f, 0.12f },      // dark red
    float3{ 0.46f, 0.43f, 0.40f },      // warm grey
    float3{ 0.32f, 0.31f, 0.31f },      // dark grey
    float3{ 0.78f, 0.06f, 0.25f },      // crimson
    float3{ 0.10f, 0.10f, 0.11f },      // black
};

// Dark cables and plugs get a lighter edge so they read on the black
// canvas and the dark panels; a colour at least this bright in some
// channel is its own edge.
const f32 CABLE_EDGE_MIN = 0.30f;

float3 cable_edge(float3 c, f32 least) {
    f32 m = fmaxf(c.r, fmaxf(c.g, c.b));
    if m >= least { return c; }
    return c + float3{ least - m, least - m, least - m };
}

struct CablePath {
    float2[CABLE_SEGS + 1] pts;
}

private f32 span(float2 d) { return sqrtf(d.x * d.x + d.y * d.y); }

void cable_path(CablePath* out, float2 a, float2 b) {
    f32 sag = CABLE_MIN_SAG + CABLE_SLACK * span(b - a);
    float2 c1 = a + float2{ 0.0f, sag };
    float2 c2 = b + float2{ 0.0f, sag };
    for i32 i = 0; i <= CABLE_SEGS; i++ {
        f32 t = cast(f32, i) / cast(f32, CABLE_SEGS);
        f32 u = 1.0f - t;
        f32 w0 = u * u * u;
        f32 w1 = 3.0f * u * u * t;
        f32 w2 = 3.0f * u * t * t;
        f32 w3 = t * t * t;
        out.pts[i] = a * w0 + c1 * w1 + c2 * w2 + b * w3;
    }
}

// Distance from p to the segment a-b.
f32 segment_distance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float2 ap = p - a;
    f32 len2 = ab.x * ab.x + ab.y * ab.y;
    f32 t = 0.0f;
    if len2 > 0.0f { t = (ap.x * ab.x + ap.y * ab.y) / len2; }
    if t < 0.0f { t = 0.0f; }
    if t > 1.0f { t = 1.0f; }
    return span(p - (a + ab * t));
}

f32 cable_distance(CablePath* c, float2 p) {
    f32 best = 1e30f;
    for i32 i = 0; i < CABLE_SEGS; i++ {
        f32 d = segment_distance(p, c.pts[i], c.pts[i + 1]);
        if d < best { best = d; }
    }
    return best;
}

f32 point_distance(float2 a, float2 b) { return span(b - a); }

// ---- the rope ----
//
// Every cable is a verlet rope: a chain of points under gravity, pinned
// at the plugs, kept at its rest length by distance constraints. It is
// simulated while in hand and for a moment after it lands or a plug
// moves, then rests where it hangs. The Bezier gives it its length and
// its first shape, and stands in for it where nothing has been simulated
// (the hit tests in a headless test).

const i32 ROPE_N = 16;
const f32 ROPE_GRAVITY = 6000.0f;       // rack units per second squared: a swing of about a second
const f32 ROPE_DAMPING = 0.95f;         // per step
const f32 ROPE_DT = 1.0f / 120.0f;      // one physics step
const i32 ROPE_ITERS = 40;              // constraint passes per step: few leave the rope stretchy
const f32 ROPE_WOBBLE_S = 1.2f;         // how long a landed cable keeps swinging

struct Rope {
    float2[16] p;                       // ROPE_N points, the first and last pinned
    float2[16] prev;
    f32 rest;                           // length of one link
}

// Length of a path's polyline.
f32 path_length(CablePath* c) {
    f32 len = 0.0f;
    for i32 i = 0; i < CABLE_SEGS; i++ { len += span(c.pts[i + 1] - c.pts[i]); }
    return len;
}

// A rope laid along a path, at rest.
void rope_init_path(Rope* r, CablePath* c) {
    for i32 i = 0; i < ROPE_N; i++ {
        f32 t = cast(f32, i) * cast(f32, CABLE_SEGS) / cast(f32, ROPE_N - 1);
        i32 k = cast(i32, t);
        if k >= CABLE_SEGS { k = CABLE_SEGS - 1; }
        f32 f = t - cast(f32, k);
        r.p[i] = c.pts[k] + (c.pts[k + 1] - c.pts[k]) * f;
        r.prev[i] = r.p[i];
    }
    r.rest = path_length(c) / cast(f32, ROPE_N - 1);
}

// A rope nearly straight between two points, at rest; it drops into
// its sag from there. Its length is what the Bezier between them would
// have. A little sag to start with keeps the links from fighting in a
// line.
void rope_init_line(Rope* r, float2 a, float2 b) {
    CablePath c;
    cable_path(&c, a, b);
    for i32 i = 0; i < ROPE_N; i++ {
        f32 t = cast(f32, i) / cast(f32, ROPE_N - 1);
        float2 line = a + (b - a) * t;
        float2 hang = c.pts[i * CABLE_SEGS / (ROPE_N - 1)];
        r.p[i] = line + (hang - line) * 0.2f;
        r.prev[i] = r.p[i];
    }
    r.rest = path_length(&c) / cast(f32, ROPE_N - 1);
}

// Advances the rope by `dt` in fixed steps, pinned at a and b, with the
// rest length of the Bezier between them.
void rope_step(Rope* r, float2 a, float2 b, f32 dt) {
    CablePath c;
    cable_path(&c, a, b);
    f32 rest = path_length(&c) / cast(f32, ROPE_N - 1);
    i32 steps = cast(i32, dt / ROPE_DT + 0.5f);
    if steps < 1 { steps = 1; }
    if steps > 8 { steps = 8; }
    for i32 s = 0; s < steps; s++ {
        for i32 i = 1; i < ROPE_N - 1; i++ {
            float2 v = (r.p[i] - r.prev[i]) * ROPE_DAMPING;
            r.prev[i] = r.p[i];
            r.p[i] = r.p[i] + v + float2{ 0.0f, ROPE_GRAVITY * ROPE_DT * ROPE_DT };
        }
        r.p[0] = a;
        r.p[ROPE_N - 1] = b;
        for i32 it = 0; it < ROPE_ITERS; it++ {
            for i32 i = 0; i < ROPE_N - 1; i++ {
                float2 d = r.p[i + 1] - r.p[i];
                f32 len = span(d);
                if len < 1e-6f { continue; }
                float2 fix = d * ((len - rest) / len * 0.5f);
                if i == 0 { r.p[i + 1] = r.p[i + 1] - fix * 2.0f; }
                else if i == ROPE_N - 2 { r.p[i] = r.p[i] + fix * 2.0f; }
                else {
                    r.p[i] = r.p[i] + fix;
                    r.p[i + 1] = r.p[i + 1] - fix;
                }
            }
        }
    }
    r.prev[0] = a;
    r.prev[ROPE_N - 1] = b;
    r.rest = rest;
}

// The rope as a path, Catmull-Rom through its points.
void rope_path(Rope* r, CablePath* out) {
    for i32 s = 0; s <= CABLE_SEGS; s++ {
        f32 t = cast(f32, s) * cast(f32, ROPE_N - 1) / cast(f32, CABLE_SEGS);
        i32 k = cast(i32, t);
        if k >= ROPE_N - 1 { k = ROPE_N - 2; }
        f32 f = t - cast(f32, k);
        float2 p0 = r.p[k > 0 ? k - 1 : 0];
        float2 p1 = r.p[k];
        float2 p2 = r.p[k + 1];
        float2 p3 = r.p[k + 2 < ROPE_N ? k + 2 : ROPE_N - 1];
        f32 f2 = f * f;
        f32 f3 = f2 * f;
        out.pts[s] = (p1 * 2.0f + (p2 - p0) * f + (p0 * 2.0f - p1 * 5.0f + p2 * 4.0f - p3) * f2
                    + (p1 * 3.0f - p0 - p2 * 3.0f + p3) * f3) * 0.5f;
    }
}
