// dsp_osc.mc: oscillator core shared by the OSC and OSC BANK modules.
//
// Saw, pulse, triangle and sine come from one phase accumulator. Every
// discontinuity (phase wrap, pulse edge, triangle corner, hard-sync
// reset) is located at its sub-sample position and smoothed with a
// 2-point polyBLEP (steps) or polyBLAMP (slope changes). A correction
// reaches one sample on each side of its edge, so the output runs one
// sample late: an edge found this sample also fixes the previous one.
//
// Levels are canonical: every waveform spans -1..+1.

import dsp_math;

const f32 OSC_MAX_DT = 0.45f;       // highest frequency, as a fraction of the sample rate

struct Osc {
    f64 phase;          // cycles in [0, 1); f64 keeps LFO rates exact
    f32 last_sync;      // previous sync input, for edge detection
    f32 saw_d;          // corrected samples waiting one tick
    f32 pulse_d;
    f32 tri_d;
    f32 saw;            // outputs of the last tick
    f32 pulse;
    f32 tri;
    f32 sine;
}

void osc_init(Osc* o, f64 phase) {
    *o = Osc{};
    o.phase = phase;
}

// Phase increment for a pitch voltage (1 V/oct, 0 V = C4).
f32 osc_dt(f32 volts, f32 sample_rate) {
    return clampf(volts_to_hz(volts) / sample_rate, 0.0f, OSC_MAX_DT);
}

// Residual of a unit upward step at signed distance d samples from it
// (d < 0 before the step), |d| < 1.
f32 blep_residual(f32 d) {
    if d < 0.0f {
        f32 a = 1.0f + d;
        return 0.5f * a * a;
    }
    f32 b = 1.0f - d;
    return -0.5f * b * b;
}

// Residual of a unit slope increase (per sample) at distance d, |d| < 1.
f32 blamp_residual(f32 d) {
    f32 a = 1.0f - fabsf(d);
    return a * a * a * (1.0f / 6.0f);
}

private {
    f32 naive_saw(f64 t) { return cast(f32, 2.0 * t - 1.0); }
    f32 naive_pulse(f64 t, f32 pw) { if t < pw { return 1.0f; } return -1.0f; }
    f32 naive_tri(f64 t) { return cast(f32, 1.0 - 4.0 * fabs(t - 0.5)); }

    // Corrections for the delayed (prev) and current (cur) samples.
    struct Fix {
        f32 saw_prev; f32 saw_cur;
        f32 pulse_prev; f32 pulse_cur;
        f32 tri_prev; f32 tri_cur;
    }

    // An edge at fraction x in (0, 1] of the interval since the last
    // sample: the previous sample is x before it, the current one 1 - x after.
    void fix_step(f32* prev, f32* cur, f32 x, f32 height) {
        *prev += height * blep_residual(-x);
        *cur += height * blep_residual(1.0f - x);
    }

    void fix_corner(f32* prev, f32* cur, f32 x, f32 slope_change) {
        *prev += slope_change * blamp_residual(-x);
        *cur += slope_change * blamp_residual(1.0f - x);
    }
}

// The phase running backwards, `a` per sample (through-zero FM). Every
// edge is crossed the other way: steps change sign, corners keep theirs.
// Sync acts only while the phase runs forward.
private void osc_tick_reverse(Osc* o, f32 a, f32 pw, f32 sync) {
    Fix f;
    o.last_sync = sync;
    f64 p0 = o.phase;
    f64 p1 = p0 - a;
    f32 tri_slope = 4.0f * a;

    if p0 >= pw && p1 < pw {
        fix_step(&f.pulse_prev, &f.pulse_cur, cast(f32, (p0 - pw) / a), 2.0f);
    }
    if p0 >= 0.5 && p1 < 0.5 {
        fix_corner(&f.tri_prev, &f.tri_cur, cast(f32, (p0 - 0.5) / a), -2.0f * tri_slope);
    }
    f64 p = p1;
    if p1 < 0.0 {
        f32 x = cast(f32, p0 / a);
        fix_step(&f.saw_prev, &f.saw_cur, x, 2.0f);
        fix_step(&f.pulse_prev, &f.pulse_cur, x, -2.0f);
        fix_corner(&f.tri_prev, &f.tri_cur, x, 2.0f * tri_slope);
        p = p1 + 1.0;
        if p < pw { fix_step(&f.pulse_prev, &f.pulse_cur, cast(f32, (p0 + 1.0 - pw) / a), 2.0f); }
    }
    o.phase = p;

    o.saw = o.saw_d + f.saw_prev;
    o.pulse = o.pulse_d + f.pulse_prev;
    o.tri = o.tri_d + f.tri_prev;
    o.sine = sin_cycle(o.tri * 0.25f);

    o.saw_d = naive_saw(p) + f.saw_cur;
    o.pulse_d = naive_pulse(p, pw) + f.pulse_cur;
    o.tri_d = naive_tri(p) + f.tri_cur;
}

