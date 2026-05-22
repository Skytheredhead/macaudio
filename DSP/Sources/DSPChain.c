#include "DSPChain.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct Biquad {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
    float z1;
    float z2;
} Biquad;

struct DSPChain {
    double sampleRate;
    uint32_t channels;

    _Atomic(float) inputGainDB;
    _Atomic(uint32_t) eqEnabled;
    _Atomic(uint32_t) highPassEnabled;
    _Atomic(float) highPassHz;

    _Atomic(uint32_t) band1Enabled;
    _Atomic(float) band1FrequencyHz;
    _Atomic(float) band1GainDB;
    _Atomic(float) band1Q;

    _Atomic(uint32_t) band2Enabled;
    _Atomic(float) band2FrequencyHz;
    _Atomic(float) band2GainDB;
    _Atomic(float) band2Q;

    _Atomic(uint32_t) band3Enabled;
    _Atomic(float) band3FrequencyHz;
    _Atomic(float) band3GainDB;
    _Atomic(float) band3Q;

    _Atomic(uint32_t) compressorEnabled;
    _Atomic(float) compressorThresholdDB;
    _Atomic(float) compressorRatio;
    _Atomic(float) compressorAttackMs;
    _Atomic(float) compressorReleaseMs;
    _Atomic(float) makeupGainDB;

    _Atomic(uint32_t) limiterEnabled;
    _Atomic(float) limiterCeilingDB;
    _Atomic(float) outputGainDB;

    _Atomic(uint32_t) denoiseEnabled;
    _Atomic(float) denoiseStrength;

    _Atomic(uint32_t) gateEnabled;
    _Atomic(float) gateThresholdDB;
    _Atomic(float) gateAttackMs;
    _Atomic(float) gateReleaseMs;

    float smoothedInputGainDB;
    float smoothedOutputGainDB;
    float smoothedDenoiseGain;
    float compEnvelope;
    float compGainDB;
    float gateEnvelope;
    float gateGain;
    float noiseFloor;

    Biquad highPass;
    Biquad band1;
    Biquad band2;
    Biquad band3;

    _Atomic(float) meterInputPeak;
    _Atomic(float) meterInputRMS;
    _Atomic(float) meterOutputPeak;
    _Atomic(float) meterOutputRMS;
    _Atomic(float) meterCompressorInputRMS;
    _Atomic(float) meterCompressorOutputRMS;
    _Atomic(float) meterGainReductionDB;
    _Atomic(uint32_t) meterClippedSamples;
};

static inline float clampf(float value, float minimum, float maximum) {
    return value < minimum ? minimum : (value > maximum ? maximum : value);
}

static inline float db_to_linear(float db) {
    return powf(10.0f, db / 20.0f);
}

static inline float linear_to_db(float linear) {
    if (linear <= 0.0000001f) {
        return -140.0f;
    }
    return 20.0f * log10f(linear);
}

static void biquad_reset(Biquad* biquad) {
    biquad->z1 = 0.0f;
    biquad->z2 = 0.0f;
}

static inline float biquad_process(Biquad* biquad, float x) {
    const float y = biquad->b0 * x + biquad->z1;
    biquad->z1 = biquad->b1 * x - biquad->a1 * y + biquad->z2;
    biquad->z2 = biquad->b2 * x - biquad->a2 * y;
    return y;
}

static void biquad_set_from_raw(Biquad* biquad,
                                float b0,
                                float b1,
                                float b2,
                                float a0,
                                float a1,
                                float a2) {
    const float invA0 = 1.0f / a0;
    biquad->b0 = b0 * invA0;
    biquad->b1 = b1 * invA0;
    biquad->b2 = b2 * invA0;
    biquad->a1 = a1 * invA0;
    biquad->a2 = a2 * invA0;
}

static void biquad_set_highpass(Biquad* biquad, float sampleRate, float cutoffHz, float q) {
    const float omega = 2.0f * (float)M_PI * cutoffHz / sampleRate;
    const float sinW = sinf(omega);
    const float cosW = cosf(omega);
    const float alpha = sinW / (2.0f * q);

    biquad_set_from_raw(
        biquad,
        (1.0f + cosW) * 0.5f,
        -(1.0f + cosW),
        (1.0f + cosW) * 0.5f,
        1.0f + alpha,
        -2.0f * cosW,
        1.0f - alpha
    );
}

