// mod_bank.mc: OSC BANK, a driver and three oscillator cores.
//
// The driver sums three 1 V/oct inputs with its frequency knob and sets
// one pulse width; every core adds its own octave switch and fine tune
// and has its own sync input. The cores track together, so stacked,
// detuned or octave-spread unison is a matter of the core knobs. Each
// core starts at a random phase and runs free, so detuned cores beat.

import dsp_math;
import dsp_osc;
import dsp_age;
import profile;
import engine_core;

const i32 BANK_CORES = 3;

enum BankIn { BANK_IN_PITCH1, BANK_IN_PITCH2, BANK_IN_PITCH3, BANK_IN_WIDTH, BANK_IN_SYNC1, BANK_IN_SYNC2, BANK_IN_SYNC3 }
enum BankParam { BANK_P_FREQ, BANK_P_WIDTH, BANK_P_OCT1, BANK_P_FINE1, BANK_P_OCT2, BANK_P_FINE2, BANK_P_OCT3, BANK_P_FINE3 }

// Outputs run core by core: sine, tri, saw, pulse.
const i32 BANK_OUT_SINE = 0;
const i32 BANK_OUT_TRI = 1;
const i32 BANK_OUT_SAW = 2;
const i32 BANK_OUT_PULSE = 3;
const i32 BANK_OUT_PER_CORE = 4;

PortDesc[7] BANK_INPUTS = {
    PortDesc{ "pitch1", CLS_PITCH, 0.0f },
    PortDesc{ "pitch2", CLS_PITCH, 0.0f },
    PortDesc{ "pitch3", CLS_PITCH, 0.0f },
    PortDesc{ "width", CLS_CV_BI, 0.0f },
    PortDesc{ "sync1", CLS_AUDIO, 0.0f },
    PortDesc{ "sync2", CLS_AUDIO, 0.0f },
    PortDesc{ "sync3", CLS_AUDIO, 0.0f },
};

PortDesc[12] BANK_OUTPUTS = {
    PortDesc{ "sine1", CLS_AUDIO, 0.0f },
    PortDesc{ "tri1", CLS_AUDIO, 0.0f },
    PortDesc{ "saw1", CLS_AUDIO, 0.0f },
    PortDesc{ "pulse1", CLS_AUDIO, 0.0f },
    PortDesc{ "sine2", CLS_AUDIO, 0.0f },
    PortDesc{ "tri2", CLS_AUDIO, 0.0f },
    PortDesc{ "saw2", CLS_AUDIO, 0.0f },
    PortDesc{ "pulse2", CLS_AUDIO, 0.0f },
    PortDesc{ "sine3", CLS_AUDIO, 0.0f },
    PortDesc{ "tri3", CLS_AUDIO, 0.0f },
    PortDesc{ "saw3", CLS_AUDIO, 0.0f },
    PortDesc{ "pulse3", CLS_AUDIO, 0.0f },
};

ParamDesc[8] BANK_PARAMS = {
    ParamDesc{ "freq", 0.0f, -4.0f, 4.0f, TAPER_LIN, 0 },         // volts from C4
    ParamDesc{ "width", 0.5f, 0.05f, 0.95f, TAPER_LIN, 0 },
    ParamDesc{ "oct1", 0.0f, -3.0f, 3.0f, TAPER_LIN, 7 },
    ParamDesc{ "fine1", 0.0f, -0.583333f, 0.583333f, TAPER_LIN, 0 },   // +-7 semitones, in volts
    ParamDesc{ "oct2", 0.0f, -3.0f, 3.0f, TAPER_LIN, 7 },
    ParamDesc{ "fine2", 0.0f, -0.583333f, 0.583333f, TAPER_LIN, 0 },
    ParamDesc{ "oct3", 0.0f, -3.0f, 3.0f, TAPER_LIN, 7 },
    ParamDesc{ "fine3", 0.0f, -0.583333f, 0.583333f, TAPER_LIN, 0 },
};

ModuleDesc bank_desc() {
    return ModuleDesc{ "BANK", &BANK_INPUTS[0], 7, &BANK_OUTPUTS[0], 12, &BANK_PARAMS[0], 8 };
}

struct BankMod {
    ModBase base;
    Osc[3] v;                   // one per core, voice 0
    Drift[3] drift;             // each core's tolerances and wander, scaled by AGE
    Osc[21] vp;                 // voices 1 .. 7 of core k at 7 k + v - 1
    Drift[21] driftp;
}

