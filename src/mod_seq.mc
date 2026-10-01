// mod_seq.mc: SEQUENCER, three rows of eight steps.
//
// A clock moves the sequence on one step: the internal clock while RUN
// is on, or the CLOCK input's rising edges while that is patched. Each
// step plays, is skipped, or plays and stops the internal clock until a
// reset or RUN switched on again. STEPS sets the length; RESET makes the
// next clock play step 1. Every row has a range (1, 2 or 5 V full scale)
// and an optional semitone quantizer. GATE is high for LENGTH of the
// clock period after each clock; CLOCK and the eight step outputs fire
// triggers, so every step can start something of its own.

import dsp_math;
import profile;
import engine_core;

const i32 SEQ_STEPS = 8;
const i32 SEQ_ROWS = 3;

enum SeqIn { SEQ_IN_CLOCK, SEQ_IN_RESET }
enum SeqMode { SEQ_PLAY, SEQ_SKIP, SEQ_STOP }

// Params: the rows' steps, the step modes, then the controls.
const i32 SEQ_P_A1 = 0;                 // row r step s: SEQ_P_A1 + 8 r + s
const i32 SEQ_P_MODE1 = 24;
const i32 SEQ_P_RANGE_A = 32;
const i32 SEQ_P_QUANT_A = 35;
const i32 SEQ_P_RATE = 38;
const i32 SEQ_P_LENGTH = 39;
const i32 SEQ_P_STEPS = 40;
const i32 SEQ_P_RUN = 41;

// Outputs: the step triggers, then the rows, gate and clock.
const i32 SEQ_OUT_STEP1 = 0;
const i32 SEQ_OUT_A = 8;
const i32 SEQ_OUT_GATE = 11;
const i32 SEQ_OUT_CLOCK = 12;

f32[3] SEQ_RANGES = { 1.0f, 2.0f, 5.0f };  // volts, by range switch position

PortDesc[2] SEQ_INPUTS = {
    PortDesc{ "clock", CLS_TRIG, 0.0f },
    PortDesc{ "reset", CLS_TRIG, 0.0f },
};

PortDesc[13] SEQ_OUTPUTS = {
    PortDesc{ "step1", CLS_TRIG, 0.0f },
    PortDesc{ "step2", CLS_TRIG, 0.0f },
    PortDesc{ "step3", CLS_TRIG, 0.0f },
    PortDesc{ "step4", CLS_TRIG, 0.0f },
    PortDesc{ "step5", CLS_TRIG, 0.0f },
    PortDesc{ "step6", CLS_TRIG, 0.0f },
    PortDesc{ "step7", CLS_TRIG, 0.0f },
    PortDesc{ "step8", CLS_TRIG, 0.0f },
    PortDesc{ "a", CLS_PITCH, 0.0f },
    PortDesc{ "b", CLS_PITCH, 0.0f },
    PortDesc{ "c", CLS_PITCH, 0.0f },
    PortDesc{ "gate", CLS_TRIG, 0.0f },
    PortDesc{ "clock", CLS_TRIG, 0.0f },
};

ParamDesc[42] SEQ_PARAMS = {
    ParamDesc{ "a1", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "a2", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "a3", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "a4", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "a5", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "a6", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "a7", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "a8", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "b1", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "b2", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "b3", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "b4", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "b5", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "b6", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "b7", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "b8", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "c1", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "c2", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "c3", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "c4", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "c5", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "c6", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "c7", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "c8", 0.0f, 0.0f, 1.0f, TAPER_LIN, 0 },
    ParamDesc{ "mode1", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },         // SeqMode
    ParamDesc{ "mode2", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "mode3", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "mode4", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "mode5", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "mode6", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "mode7", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "mode8", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "range_a", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },       // SEQ_RANGES
    ParamDesc{ "range_b", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "range_c", 0.0f, 0.0f, 2.0f, TAPER_LIN, 3 },
    ParamDesc{ "quant_a", 0.0f, 0.0f, 1.0f, TAPER_LIN, 2 },
    ParamDesc{ "quant_b", 0.0f, 0.0f, 1.0f, TAPER_LIN, 2 },
    ParamDesc{ "quant_c", 0.0f, 0.0f, 1.0f, TAPER_LIN, 2 },
    ParamDesc{ "rate", 4.0f, 0.1f, 50.0f, TAPER_EXP, 0 },         // Hz
    ParamDesc{ "length", 0.5f, 0.05f, 0.95f, TAPER_LIN, 0 },      // of the clock period
    ParamDesc{ "steps", 8.0f, 1.0f, 8.0f, TAPER_LIN, 0 },         // rounded
    ParamDesc{ "run", 1.0f, 0.0f, 1.0f, TAPER_LIN, 2 },
};