static void biquad_set_peaking(Biquad* biquad, float sampleRate, float frequencyHz, float q, float gainDB) {
    const float A = powf(10.0f, gainDB / 40.0f);
    const float omega = 2.0f * (float)M_PI * frequencyHz / sampleRate;
    const float sinW = sinf(omega);
    const float cosW = cosf(omega);
    const float alpha = sinW / (2.0f * q);

    biquad_set_from_raw(
        biquad,
        1.0f + alpha * A,
        -2.0f * cosW,
        1.0f - alpha * A,
        1.0f + alpha / A,
        -2.0f * cosW,
        1.0f - alpha / A
    );
}

static DSPChainParameters dsp_chain_default_parameters(void) {
    DSPChainParameters params;
    memset(&params, 0, sizeof(params));
    params.inputGainDB = 0.0f;
    params.eqEnabled = true;
    params.highPassEnabled = true;
    params.highPassHz = 90.0f;
    params.band1Enabled = true;
    params.band1FrequencyHz = 160.0f;
    params.band1GainDB = 0.0f;
    params.band1Q = 0.9f;
    params.band2Enabled = true;
    params.band2FrequencyHz = 1800.0f;
    params.band2GainDB = 1.5f;
    params.band2Q = 1.0f;
    params.band3Enabled = true;
    params.band3FrequencyHz = 7200.0f;
    params.band3GainDB = 1.0f;
    params.band3Q = 0.8f;
    params.compressorEnabled = true;
    params.compressorThresholdDB = -18.0f;
    params.compressorRatio = 3.0f;
    params.compressorAttackMs = 8.0f;
    params.compressorReleaseMs = 120.0f;
    params.makeupGainDB = 2.0f;
    params.limiterEnabled = true;
    params.limiterCeilingDB = -1.0f;
    params.outputGainDB = 0.0f;
    params.denoiseEnabled = false;
    params.denoiseStrength = 0.0f;
    params.gateEnabled = false;
    params.gateThresholdDB = -45.0f;
    params.gateAttackMs = 10.0f;
    params.gateReleaseMs = 120.0f;
    return params;
}

static void dsp_chain_rebuild_filters(DSPChain* chain) {
    const float sampleRate = (float)chain->sampleRate;
    biquad_set_highpass(&chain->highPass, sampleRate, clampf(atomic_load_explicit(&chain->highPassHz, memory_order_relaxed), 40.0f, 240.0f), 0.707f);
    biquad_set_peaking(
        &chain->band1,
        sampleRate,
        clampf(atomic_load_explicit(&chain->band1FrequencyHz, memory_order_relaxed), 60.0f, 18000.0f),
        clampf(atomic_load_explicit(&chain->band1Q, memory_order_relaxed), 0.2f, 6.0f),
        clampf(atomic_load_explicit(&chain->band1GainDB, memory_order_relaxed), -18.0f, 18.0f)
    );
    biquad_set_peaking(
        &chain->band2,
        sampleRate,
        clampf(atomic_load_explicit(&chain->band2FrequencyHz, memory_order_relaxed), 60.0f, 18000.0f),
        clampf(atomic_load_explicit(&chain->band2Q, memory_order_relaxed), 0.2f, 6.0f),
        clampf(atomic_load_explicit(&chain->band2GainDB, memory_order_relaxed), -18.0f, 18.0f)
    );
    biquad_set_peaking(
        &chain->band3,
        sampleRate,
        clampf(atomic_load_explicit(&chain->band3FrequencyHz, memory_order_relaxed), 60.0f, 18000.0f),
        clampf(atomic_load_explicit(&chain->band3Q, memory_order_relaxed), 0.2f, 6.0f),
        clampf(atomic_load_explicit(&chain->band3GainDB, memory_order_relaxed), -18.0f, 18.0f)
    );
}

DSPChain* dsp_chain_create(double sampleRate, uint32_t channels) {
    if (sampleRate < 8000.0 || channels == 0U) {
        return NULL;
    }

    DSPChain* chain = (DSPChain*)calloc(1, sizeof(DSPChain));
    if (chain == NULL) {
        return NULL;
    }

    chain->sampleRate = sampleRate;
    chain->channels = channels;
    const DSPChainParameters defaults = dsp_chain_default_parameters();
    dsp_chain_set_parameters(chain, defaults);
    chain->smoothedInputGainDB = defaults.inputGainDB;
    chain->smoothedOutputGainDB = defaults.outputGainDB;
    chain->smoothedDenoiseGain = 1.0f;
    chain->noiseFloor = 0.0008f;
    chain->gateGain = 1.0f;
    dsp_chain_rebuild_filters(chain);
    return chain;
}

