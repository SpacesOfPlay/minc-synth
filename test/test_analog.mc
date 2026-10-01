// test_analog.mc: headline numbers of the analog reference suite
// (plan.md section 8a). `minc run analog` prints the full report; these
// checks keep the numbers from drifting.

import math;
import "util/check.mc";
import "util/analog_suite.mc";

void test_linear() {
    Resp lad = compare_linear(LIN_LADDER, 1000.0, 0.0);
    print("ladder: delay {} samples, magnitude within {} dB and phase within {} deg to 2 kHz\n",
          lad.delay_samples, resp_worst_mag(&lad, 2000.0), resp_worst_phase(&lad, 2000.0));
    check(resp_worst_mag(&lad, 2000.0) < 0.05, "ladder magnitude matches analog within 0.05 dB to 2 kHz");
    check(resp_worst_phase(&lad, 2000.0) < 0.5, "ladder phase matches analog within 0.5 deg to 2 kHz, delay aside");
    check(lad.delay_samples > 3.7 && lad.delay_samples < 3.9, "ladder oversampler latency is 3.8 samples");

    Resp dir = compare_linear_at(LIN_LADDER_DIRECT, 1000.0, 0.0, 96000.0);
    print("ladder in a 96 kHz engine: delay {} samples, magnitude within {} dB to 2 kHz, {} dB to 4 kHz\n",
          dir.delay_samples, resp_worst_mag(&dir, 2000.0), resp_worst_mag(&dir, 4000.0));
    check(fabs(dir.delay_samples) < 0.1, "in a 96 kHz engine the ladder adds no latency");
    check(resp_worst_mag(&dir, 2000.0) < 0.05, "in a 96 kHz engine the ladder matches analog within 0.05 dB to 2 kHz");
    check(resp_worst_phase(&dir, 4000.0) < 1.0, "in a 96 kHz engine the ladder phase matches analog within 1 deg to 4 kHz");

    Resp hp = compare_linear(LIN_HP4, 1000.0, 0.0);
    Resp sv = compare_linear(LIN_SVF_LOW, 1000.0, 0.7071);
    check(resp_worst_mag(&hp, 2000.0) < 0.1 && fabs(hp.delay_samples) < 0.1, "HIGHPASS matches analog to 2 kHz, no delay");
    check(resp_worst_mag(&sv, 2000.0) < 0.1 && fabs(sv.delay_samples) < 0.1, "SVF matches analog to 2 kHz, no delay");
}

void test_waves() {
    WaveCmp saw = compare_wave(WAVE_SAW, 439.0);
    WaveCmp tri = compare_wave(WAVE_TRI, 109.0);
    WaveCmp sine = compare_wave(WAVE_SINE, 109.0);
    print("saw 439 Hz: error below 5 kHz {} dB, aliases {} dB; triangle {} dB; sine {} dB\n",
          saw.esr_5k, saw.alias_db, tri.esr_all, sine.esr_all);
    check(saw.esr_5k < -45.0, "saw within -45 dB of the ideal below 5 kHz");
    check(saw.alias_db < -34.0, "saw aliases below -34 dB");
    check(tri.esr_all < -74.0, "triangle within -74 dB of the ideal");
    check(sine.esr_all < -110.0, "sine within -110 dB of the ideal: the f32 floor");
    check(fabs(saw.delay_samples) < 1e-3, "waveforms line up with the reference phase");
}

void test_env() {
    EnvCmp e = compare_env(0.01, 0.1, 0.5);
    check(e.max_err < 1e-3, "envelope within 1e-3 of the exact RC curve");
    check(fabs(e.corner_err_samples) <= 1.0, "attack corner within one sample");
}

void test_ladder_nonlinear() {
    DrivenCmp d0 = compare_ladder_driven(1000.0, 0.0, 1.0, 110.0);
    DrivenCmp d3 = compare_ladder_driven(1000.0, 3.0, 1.0, 110.0);
    print("driven ladder: {} dB and {} dB from RK4 after the delay\n", d0.esr_comp_db, d3.esr_comp_db);
    check(d0.esr_comp_db < -80.0 && d3.esr_comp_db < -80.0, "driven ladder within -80 dB of RK4, delay aside");
    check(fabs(d0.h3_digital_db - d0.h3_analog_db) < 0.05, "saturation harmonics match RK4 within 0.05 dB");

    SelfOscCmp s = compare_self_osc(1000.0, 4.2, 2.0);
    print("self-oscillation: digital {} cent, analog {} cent\n", s.cents_digital, s.cents_analog);
    check(fabs(s.cents_digital - s.cents_analog) < 0.5, "self-oscillation pitch matches RK4 within 0.5 cent");
    check(fabs(s.amp_digital / s.amp_analog - 1.0) < 0.01, "self-oscillation level matches RK4 within 1 %");
}

void test_loop() {
    LoopCmp l48 = compare_loop(48000.0, 1000.0, 2.0, 0.8);
    LoopCmp l96 = compare_loop(96000.0, 1000.0, 2.0, 0.8);
    print("feedback loop: 48 kHz {} dB / {} deg, 96 kHz {} dB / {} deg; delay model leaves {} / {} dB\n",
          l48.worst_mag_4k, l48.worst_phase_4k, l96.worst_mag_4k, l96.worst_phase_4k, l48.residual_db, l96.residual_db);
    check(l48.residual_db < -25.0, "at 48 kHz the loop error is the cable and oversampler delays");
    check(l96.worst_mag_4k < 0.3 && l96.worst_phase_4k < 6.0,
          "at 96 kHz, with LOWPASS unoversampled, the loop is within 0.3 dB and 6 deg of analog");
    check(l96.worst_mag_4k < 0.5 * l48.worst_mag_4k, "doubling the engine rate more than halves the loop error");
}

void test_chaos() {
    FmParams chaotic = FmParams{ 0.0, 2.0, 1.0, 0.9 };
    FmParams calm = FmParams{ 0.0, 0.5, 1.0, 0.9 };
    f64 la = fm_lyapunov_analog(chaotic);
    ChaosCmp c = compare_chaos(chaotic, 48000.0);
    f64 calm_a = fm_lyapunov_analog(calm);
    f64 calm_d = fm_lyapunov_digital(calm, 48000.0);
    print("chaos: Lyapunov analog {} /s, engine {} /s; distribution distance {}, bands within {} dB\n",
          la, c.lyap_digital, c.hist_distance, c.band_worst_db);
    check(la > 100.0 && c.lyap_digital > 100.0, "depth 2 is chaotic in both");
    check(fabs(c.lyap_digital / la - 1.0) < 0.3, "the engine's Lyapunov exponent is within 30 % of analog");
    check(calm_a < 10.0 && calm_d < 10.0, "depth 0.5 is periodic in both");
    check(c.hist_distance < 0.15, "the chaotic signal has the analog amplitude distribution");
    check(c.band_worst_db < 1.5, "the chaotic signal has the analog spectrum within 1.5 dB per octave");
}

i32 main() {
    test_linear();
    test_waves();
    test_env();
    test_ladder_nonlinear();
    test_loop();
    test_chaos();
    return check_done();
}
