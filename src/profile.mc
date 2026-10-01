// profile.mc: signal conventions, MODERN and VINTAGE (plan.md section 4).
//
// The DSP works in canonical units: audio +-1, unipolar CV 0..1, pitch in
// octaves, triggers 0/1. A profile turns those into volts at the jacks,
// class by class, and decides which jacks may be patched together.

enum SigClass { CLS_AUDIO, CLS_PITCH, CLS_CV_UNI, CLS_CV_BI, CLS_TRIG }
enum Profile { PROFILE_MODERN, PROFILE_VINTAGE }

const i32 CLASS_COUNT = 5;
const i32 PROFILE_COUNT = 2;
const i32 TRIG_MAX_SOURCES = 4;

// Canonical gate thresholds: 2 V high, 1 V low in MODERN; a closed
// switch trigger (1) is high in VINTAGE.
const f32 GATE_HIGH = 0.2f;
const f32 GATE_LOW = 0.1f;

// Volts per canonical unit, by profile and class. Patches within one
// class sound the same in both profiles because the factors cancel;
// cross-class patches differ by the ratio. The VINTAGE audio level, 1.5 V,
// is set by ear: distinct from MODERN, where 2.5 V already sounds alike.
f32:[2][5] PROFILE_SCALE = {
    { 5.0f, 1.0f, 10.0f, 5.0f, 10.0f },     // MODERN
    { 1.5f, 1.0f, 5.5f, 2.75f, 1.0f },      // VINTAGE
};

f32 profile_scale(i32 profile, i32 cls) { return PROFILE_SCALE[profile][cls]; }

// Can an output of class `src` feed an input of class `dst`? MODERN
// patches anything into anything; VINTAGE keeps the trigger network apart.
bool profile_can_connect(i32 profile, i32 src, i32 dst) {
    if profile == PROFILE_MODERN { return true; }
    return (src == CLS_TRIG) == (dst == CLS_TRIG);
}

// Cables an input of class `cls` accepts. VINTAGE trigger inputs wire
// several switch closures together as an OR.
i32 profile_max_sources(i32 profile, i32 cls) {
    if profile == PROFILE_VINTAGE && cls == CLS_TRIG { return TRIG_MAX_SOURCES; }
    return 1;
}