void dsp_chain_destroy(DSPChain* chain) {
    free(chain);
}

void dsp_chain_reset(DSPChain* chain) {
    if (chain == NULL) {
        return;
    }
    biquad_reset(&chain->highPass);
    biquad_reset(&chain->band1);
    biquad_reset(&chain->band2);
    biquad_reset(&chain->band3);
    chain->compEnvelope = 0.0f;
    chain->compGainDB = 0.0f;
    chain->gateEnvelope = 0.0f;
    chain->gateGain = 1.0f;
    chain->noiseFloor = 0.0008f;
    chain->smoothedDenoiseGain = 1.0f;
}

void dsp_chain_set_parameters(DSPChain* chain, DSPChainParameters parameters) {
    if (chain == NULL) {
        return;
    }

    atomic_store_explicit(&chain->inputGainDB, parameters.inputGainDB, memory_order_relaxed);
    atomic_store_explicit(&chain->eqEnabled, parameters.eqEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->highPassEnabled, parameters.highPassEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->highPassHz, parameters.highPassHz, memory_order_relaxed);

    atomic_store_explicit(&chain->band1Enabled, parameters.band1Enabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->band1FrequencyHz, parameters.band1FrequencyHz, memory_order_relaxed);
    atomic_store_explicit(&chain->band1GainDB, parameters.band1GainDB, memory_order_relaxed);
    atomic_store_explicit(&chain->band1Q, parameters.band1Q, memory_order_relaxed);

    atomic_store_explicit(&chain->band2Enabled, parameters.band2Enabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->band2FrequencyHz, parameters.band2FrequencyHz, memory_order_relaxed);
    atomic_store_explicit(&chain->band2GainDB, parameters.band2GainDB, memory_order_relaxed);
    atomic_store_explicit(&chain->band2Q, parameters.band2Q, memory_order_relaxed);

    atomic_store_explicit(&chain->band3Enabled, parameters.band3Enabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->band3FrequencyHz, parameters.band3FrequencyHz, memory_order_relaxed);
    atomic_store_explicit(&chain->band3GainDB, parameters.band3GainDB, memory_order_relaxed);
    atomic_store_explicit(&chain->band3Q, parameters.band3Q, memory_order_relaxed);

    atomic_store_explicit(&chain->compressorEnabled, parameters.compressorEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->compressorThresholdDB, parameters.compressorThresholdDB, memory_order_relaxed);
    atomic_store_explicit(&chain->compressorRatio, parameters.compressorRatio, memory_order_relaxed);
    atomic_store_explicit(&chain->compressorAttackMs, parameters.compressorAttackMs, memory_order_relaxed);
    atomic_store_explicit(&chain->compressorReleaseMs, parameters.compressorReleaseMs, memory_order_relaxed);
    atomic_store_explicit(&chain->makeupGainDB, parameters.makeupGainDB, memory_order_relaxed);

    atomic_store_explicit(&chain->limiterEnabled, parameters.limiterEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->limiterCeilingDB, parameters.limiterCeilingDB, memory_order_relaxed);
    atomic_store_explicit(&chain->outputGainDB, parameters.outputGainDB, memory_order_relaxed);

    atomic_store_explicit(&chain->denoiseEnabled, parameters.denoiseEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->denoiseStrength, parameters.denoiseStrength, memory_order_relaxed);

    atomic_store_explicit(&chain->gateEnabled, parameters.gateEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->gateThresholdDB, parameters.gateThresholdDB, memory_order_relaxed);
    atomic_store_explicit(&chain->gateAttackMs, parameters.gateAttackMs, memory_order_relaxed);
    atomic_store_explicit(&chain->gateReleaseMs, parameters.gateReleaseMs, memory_order_relaxed);
}