// Advance one sample. dt: frequency / sample rate, -OSC_MAX_DT..OSC_MAX_DT;
// below 0 the phase runs backwards (through-zero FM).
// pw: pulse width, 0..1 (callers clamp to a musical range). sync: a
// rising zero crossing resets the phase at its interpolated position.
void osc_tick(Osc* o, f32 dt, f32 pw, f32 sync) {
    if dt < 0.0f {
        osc_tick_reverse(o, -dt, pw, sync);
        return;
    }
    Fix f;
    f64 p0 = o.phase;
    f64 p1 = p0 + dt;
    f32 tri_slope = 4.0f * dt;           // triangle slope per sample

    // Sub-sample position of a sync edge; > 1 means none this sample.
    f32 xs = 2.0f;
    if o.last_sync < 0.0f && sync >= 0.0f {
        xs = o.last_sync / (o.last_sync - sync);
    }
    o.last_sync = sync;

    // Edges of the free-running cycle that happen before any sync.
    bool wrapped = false;
    if p1 >= 1.0 {
        f32 x = cast(f32, (1.0 - p0) / dt);
        if x < xs {
            wrapped = true;
            fix_step(&f.saw_prev, &f.saw_cur, x, -2.0f);
            fix_step(&f.pulse_prev, &f.pulse_cur, x, 2.0f);
            fix_corner(&f.tri_prev, &f.tri_cur, x, 2.0f * tri_slope);
        }
    }
    if p0 < pw && p1 >= pw {
        f32 x = cast(f32, (pw - p0) / dt);
        if x < xs { fix_step(&f.pulse_prev, &f.pulse_cur, x, -2.0f); }
    } else if wrapped && p1 - 1.0 >= pw {
        f32 x = cast(f32, (1.0 + pw - p0) / dt);
        if x < xs { fix_step(&f.pulse_prev, &f.pulse_cur, x, -2.0f); }
    }
    if p0 < 0.5 && p1 >= 0.5 {
        f32 x = cast(f32, (0.5 - p0) / dt);
        if x < xs { fix_corner(&f.tri_prev, &f.tri_cur, x, -2.0f * tri_slope); }
    }

    f64 p = p1;
    if xs <= 1.0f {
        // Hard sync: jump from the waveform values at the sync instant
        // to the values at phase 0.
        f64 ps = p0 + cast(f64, xs * dt);
        if ps >= 1.0 { ps -= 1.0; }
        fix_step(&f.saw_prev, &f.saw_cur, xs, -1.0f - naive_saw(ps));
        fix_step(&f.pulse_prev, &f.pulse_cur, xs, naive_pulse(0.0, pw) - naive_pulse(ps, pw));
        fix_step(&f.tri_prev, &f.tri_cur, xs, -1.0f - naive_tri(ps));
        f32 slope_before = tri_slope;
        if ps >= 0.5 { slope_before = -tri_slope; }
        fix_corner(&f.tri_prev, &f.tri_cur, xs, tri_slope - slope_before);
        p = cast(f64, (1.0f - xs) * dt);
    } else if p >= 1.0 {
        p -= 1.0;
    }
    o.phase = p;

    o.saw = o.saw_d + f.saw_prev;
    o.pulse = o.pulse_d + f.pulse_prev;
    o.tri = o.tri_d + f.tri_prev;
    o.sine = sin_cycle(o.tri * 0.25f);       // sin(pi/2 * tri): a sine shaped from the triangle

    o.saw_d = naive_saw(p) + f.saw_cur;
    o.pulse_d = naive_pulse(p, pw) + f.pulse_cur;
    o.tri_d = naive_tri(p) + f.tri_cur;
}