void bank_mod_init(BankMod* m, ModBase base, f64 phase1, f64 phase2, f64 phase3, u64 seed, f32 sample_rate) {
    m.base = base;
    osc_init(&m.v[0], phase1);
    osc_init(&m.v[1], phase2);
    osc_init(&m.v[2], phase3);
    for i32 k = 0; k < BANK_CORES; k++ { drift_init(&m.drift[k], seed * 3 + cast(u64, k), sample_rate); }
    for i32 i = 0; i < BANK_CORES * (MAX_VOICES - 1); i++ {
        f64 p = phase1 + 0.382 * cast(f64, i + 1);
        osc_init(&m.vp[i], p - floor(p));
        drift_init(&m.driftp[i], seed * 29 + cast(u64, i + 1), sample_rate);
    }
}

void bank_mod_reset(BankMod* m) {
    for i32 k = 0; k < BANK_CORES; k++ { osc_init(&m.v[k], m.v[k].phase); }
    for i32 i = 0; i < BANK_CORES * (MAX_VOICES - 1); i++ { osc_init(&m.vp[i], m.vp[i].phase); }
}

private void bank_voice(Core* c, BankMod* m, i32 v) {
    ModBase* b = &m.base;
    f32 driver = mod_in_ch(c, b, BANK_IN_PITCH1, v) + mod_in_ch(c, b, BANK_IN_PITCH2, v) + mod_in_ch(c, b, BANK_IN_PITCH3, v)
               + mod_param(c, b, BANK_P_FREQ);
    f32 pw = clampf(mod_param(c, b, BANK_P_WIDTH) + 0.45f * mod_in_ch(c, b, BANK_IN_WIDTH, v), 0.05f, 0.95f);
    for i32 k = 0; k < BANK_CORES; k++ {
        // Past the first voice a core nobody listens to is skipped: its
        // voices have no cable to reach anything through.
        i32 out0 = b.slot0 + BANK_OUT_PER_CORE * k;
        if v > 0 && !c.slot_used[out0] && !c.slot_used[out0 + 1] && !c.slot_used[out0 + 2] && !c.slot_used[out0 + 3] { continue; }
        Osc* o = &m.v[k];
        Drift* d = &m.drift[k];
        if v > 0 {
            o = &m.vp[7 * k + v - 1];
            d = &m.driftp[7 * k + v - 1];
        }
        f32 volts = driver + mod_param(c, b, BANK_P_OCT1 + 2 * k) + mod_param(c, b, BANK_P_FINE1 + 2 * k);
        volts = aged_volts(d, volts, c.age);
        osc_tick(o, osc_dt(volts, c.sample_rate), pw, mod_in_ch(c, b, BANK_IN_SYNC1 + k, v));
        i32 out = BANK_OUT_PER_CORE * k;
        mod_out_ch(c, b, out + BANK_OUT_SINE, v, o.sine);
        mod_out_ch(c, b, out + BANK_OUT_TRI, v, o.tri);
        mod_out_ch(c, b, out + BANK_OUT_SAW, v, o.saw);
        mod_out_ch(c, b, out + BANK_OUT_PULSE, v, o.pulse);
    }
}

// Polyphonic like OSC: every core runs once per channel of the driver's
// inputs.
// One voice: the direct path, as fast as before voices existed.
private void bank_mono(Core* c, BankMod* m) {
    ModBase* b = &m.base;
    f32 driver = mod_in(c, b, BANK_IN_PITCH1) + mod_in(c, b, BANK_IN_PITCH2) + mod_in(c, b, BANK_IN_PITCH3)
               + mod_param(c, b, BANK_P_FREQ);
    f32 pw = clampf(mod_param(c, b, BANK_P_WIDTH) + 0.45f * mod_in(c, b, BANK_IN_WIDTH), 0.05f, 0.95f);
    for i32 k = 0; k < BANK_CORES; k++ {
        Osc* o = &m.v[k];
        f32 volts = driver + mod_param(c, b, BANK_P_OCT1 + 2 * k) + mod_param(c, b, BANK_P_FINE1 + 2 * k);
        volts = aged_volts(&m.drift[k], volts, c.age);
        osc_tick(o, osc_dt(volts, c.sample_rate), pw, mod_in(c, b, BANK_IN_SYNC1 + k));
        i32 out = BANK_OUT_PER_CORE * k;
        mod_out(c, b, out + BANK_OUT_SINE, o.sine);
        mod_out(c, b, out + BANK_OUT_TRI, o.tri);
        mod_out(c, b, out + BANK_OUT_SAW, o.saw);
        mod_out(c, b, out + BANK_OUT_PULSE, o.pulse);
    }
}

void bank_mod_tick(Core* c, BankMod* m) {
    i32 n = 1;
    if mod_poly(c, &m.base) { n = mod_begin_voices(c, &m.base, 0, 7); }
    if n == 1 {
        bank_mono(c, m);
        return;
    }
    for i32 v = 0; v < n; v++ { bank_voice(c, m, v); }
}