DSPChainParameters dsp_chain_get_parameters(const DSPChain* chain) {
    DSPChainParameters params = dsp_chain_default_parameters();
    if (chain == NULL) {
        return params;
    }

    params.inputGainDB = atomic_load_explicit(&chain->inputGainDB, memory_order_relaxed);
    params.eqEnabled = atomic_load_explicit(&chain->eqEnabled, memory_order_relaxed) != 0U;
    params.highPassEnabled = atomic_load_explicit(&chain->highPassEnabled, memory_order_relaxed) != 0U;
    params.highPassHz = atomic_load_explicit(&chain->highPassHz, memory_order_relaxed);
    params.band1Enabled = atomic_load_explicit(&chain->band1Enabled, memory_order_relaxed) != 0U;
    params.band1FrequencyHz = atomic_load_explicit(&chain->band1FrequencyHz, memory_order_relaxed);
    params.band1GainDB = atomic_load_explicit(&chain->band1GainDB, memory_order_relaxed);
    params.band1Q = atomic_load_explicit(&chain->band1Q, memory_order_relaxed);
    params.band2Enabled = atomic_load_explicit(&chain->band2Enabled, memory_order_relaxed) != 0U;
    params.band2FrequencyHz = atomic_load_explicit(&chain->band2FrequencyHz, memory_order_relaxed);
    params.band2GainDB = atomic_load_explicit(&chain->band2GainDB, memory_order_relaxed);
    params.band2Q = atomic_load_explicit(&chain->band2Q, memory_order_relaxed);
    params.band3Enabled = atomic_load_explicit(&chain->band3Enabled, memory_order_relaxed) != 0U;
    params.band3FrequencyHz = atomic_load_explicit(&chain->band3FrequencyHz, memory_order_relaxed);
    params.band3GainDB = atomic_load_explicit(&chain->band3GainDB, memory_order_relaxed);
    params.band3Q = atomic_load_explicit(&chain->band3Q, memory_order_relaxed);
    params.compressorEnabled = atomic_load_explicit(&chain->compressorEnabled, memory_order_relaxed) != 0U;
    params.compressorThresholdDB = atomic_load_explicit(&chain->compressorThresholdDB, memory_order_relaxed);
    params.compressorRatio = atomic_load_explicit(&chain->compressorRatio, memory_order_relaxed);
    params.compressorAttackMs = atomic_load_explicit(&chain->compressorAttackMs, memory_order_relaxed);
    params.compressorReleaseMs = atomic_load_explicit(&chain->compressorReleaseMs, memory_order_relaxed);
    params.makeupGainDB = atomic_load_explicit(&chain->makeupGainDB, memory_order_relaxed);
    params.limiterEnabled = atomic_load_explicit(&chain->limiterEnabled, memory_order_relaxed) != 0U;
    params.limiterCeilingDB = atomic_load_explicit(&chain->limiterCeilingDB, memory_order_relaxed);
    params.outputGainDB = atomic_load_explicit(&chain->outputGainDB, memory_order_relaxed);
    params.denoiseEnabled = atomic_load_explicit(&chain->denoiseEnabled, memory_order_relaxed) != 0U;
    params.denoiseStrength = atomic_load_explicit(&chain->denoiseStrength, memory_order_relaxed);
    params.gateEnabled = atomic_load_explicit(&chain->gateEnabled, memory_order_relaxed) != 0U;
    params.gateThresholdDB = atomic_load_explicit(&chain->gateThresholdDB, memory_order_relaxed);
    params.gateAttackMs = atomic_load_explicit(&chain->gateAttackMs, memory_order_relaxed);
    params.gateReleaseMs = atomic_load_explicit(&chain->gateReleaseMs, memory_order_relaxed);
    return params;
}

void dsp_chain_copy_meters(const DSPChain* chain, DSPChainMeters* outMeters) {
    if (chain == NULL || outMeters == NULL) {
        return;
    }

    outMeters->inputPeak = atomic_load_explicit(&chain->meterInputPeak, memory_order_relaxed);
    outMeters->inputRMS = atomic_load_explicit(&chain->meterInputRMS, memory_order_relaxed);
    outMeters->outputPeak = atomic_load_explicit(&chain->meterOutputPeak, memory_order_relaxed);
    outMeters->outputRMS = atomic_load_explicit(&chain->meterOutputRMS, memory_order_relaxed);
    outMeters->compressorInputRMS = atomic_load_explicit(&chain->meterCompressorInputRMS, memory_order_relaxed);
    outMeters->compressorOutputRMS = atomic_load_explicit(&chain->meterCompressorOutputRMS, memory_order_relaxed);
    outMeters->gainReductionDB = atomic_load_explicit(&chain->meterGainReductionDB, memory_order_relaxed);
    outMeters->clippedSamples = atomic_load_explicit(&chain->meterClippedSamples, memory_order_relaxed);
}

