// dsp_age.mc: what age does to a circuit.
//
// The AGE knob on OUT (0 = pristine, 1 = well used) scales two things
// that every oscillator and filter gets from its own seed at build time:
// a fixed tolerance (a 1 V/oct scale error and an offset for an
// oscillator, a cutoff offset for a filter) and, for oscillators, a slow
// random wander of a few cents. Two instances never share a seed, so
// aged oscillators beat against each other, which is most of the sound.

import dsp_math;

const f32 AGE_SCALE_ERR = 0.003f;       // 1 V/oct scale error at AGE 1, fraction, +-
const f32 AGE_OFFSET_V = 0.0025f;       // fixed pitch offset at AGE 1: +-3 cents
const f32 AGE_DRIFT_V = 0.0033f;        // slow wander at AGE 1: +-4 cents
const f32 AGE_FILTER_V = 0.04f;         // cutoff offset at AGE 1: +-3 % in frequency
const f32 AGE_DRIFT_TAU_S = 1.0f;       // the wander's smoothing
const f32 AGE_HOLD_MIN_S = 0.5f;        // a new wander target every 0.5 to 2 s
const f32 AGE_HOLD_MAX_S = 2.0f;

struct Drift {
    f32 scale_err;                      // fraction of the pitch voltage
    f32 offset;                         // volts
    f32 walk;                           // the wander, -1..1
    f32 target;
    f32 a;                              // per-tick smoothing coefficient
    i32 left;                           // ticks until the next target
    f32 rate;
    Rng rng;
}

// Tolerances and the wander's start from `seed`; no two instances alike.
void drift_init(Drift* d, u64 seed, f32 sample_rate) {
    *d = Drift{};
    rng_seed(&d.rng, seed, 11);
    d.scale_err = AGE_SCALE_ERR * rng_uniform(&d.rng);
    d.offset = AGE_OFFSET_V * rng_uniform(&d.rng);
    d.rate = sample_rate;
    d.a = 1.0f / (AGE_DRIFT_TAU_S * sample_rate);
    d.target = rng_uniform(&d.rng);
}

// One tick of the wander: a one-pole slew toward a target that moves
// every half second to two seconds.
private f32 drift_step(Drift* d) {
    if d.left <= 0 {
        f32 hold = AGE_HOLD_MIN_S + (rng_uniform(&d.rng) + 1.0f) * 0.5f * (AGE_HOLD_MAX_S - AGE_HOLD_MIN_S);
        d.left = cast(i32, hold * d.rate);
        d.target = rng_uniform(&d.rng);
    }
    d.left--;
    d.walk += (d.target - d.walk) * d.a;
    return d.walk;
}

// A pitch voltage as the aged oscillator sees it. At age 0 it passes
// through untouched and the wander stands still.
f32 aged_volts(Drift* d, f32 volts, f32 age) {
    if age <= 0.0f { return volts; }
    f32 w = drift_step(d);
    return volts + age * (volts * d.scale_err + d.offset + AGE_DRIFT_V * w);
}

// A filter's fixed cutoff offset in volts, from its seed.
f32 age_filter_offset(u64 seed) {
    Rng r;
    rng_seed(&r, seed, 13);
    return AGE_FILTER_V * rng_uniform(&r);
}