ModuleDesc seq_desc() {
    return ModuleDesc{ "SEQUENCER", &SEQ_INPUTS[0], 2, &SEQ_OUTPUTS[0], 13, &SEQ_PARAMS[0], 42 };
}

struct SeqMod {
    ModBase base;
    i32 step;                   // sounding step, 0..7
    bool at_start;              // the next clock plays the first step
    bool halted;                // a STOP step holds the internal clock
    bool was_running;
    f64 phase;                  // internal clock, cycles
    i32 since;                  // samples since the last clock
    i32 period;                 // samples between the last two clocks
    i32 gate_left;
    Schmitt clock;
    Schmitt reset;
    TrigOut[8] step_trig;
    TrigOut clock_trig;
}

void seq_mod_init(SeqMod* m, ModBase base) {
    *m = SeqMod{};
    m.base = base;
    m.at_start = true;
}

void seq_mod_reset(SeqMod* m) {
    ModBase b = m.base;
    seq_mod_init(m, b);
}

private i32 seq_mode(Core* c, ModBase* b, i32 s) { return cast(i32, mod_param(c, b, SEQ_P_MODE1 + s) + 0.5f); }

// The next step to play after `at` (or the first, from -1), skipping
// SKIP steps; `at` again when every step skips.
private i32 seq_next(Core* c, ModBase* b, i32 at, i32 n) {
    for i32 k = 1; k <= n; k++ {
        i32 s = (at + k) % n;
        if at < 0 { s = k - 1; }
        if seq_mode(c, b, s) != SEQ_SKIP { return s; }
    }
    if at < 0 { return 0; }
    return at;
}

void seq_mod_tick(Core* c, SeqMod* m) {
    ModBase* b = &m.base;
    i32 n = clampi(cast(i32, mod_param(c, b, SEQ_P_STEPS) + 0.5f), 1, SEQ_STEPS);
    if m.step >= n { m.step = n - 1; }
    bool running = mod_param(c, b, SEQ_P_RUN) > 0.5f;
    if running && !m.was_running { m.halted = false; }
    m.was_running = running;

    bool was_reset = m.reset.high;
    if schmitt(&m.reset, mod_in(c, b, SEQ_IN_RESET)) && !was_reset {
        m.at_start = true;
        m.halted = false;
        m.step = seq_next(c, b, -1, n);
        m.phase = 0.0;
    }

    bool tick = false;
    if m.since < 0x7FFFFFFF { m.since++; }
    if mod_patched(c, b, SEQ_IN_CLOCK) {
        bool was = m.clock.high;
        tick = schmitt(&m.clock, mod_in(c, b, SEQ_IN_CLOCK)) && !was;
        if tick { m.period = m.since; }
    } else if running && !m.halted {
        f32 rate = mod_param(c, b, SEQ_P_RATE);
        m.phase += cast(f64, rate / c.sample_rate);
        if m.phase >= 1.0 {
            m.phase -= 1.0;
            tick = true;
        }
        m.period = cast(i32, c.sample_rate / rate);
    }

    if tick {
        m.since = 0;
        if m.at_start {
            m.at_start = false;
            m.step = seq_next(c, b, -1, n);
        } else {
            m.step = seq_next(c, b, m.step, n);
        }
        if seq_mode(c, b, m.step) == SEQ_STOP { m.halted = true; }
        m.gate_left = cast(i32, mod_param(c, b, SEQ_P_LENGTH) * cast(f32, m.period));
        trig_fire(c, &m.step_trig[m.step]);
        trig_fire(c, &m.clock_trig);
    }

    for i32 r = 0; r < SEQ_ROWS; r++ {
        f32 range = SEQ_RANGES[clampi(cast(i32, mod_param(c, b, SEQ_P_RANGE_A + r) + 0.5f), 0, 2)];
        f32 v = mod_param(c, b, SEQ_P_A1 + SEQ_STEPS * r + m.step) * range;
        if mod_param(c, b, SEQ_P_QUANT_A + r) > 0.5f { v = floorf(v * 12.0f + 0.5f) / 12.0f; }
        mod_out(c, b, SEQ_OUT_A + r, v);
    }
    for i32 s = 0; s < SEQ_STEPS; s++ { mod_out(c, b, SEQ_OUT_STEP1 + s, trig_tick(&m.step_trig[s])); }
    f32 gate = 0.0f;
    if m.gate_left > 0 {
        m.gate_left--;
        gate = 1.0f;
    }
    mod_out(c, b, SEQ_OUT_GATE, gate);
    mod_out(c, b, SEQ_OUT_CLOCK, trig_tick(&m.clock_trig));
}