void dsp_chain_process_mono(DSPChain* chain, float* samples, uint32_t frames) {
    if (chain == NULL || samples == NULL || frames == 0U) {
        return;
    }

    dsp_chain_rebuild_filters(chain);

    const float sampleRate = (float)chain->sampleRate;
    const float parameterAlpha = 1.0f - expf(-1.0f / (0.008f * sampleRate));
    const float compressorAttackCoeff = expf(-1.0f / (fmaxf(0.1f, atomic_load_explicit(&chain->compressorAttackMs, memory_order_relaxed)) * 0.001f * sampleRate));
    const float compressorReleaseCoeff = expf(-1.0f / (fmaxf(1.0f, atomic_load_explicit(&chain->compressorReleaseMs, memory_order_relaxed)) * 0.001f * sampleRate));
    const float gateAttackCoeff = expf(-1.0f / (fmaxf(0.1f, atomic_load_explicit(&chain->gateAttackMs, memory_order_relaxed)) * 0.001f * sampleRate));
    const float gateReleaseCoeff = expf(-1.0f / (fmaxf(1.0f, atomic_load_explicit(&chain->gateReleaseMs, memory_order_relaxed)) * 0.001f * sampleRate));

    const uint32_t eqEnabled = atomic_load_explicit(&chain->eqEnabled, memory_order_relaxed);
    const uint32_t highPassEnabled = atomic_load_explicit(&chain->highPassEnabled, memory_order_relaxed);
    const uint32_t band1Enabled = atomic_load_explicit(&chain->band1Enabled, memory_order_relaxed);
    const uint32_t band2Enabled = atomic_load_explicit(&chain->band2Enabled, memory_order_relaxed);
    const uint32_t band3Enabled = atomic_load_explicit(&chain->band3Enabled, memory_order_relaxed);
    const uint32_t compressorEnabled = atomic_load_explicit(&chain->compressorEnabled, memory_order_relaxed);
    const uint32_t limiterEnabled = atomic_load_explicit(&chain->limiterEnabled, memory_order_relaxed);
    const uint32_t denoiseEnabled = atomic_load_explicit(&chain->denoiseEnabled, memory_order_relaxed);
    const uint32_t gateEnabled = atomic_load_explicit(&chain->gateEnabled, memory_order_relaxed);

    const float thresholdDB = atomic_load_explicit(&chain->compressorThresholdDB, memory_order_relaxed);
    const float ratio = fmaxf(1.0f, atomic_load_explicit(&chain->compressorRatio, memory_order_relaxed));
    const float makeupDB = atomic_load_explicit(&chain->makeupGainDB, memory_order_relaxed);
    const float limiterLinear = db_to_linear(clampf(atomic_load_explicit(&chain->limiterCeilingDB, memory_order_relaxed), -18.0f, 0.0f));
    const float denoiseStrength = clampf(atomic_load_explicit(&chain->denoiseStrength, memory_order_relaxed), 0.0f, 1.0f);
    const float gateThresholdLinear = db_to_linear(clampf(atomic_load_explicit(&chain->gateThresholdDB, memory_order_relaxed), -90.0f, -12.0f));

    float inputPeak = 0.0f;
    float inputEnergy = 0.0f;
    float outputPeak = 0.0f;
    float outputEnergy = 0.0f;
    float compressorInputEnergy = 0.0f;
    float compressorOutputEnergy = 0.0f;
    float maxGainReduction = 0.0f;
    uint32_t clipped = 0U;

    for (uint32_t frame = 0; frame < frames; ++frame) {
        chain->smoothedInputGainDB += parameterAlpha * (atomic_load_explicit(&chain->inputGainDB, memory_order_relaxed) - chain->smoothedInputGainDB);
        chain->smoothedOutputGainDB += parameterAlpha * (atomic_load_explicit(&chain->outputGainDB, memory_order_relaxed) - chain->smoothedOutputGainDB);

        float sample = samples[frame];
        inputPeak = fmaxf(inputPeak, fabsf(sample));
        inputEnergy += sample * sample;

        sample *= db_to_linear(chain->smoothedInputGainDB);

        if (eqEnabled != 0U) {
            if (highPassEnabled != 0U) {
                sample = biquad_process(&chain->highPass, sample);
            }
            if (band1Enabled != 0U) {
                sample = biquad_process(&chain->band1, sample);
            }
            if (band2Enabled != 0U) {
                sample = biquad_process(&chain->band2, sample);
            }
            if (band3Enabled != 0U) {
                sample = biquad_process(&chain->band3, sample);
            }
        }

        if (denoiseEnabled != 0U && denoiseStrength > 0.001f) {
            const float absolute = fabsf(sample);
            const float floorInput = fminf(absolute, 0.02f);
            chain->noiseFloor = (0.995f * chain->noiseFloor) + (0.005f * floorInput);
            const float threshold = fmaxf(0.0010f, chain->noiseFloor * (2.0f + denoiseStrength * 3.0f));
            const float normalized = clampf(absolute / threshold, 0.0f, 1.0f);
            const float targetGain = 1.0f - ((1.0f - normalized) * denoiseStrength * 0.35f);
            chain->smoothedDenoiseGain += 0.02f * (targetGain - chain->smoothedDenoiseGain);
            sample *= chain->smoothedDenoiseGain;
        } else {
            chain->smoothedDenoiseGain += 0.04f * (1.0f - chain->smoothedDenoiseGain);
        }

        if (gateEnabled != 0U) {
            const float gateInput = fabsf(sample);
            const float envelopeCoeff = gateInput > chain->gateEnvelope ? 0.08f : 0.01f;
            chain->gateEnvelope += envelopeCoeff * (gateInput - chain->gateEnvelope);
            const float targetGateGain = chain->gateEnvelope >= gateThresholdLinear ? 1.0f : 0.0f;
            const float gateCoeff = targetGateGain > chain->gateGain ? gateAttackCoeff : gateReleaseCoeff;
            chain->gateGain = gateCoeff * chain->gateGain + (1.0f - gateCoeff) * targetGateGain;
            sample *= (0.06f + 0.94f * chain->gateGain);
        } else {
            chain->gateGain += 0.03f * (1.0f - chain->gateGain);
        }

        compressorInputEnergy += sample * sample;

        if (compressorEnabled != 0U) {
            const float detector = fabsf(sample) + 0.0000001f;
            if (detector > chain->compEnvelope) {
                chain->compEnvelope = compressorAttackCoeff * chain->compEnvelope + (1.0f - compressorAttackCoeff) * detector;
            } else {
                chain->compEnvelope = compressorReleaseCoeff * chain->compEnvelope + (1.0f - compressorReleaseCoeff) * detector;
            }

            const float envDB = linear_to_db(chain->compEnvelope);
            float targetGainDB = 0.0f;
            if (envDB > thresholdDB) {
                const float compressedDB = thresholdDB + (envDB - thresholdDB) / ratio;
                targetGainDB = compressedDB - envDB;
            }

            const float grCoeff = targetGainDB < chain->compGainDB ? 0.15f : 0.04f;
            chain->compGainDB += grCoeff * (targetGainDB - chain->compGainDB);
            maxGainReduction = fmaxf(maxGainReduction, -chain->compGainDB);
            sample *= db_to_linear(chain->compGainDB + makeupDB);
        } else {
            chain->compGainDB += 0.1f * (0.0f - chain->compGainDB);
        }

        compressorOutputEnergy += sample * sample;

        sample *= db_to_linear(chain->smoothedOutputGainDB);

        if (limiterEnabled != 0U) {
            if (fabsf(sample) > limiterLinear) {
                sample = copysignf(limiterLinear, sample);
                clipped += 1U;
            }
        } else if (fabsf(sample) > 0.999f) {
            clipped += 1U;
        }

        outputPeak = fmaxf(outputPeak, fabsf(sample));
        outputEnergy += sample * sample;
        samples[frame] = sample;
    }

    const float inverseFrames = 1.0f / (float)frames;
    atomic_store_explicit(&chain->meterInputPeak, inputPeak, memory_order_relaxed);
    atomic_store_explicit(&chain->meterInputRMS, sqrtf(inputEnergy * inverseFrames), memory_order_relaxed);
    atomic_store_explicit(&chain->meterOutputPeak, outputPeak, memory_order_relaxed);
    atomic_store_explicit(&chain->meterOutputRMS, sqrtf(outputEnergy * inverseFrames), memory_order_relaxed);
    atomic_store_explicit(&chain->meterCompressorInputRMS, sqrtf(compressorInputEnergy * inverseFrames), memory_order_relaxed);
    atomic_store_explicit(&chain->meterCompressorOutputRMS, sqrtf(compressorOutputEnergy * inverseFrames), memory_order_relaxed);
    atomic_store_explicit(&chain->meterGainReductionDB, maxGainReduction, memory_order_relaxed);
    atomic_store_explicit(&chain->meterClippedSamples, clipped, memory_order_relaxed);
}
