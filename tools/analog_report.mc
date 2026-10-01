// analog_report.mc: the full analog reference report (plan.md section 8a).
//
//   minc run analog
//
// Prints every comparison of the digital modules with their analog
// references. test/test_analog.mc pins the headline numbers.

import math;
import "../test/util/analog_suite.mc";

f64 now_s() { return cast(f64, qpc()) / cast(f64, qpf()); }

// Seconds of audio per second of CPU: the rack and the default patch with
// a key held, rendered at 48 kHz device rate.
f64 speed(i32 os) {
    Engine* e = engine_new_os(48000.0f, os);
    defer engine_free(e);
    rack_build(e);
    rack_default_patch(e);
    ignore engine_key_on(e, 48);
    ignore rig_run(e, 9600);
    f64 t0 = now_s();
    ignore rig_run(e, 48000 * 10);
    return 10.0 / (now_s() - t0);
}

i32 main() {
    print("== engine rate: cost, 48 kHz device, 10-module rack ==\n");
    f64 s1 = speed(1);
    f64 s2 = speed(2);
    f64 s4 = speed(4);
    print("  1x: {}x real time ({} % of a core)\n", s1, 100.0 / s1);
    print("  2x (NORMAL): {}x real time ({} % of a core, {} times the 1x cost)\n", s2, 100.0 / s2, s1 / s2);
    print("  4x (HIGH): {}x real time ({} % of a core, {} times the 1x cost)\n\n", s4, 100.0 / s4, s1 / s4);

    print("== linear responses, digital / analog ==\n");
    Resp r = compare_linear(LIN_LADDER, 1000.0, 0.0);
    print_resp("LOWPASS ladder, small signal, fc 1 kHz, k 0", &r);
    r = compare_linear(LIN_LADDER, 1000.0, 3.8);
    print_resp("LOWPASS ladder, small signal, fc 1 kHz, k 3.8", &r);
    r = compare_linear(LIN_LADDER, 5000.0, 2.0);
    print_resp("LOWPASS ladder, small signal, fc 5 kHz, k 2", &r);
    r = compare_linear_at(LIN_LADDER_DIRECT, 1000.0, 0.0, 96000.0);
    print_resp("LOWPASS ladder in a 96 kHz engine (no oversampler of its own), fc 1 kHz, k 0; delay in 96 kHz samples", &r);
    r = compare_linear_at(LIN_LADDER_DIRECT, 1000.0, 3.8, 96000.0);
    print_resp("LOWPASS ladder in a 96 kHz engine, fc 1 kHz, k 3.8", &r);
    r = compare_linear(LIN_HP4, 1000.0, 0.0);
    print_resp("HIGHPASS 4-pole, fc 1 kHz", &r);
    r = compare_linear(LIN_SVF_LOW, 1000.0, 0.7071);
    print_resp("SVF low, fc 1 kHz, Q 0.707", &r);
    r = compare_linear(LIN_SVF_BAND, 2000.0, 4.0);
    print_resp("SVF band, fc 2 kHz, Q 4", &r);

    print("\n== oscillator waveforms, digital / ideal band-limited ==\n");
    // Whole Hz sharing no factor with 48000, so aliases miss the harmonics.
    f64[4] freqs = { 109.0, 439.0, 1777.0, 4363.0 };
    for i32 i = 0; i < 4; i++ {
        WaveCmp w = compare_wave(WAVE_SAW, freqs[i]);
        print_wave("saw  ", &w);
        w = compare_wave(WAVE_PULSE, freqs[i]);
        print_wave("pulse", &w);
        w = compare_wave(WAVE_TRI, freqs[i]);
        print_wave("tri  ", &w);
        w = compare_wave(WAVE_SINE, freqs[i]);
        print_wave("sine ", &w);
    }

    print("\n== LOWPASS ladder, nonlinear, digital / RK4 ==\n");
    f64[3] amps = { 0.3, 1.0, 3.0 };
    f64[2] ks = { 0.0, 3.0 };
    for i32 ki = 0; ki < 2; ki++ {
        for i32 ai = 0; ai < 3; ai++ {
            DrivenCmp c = compare_ladder_driven(1000.0, ks[ki], amps[ai], 110.0);
            print("  fc 1 kHz, k {}, 110 Hz sine at {}: error {} dB raw, {} dB without the {}-sample delay; H3 {} dB digital, {} dB analog\n",
                  c.k, c.amp, c.esr_raw_db, c.esr_comp_db, c.delay_samples, c.h3_digital_db, c.h3_analog_db);
        }
    }
    f64[3] fcs = { 250.0, 1000.0, 4000.0 };
    for i32 fi = 0; fi < 3; fi++ {
        f64 secs = 2.0;
        if fcs[fi] < 500.0 { secs = 4.0; }
        SelfOscCmp s = compare_self_osc(fcs[fi], 4.2, secs);
        print("  self-oscillation fc {} Hz, k 4.2: digital {} cent / peak {}, analog {} cent / peak {}\n",
              s.fc, s.cents_digital, s.amp_digital, s.cents_analog, s.amp_analog);
    }
    SelfOscCmp s5 = compare_self_osc(1000.0, 5.0, 2.0);
    print("  self-oscillation fc 1000 Hz, k 5.0: digital {} cent / peak {}, analog {} cent / peak {}\n",
          s5.cents_digital, s5.amp_digital, s5.cents_analog, s5.amp_analog);

    print("\n== patch: LOWPASS fc 1 kHz k 2 in a feedback loop (MIX inverted, level 0.8), engine / zero-delay analog ==\n");
    f64[3] rates = { 48000.0, 96000.0, 192000.0 };
    for i32 ri = 0; ri < 3; ri++ {
        LoopCmp lc = compare_loop(rates[ri], 1000.0, 2.0, 0.8);
        print_loop(&lc);
    }

    print("\n== chaos: OSC.sine -> LOWPASS -> MIX -> OSC.pitch1 ==\n");
    print("  pitch 0 V, cutoff 1 V, res 0.9; largest Lyapunov exponent per second against FM depth (> 0: chaotic)\n");
    print("    depth    analog    engine 48 kHz    engine 96 kHz\n");
    for i32 di = 0; di <= 8; di++ {
        FmParams p = FmParams{ 0.0, 0.5 + 0.25 * cast(f64, di), 1.0, 0.9 };
        f64 la = fm_lyapunov_analog(p);
        f64 l48 = fm_lyapunov_digital(p, 48000.0);
        f64 l96 = fm_lyapunov_digital(p, 96000.0);
        print("    {}    {}    {}    {}\n", p.depth, la, l48, l96);
    }
    FmParams chaos = FmParams{ 0.0, 2.0, 1.0, 0.9 };
    f64 lc = fm_lyapunov_analog(chaos);
    FmLoopRef probe;
    fm_ref_init(&probe, chaos.pitch, chaos.depth, chaos.cutoff_v, chaos.res);
    for i32 i = 0; i < 48000 * REF_OS; i++ { fm_ref_step(&probe, 1.0 / (48000.0 * cast(f64, REF_OS))); }
    print("  chaotic point depth 2 (analog {} /s, oscillator up to {} Hz):\n", lc, probe.max_hz);
    ChaosCmp c48 = compare_chaos(chaos, 48000.0);
    print_chaos(&c48, lc);
    ChaosCmp c96 = compare_chaos(chaos, 96000.0);
    print_chaos(&c96, lc);
    FmParams calm = FmParams{ 0.0, 1.0, 1.0, 0.9 };
    print("  periodic point depth 1:\n");
    ChaosCmp p48 = compare_chaos(calm, 48000.0);
    print_chaos(&p48, 0.0);
    ChaosCmp p96 = compare_chaos(calm, 96000.0);
    print_chaos(&p96, 0.0);

    print("\n== envelope, digital / exact RC ==\n");
    f64[4] attacks = { 0.001, 0.01, 0.1, 1.0 };
    for i32 i = 0; i < 4; i++ {
        EnvCmp c = compare_env(attacks[i], 0.1, 0.5);
        print("  attack {} s: worst error {} (canonical), corner {} samples late\n",
              c.attack_s, c.max_err, c.corner_err_samples);
    }
    return 0;
}
