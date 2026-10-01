// dsp_env.mc: 4-stage contour generator (ADSR) with RC-shaped curves.
//
// Attack charges toward an overshoot target and stops at full level:
// the concave curve of an RC charge, with an exact attack time. Decay
// and release are exponential approaches toward sustain and zero. A
// decay or release time is the time to cover 99 % of the distance.
//
// The level is canonical, 0..1. Gate and retrigger arrive as booleans;
// the module turns voltages into them with a Schmitt trigger.

import math;
import dsp_math;

enum EnvStage { ENV_IDLE, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE }

const f32 ENV_OVERSHOOT = 1.5f;
const f32 ENV_FLOOR = 1e-4f;            // release ends here, -80 dB
const f32 ENV_LN3 = 1.09861229f;        // attack: 1.5 * (1 - e^-t) reaches 1 at t = ln 3
const f32 ENV_LN100 = 4.60517019f;      // 99 % of the distance

struct Env {
    f32 level;
    i32 stage;
    bool gate;                          // last gate input
    bool retrig;                        // last retrigger input
    bool eoc;                           // true for one tick when a cycle ends
    bool loop;                          // cycle attack/decay while the gate is high
    f32 attack_coef;
    f32 decay_coef;
    f32 release_coef;
    f32 sustain;
}

void env_set(Env* e, f32 attack_s, f32 decay_s, f32 sustain, f32 release_s, f32 sample_rate) {
    e.attack_coef = onepole_coef(attack_s / ENV_LN3, sample_rate);
    e.decay_coef = onepole_coef(decay_s / ENV_LN100, sample_rate);
    e.release_coef = onepole_coef(release_s / ENV_LN100, sample_rate);
    e.sustain = clampf(sustain, 0.0f, 1.0f);
}

// One sample. A rising gate, or a rising retrigger while the gate is
// high, restarts the attack from the current level, so it never clicks
// back to zero. A falling gate releases from the current level.
f32 env_tick(Env* e, bool gate, bool retrig) {
    e.eoc = false;
    if gate && !e.gate {
        e.stage = ENV_ATTACK;
    } else if !gate && e.gate && e.stage != ENV_IDLE {
        e.stage = ENV_RELEASE;
    } else if gate && retrig && !e.retrig {
        e.stage = ENV_ATTACK;
    }
    e.gate = gate;
    e.retrig = retrig;

    switch e.stage {
        case ENV_ATTACK: {
            e.level += (ENV_OVERSHOOT - e.level) * e.attack_coef;
            if e.level >= 1.0f {
                e.level = 1.0f;
                e.stage = ENV_DECAY;
            }
        }
        case ENV_DECAY: {
            e.level += (e.sustain - e.level) * e.decay_coef;
            // Within 1 % of the distance from full level to sustain.
            if e.level - e.sustain <= 0.01f * (1.0f - e.sustain) + 1e-6f {
                if e.loop {
                    e.eoc = true;
                    e.stage = ENV_ATTACK;
                } else {
                    e.stage = ENV_SUSTAIN;
                }
            }
        }
        case ENV_SUSTAIN: {
            // Follows sustain changes at the decay rate instead of stepping.
            e.level += (e.sustain - e.level) * e.decay_coef;
        }
        case ENV_RELEASE: {
            e.level -= e.level * e.release_coef;
            if e.level < ENV_FLOOR {
                e.level = 0.0f;
                e.stage = ENV_IDLE;
                e.eoc = true;
            }
        }
        default: {}
    }
    return e.level;
}
