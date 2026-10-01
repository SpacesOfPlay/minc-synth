// mod_noise.mc: NOISE, noise colours and random voltages.
//
// White, pink and red noise, plus a sample-and-hold of uniform random
// values. The S&H runs on its own clock, or on the CLOCK input's rising
// edges while that is patched. SMOOTH is STEPPED through a slew.

import dsp_math;
import dsp_noise;
import profile;
import engine_core;

enum NoiseIn { NOISE_IN_CLOCK }
enum NoiseOut { NOISE_OUT_WHITE, NOISE_OUT_PINK, NOISE_OUT_RED, NOISE_OUT_STEPPED, NOISE_OUT_SMOOTH }
enum NoiseParam { NOISE_P_RATE, NOISE_P_SLEW }

PortDesc[1] NOISE_INPUTS = {
    PortDesc{ "clock", CLS_TRIG, 0.0f },
};

PortDesc[5] NOISE_OUTPUTS = {
    PortDesc{ "white", CLS_AUDIO, 0.0f },
    PortDesc{ "pink", CLS_AUDIO, 0.0f },
    PortDesc{ "red", CLS_AUDIO, 0.0f },
    PortDesc{ "stepped", CLS_CV_BI, 0.0f },
    PortDesc{ "smooth", CLS_CV_BI, 0.0f },
};

ParamDesc[2] NOISE_PARAMS = {
    ParamDesc{ "rate", 4.0f, 0.1f, 50.0f, TAPER_EXP, 0 },         // Hz
    ParamDesc{ "slew", 0.1f, 0.001f, 2.0f, TAPER_EXP, 0 },        // seconds to 99 %
};

ModuleDesc noise_desc() {
    return ModuleDesc{ "NOISE", &NOISE_INPUTS[0], 1, &NOISE_OUTPUTS[0], 5, &NOISE_PARAMS[0], 2 };
}

struct NoiseMod {
    ModBase base;
    Noise v;
    u64 seed;
    f64 clock_phase;
    Schmitt clock;
    f32 held;
    Smooth smooth;
    f32 slew_s;                 // slew the smoother coefficient was made for
}

void noise_mod_init(NoiseMod* m, ModBase base, u64 seed) {
    *m = NoiseMod{};
    m.base = base;
    m.seed = seed;
    m.slew_s = -1.0f;
    noise_init(&m.v, seed);
}

void noise_mod_reset(NoiseMod* m) {
    ModBase b = m.base;
    noise_mod_init(m, b, m.seed);
}

void noise_mod_tick(Core* c, NoiseMod* m) {
    ModBase* b = &m.base;
    NoiseSample n = noise_tick(&m.v);

    bool sample = false;
    if mod_patched(c, b, NOISE_IN_CLOCK) {
        bool was = m.clock.high;
        sample = schmitt(&m.clock, mod_in(c, b, NOISE_IN_CLOCK)) && !was;
    } else {
        m.clock_phase += mod_param(c, b, NOISE_P_RATE) / c.sample_rate;
        if m.clock_phase >= 1.0 {
            m.clock_phase -= 1.0;
            sample = true;
        }
    }
    if sample { m.held = rng_uniform(&m.v.rng); }

    f32 slew = mod_param(c, b, NOISE_P_SLEW);
    if slew != m.slew_s {
        m.slew_s = slew;
        m.smooth.a = onepole_coef(slew / 4.6f, c.sample_rate);
    }

    mod_out(c, b, NOISE_OUT_WHITE, n.white);
    mod_out(c, b, NOISE_OUT_PINK, n.pink);
    mod_out(c, b, NOISE_OUT_RED, n.red);
    mod_out(c, b, NOISE_OUT_STEPPED, m.held);
    mod_out(c, b, NOISE_OUT_SMOOTH, smooth_step(&m.smooth, m.held));
}
