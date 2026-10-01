// mod_out.mc: OUT, the path to the audio device.
//
// L and R inputs with levels; a single patched input plays on both
// sides. Then master level, 5 V to half scale, a DC blocker at 5 Hz, a
// soft limiter from -3 dBFS and a hard clamp at full scale. The frame is
// left in the module for the engine to collect; OUT has no bus outputs.
//
// AGE lives here as the one global knob: how far every oscillator and
// filter sits from its nominal value and how much the oscillators wander
// (dsp_age). The engine reads it once a tick into the core.

import dsp_math;
import profile;
import engine_core;

enum OutIn { OUT_IN_L, OUT_IN_R }
enum OutParam { OUT_P_LEVEL_L, OUT_P_LEVEL_R, OUT_P_MASTER, OUT_P_AGE }

const f32 OUT_HALF_SCALE = 1.0f;        // canonical audio 1 (5 V) -> full scale; the limiter takes what goes past
const f32 OUT_DC_HZ = 5.0f;
const f32 OUT_KNEE = 0.708f;            // -3 dBFS

PortDesc[2] OUT_INPUTS = {
    PortDesc{ "l", CLS_AUDIO, 0.0f },
    PortDesc{ "r", CLS_AUDIO, 0.0f },
};

ParamDesc[4] OUT_PARAMS = {
    ParamDesc{ "level_l", 0.8f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "level_r", 0.8f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "master", 0.8f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "age", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },          // 0 pristine, 1 well used
};

ModuleDesc out_desc() {
    return ModuleDesc{ "OUT", &OUT_INPUTS[0], 2, null, 0, &OUT_PARAMS[0], 4 };
}

struct DcBlock {
    f32 x1;
    f32 y1;
}

struct OutMod {
    ModBase base;
    DcBlock dc_l;
    DcBlock dc_r;
    f32 dc_r_coef;
    f32 l;                      // the frame of the last tick, full scale +-1
    f32 r;
}

void out_mod_init(OutMod* m, ModBase base, f32 sample_rate) {
    *m = OutMod{};
    m.base = base;
    m.dc_r_coef = 1.0f - TWO_PI * OUT_DC_HZ / sample_rate;
}

void out_mod_reset(OutMod* m) {
    m.dc_l = DcBlock{};
    m.dc_r = DcBlock{};
}

f32 dc_block(DcBlock* d, f32 x, f32 r) {
    f32 y = x - d.x1 + r * d.y1;
    d.x1 = x;
    d.y1 = flush_denormal(y);
    return y;
}

// Transparent below the knee, then bends toward full scale and stays under it.
f32 soft_limit(f32 x) {
    f32 a = fabsf(x);
    if a <= OUT_KNEE { return x; }
    f32 y = OUT_KNEE + (1.0f - OUT_KNEE) * tanh_fast((a - OUT_KNEE) / (1.0f - OUT_KNEE));
    if x < 0.0f { return -y; }
    return y;
}

void out_mod_tick(Core* c, OutMod* m) {
    ModBase* b = &m.base;
    bool has_l = mod_patched(c, b, OUT_IN_L);
    bool has_r = mod_patched(c, b, OUT_IN_R);
    // A poly cable plays all its voices: the channels are summed.
    f32 l = mod_in_sum(c, b, OUT_IN_L) * mod_param(c, b, OUT_P_LEVEL_L);
    f32 r = mod_in_sum(c, b, OUT_IN_R) * mod_param(c, b, OUT_P_LEVEL_R);
    if has_l && !has_r { r = l; }
    if has_r && !has_l { l = r; }
    f32 g = mod_param(c, b, OUT_P_MASTER) * OUT_HALF_SCALE;
    l = soft_limit(dc_block(&m.dc_l, l * g, m.dc_r_coef));
    r = soft_limit(dc_block(&m.dc_r, r * g, m.dc_r_coef));
    m.l = clampf(l, -1.0f, 1.0f);
    m.r = clampf(r, -1.0f, 1.0f);
}
