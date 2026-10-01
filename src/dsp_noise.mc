// dsp_noise.mc: white, pink and red noise from one seeded source.
//
// White is the sum of four uniforms, close to Gaussian. Pink is Paul
// Kellet's refined filter (-3 dB/oct), red a leaky integrator of white
// (-6 dB/oct above about 15 Hz). All three are scaled to about the same
// RMS, 0.35 in canonical units.

import dsp_math;

const f32 NOISE_WHITE_GAIN = 0.3f;      // RMS of the uniform sum is 1.155
const f32 NOISE_PINK_GAIN = 0.328f;
const f32 NOISE_RED_POLE = 0.998f;
const f32 NOISE_RED_GAIN = 0.064f;

struct Noise {
    Rng rng;
    f32[7] b;                           // pink filter states
    f32 red;
}

struct NoiseSample {
    f32 white;
    f32 pink;
    f32 red;
}

void noise_init(Noise* n, u64 seed) {
    *n = Noise{};
    rng_seed(&n.rng, seed, 0x5eed);
}

NoiseSample noise_tick(Noise* n) {
    f32 u = rng_uniform(&n.rng) + rng_uniform(&n.rng) + rng_uniform(&n.rng) + rng_uniform(&n.rng);
    f32 w = u * NOISE_WHITE_GAIN;

    n.b[0] = 0.99886f * n.b[0] + w * 0.0555179f;
    n.b[1] = 0.99332f * n.b[1] + w * 0.0750759f;
    n.b[2] = 0.96900f * n.b[2] + w * 0.1538520f;
    n.b[3] = 0.86650f * n.b[3] + w * 0.3104856f;
    n.b[4] = 0.55000f * n.b[4] + w * 0.5329522f;
    n.b[5] = -0.7616f * n.b[5] - w * 0.0168980f;
    f32 pink = n.b[0] + n.b[1] + n.b[2] + n.b[3] + n.b[4] + n.b[5] + n.b[6] + w * 0.5362f;
    n.b[6] = w * 0.115926f;

    n.red = NOISE_RED_POLE * n.red + w * NOISE_RED_GAIN;
    return NoiseSample{ w, pink * NOISE_PINK_GAIN, n.red };
}
