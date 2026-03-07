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
    _Atomic(float) hpfHz;
    _Atomic(float) lowGainDB;
    _Atomic(float) midGainDB;
    _Atomic(float) highGainDB;
    _Atomic(float) compressorThresholdDB;
    _Atomic(float) compressorRatio;
    _Atomic(float) compressorAttackMs;
    _Atomic(float) compressorReleaseMs;
    _Atomic(float) makeupGainDB;
    _Atomic(float) limiterCeilingDB;
    _Atomic(float) outputGainDB;
    _Atomic(float) denoiseStrength;
    _Atomic(float) gateThresholdDB;
    _Atomic(float) deEsserAmount;
    _Atomic(uint32_t) denoiseEnabled;
    _Atomic(uint32_t) gateEnabled;
    _Atomic(uint32_t) deEsserEnabled;

    float smoothedInputGainDB;
    float smoothedOutputGainDB;

    Biquad hpf;
    Biquad lowShelf;
    Biquad midPeak;
    Biquad highShelf;

    float envelope;
    float compGainDB;
    float gateEnvelope;
    float noiseFloor;

    _Atomic(float) meterInputPeak;
    _Atomic(float) meterInputRMS;
    _Atomic(float) meterOutputPeak;
    _Atomic(float) meterOutputRMS;
    _Atomic(float) meterGainReductionDB;
    _Atomic(uint32_t) meterClippedSamples;

    float lastHpfHz;
    float lastLowGainDB;
    float lastMidGainDB;
    float lastHighGainDB;
};

static inline float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
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

static void biquad_reset(Biquad* bq) {
    bq->z1 = 0.0f;
    bq->z2 = 0.0f;
}

static inline float biquad_process(Biquad* bq, float x) {
    const float y = bq->b0 * x + bq->z1;
    bq->z1 = bq->b1 * x - bq->a1 * y + bq->z2;
    bq->z2 = bq->b2 * x - bq->a2 * y;
    return y;
}

static void biquad_set_from_raw(Biquad* bq,
                                 float b0,
                                 float b1,
                                 float b2,
                                 float a0,
                                 float a1,
                                 float a2) {
    const float invA0 = 1.0f / a0;
    bq->b0 = b0 * invA0;
    bq->b1 = b1 * invA0;
    bq->b2 = b2 * invA0;
    bq->a1 = a1 * invA0;
    bq->a2 = a2 * invA0;
}

static void biquad_set_highpass(Biquad* bq, float sampleRate, float cutoffHz, float q) {
    const float omega = 2.0f * (float)M_PI * cutoffHz / sampleRate;
    const float cosW = cosf(omega);
    const float sinW = sinf(omega);
    const float alpha = sinW / (2.0f * q);

    const float b0 = (1.0f + cosW) * 0.5f;
    const float b1 = -(1.0f + cosW);
    const float b2 = (1.0f + cosW) * 0.5f;
    const float a0 = 1.0f + alpha;
    const float a1 = -2.0f * cosW;
    const float a2 = 1.0f - alpha;

    biquad_set_from_raw(bq, b0, b1, b2, a0, a1, a2);
}

static void biquad_set_peaking(Biquad* bq,
                               float sampleRate,
                               float centerHz,
                               float q,
                               float gainDB) {
    const float A = powf(10.0f, gainDB / 40.0f);
    const float omega = 2.0f * (float)M_PI * centerHz / sampleRate;
    const float sinW = sinf(omega);
    const float cosW = cosf(omega);
    const float alpha = sinW / (2.0f * q);

    const float b0 = 1.0f + alpha * A;
    const float b1 = -2.0f * cosW;
    const float b2 = 1.0f - alpha * A;
    const float a0 = 1.0f + alpha / A;
    const float a1 = -2.0f * cosW;
    const float a2 = 1.0f - alpha / A;

    biquad_set_from_raw(bq, b0, b1, b2, a0, a1, a2);
}

static void biquad_set_shelf(Biquad* bq,
                             float sampleRate,
                             float centerHz,
                             float slope,
                             float gainDB,
                             bool highShelf) {
    const float A = powf(10.0f, gainDB / 40.0f);
    const float omega = 2.0f * (float)M_PI * centerHz / sampleRate;
    const float sinW = sinf(omega);
    const float cosW = cosf(omega);
    const float alpha = sinW * 0.5f * sqrtf((A + 1.0f / A) * (1.0f / slope - 1.0f) + 2.0f);
    const float beta = 2.0f * sqrtf(A) * alpha;

    float b0 = 0.0f;
    float b1 = 0.0f;
    float b2 = 0.0f;
    float a0 = 0.0f;
    float a1 = 0.0f;
    float a2 = 0.0f;

    if (highShelf) {
        b0 = A * ((A + 1.0f) + (A - 1.0f) * cosW + beta);
        b1 = -2.0f * A * ((A - 1.0f) + (A + 1.0f) * cosW);
        b2 = A * ((A + 1.0f) + (A - 1.0f) * cosW - beta);
        a0 = (A + 1.0f) - (A - 1.0f) * cosW + beta;
        a1 = 2.0f * ((A - 1.0f) - (A + 1.0f) * cosW);
        a2 = (A + 1.0f) - (A - 1.0f) * cosW - beta;
    } else {
        b0 = A * ((A + 1.0f) - (A - 1.0f) * cosW + beta);
        b1 = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cosW);
        b2 = A * ((A + 1.0f) - (A - 1.0f) * cosW - beta);
        a0 = (A + 1.0f) + (A - 1.0f) * cosW + beta;
        a1 = -2.0f * ((A - 1.0f) + (A + 1.0f) * cosW);
        a2 = (A + 1.0f) + (A - 1.0f) * cosW - beta;
    }

    biquad_set_from_raw(bq, b0, b1, b2, a0, a1, a2);
}

static DSPChainParameters dsp_chain_default_parameters(void) {
    DSPChainParameters params;
    memset(&params, 0, sizeof(params));
    params.inputGainDB = 0.0f;
    params.hpfHz = 90.0f;
    params.lowGainDB = 0.0f;
    params.midGainDB = 0.0f;
    params.highGainDB = 0.0f;
    params.compressorThresholdDB = -18.0f;
    params.compressorRatio = 3.0f;
    params.compressorAttackMs = 8.0f;
    params.compressorReleaseMs = 120.0f;
    params.makeupGainDB = 2.0f;
    params.limiterCeilingDB = -1.0f;
    params.outputGainDB = 0.0f;
    params.denoiseEnabled = true;
    params.denoiseStrength = 0.25f;
    params.gateEnabled = false;
    params.gateThresholdDB = -45.0f;
    params.deEsserEnabled = false;
    params.deEsserAmount = 0.0f;
    return params;
}

static void dsp_chain_rebuild_filters(DSPChain* chain) {
    const float sampleRate = (float)chain->sampleRate;
    const float hpfHz = clampf(atomic_load_explicit(&chain->hpfHz, memory_order_relaxed), 40.0f, 240.0f);
    const float lowDB = clampf(atomic_load_explicit(&chain->lowGainDB, memory_order_relaxed), -18.0f, 18.0f);
    const float midDB = clampf(atomic_load_explicit(&chain->midGainDB, memory_order_relaxed), -18.0f, 18.0f);
    const float highDB = clampf(atomic_load_explicit(&chain->highGainDB, memory_order_relaxed), -18.0f, 18.0f);

    if (fabsf(chain->lastHpfHz - hpfHz) > 0.05f) {
        biquad_set_highpass(&chain->hpf, sampleRate, hpfHz, 0.707f);
        chain->lastHpfHz = hpfHz;
    }
    if (fabsf(chain->lastLowGainDB - lowDB) > 0.01f) {
        biquad_set_shelf(&chain->lowShelf, sampleRate, 140.0f, 0.95f, lowDB, false);
        chain->lastLowGainDB = lowDB;
    }
    if (fabsf(chain->lastMidGainDB - midDB) > 0.01f) {
        biquad_set_peaking(&chain->midPeak, sampleRate, 2200.0f, 0.9f, midDB);
        chain->lastMidGainDB = midDB;
    }
    if (fabsf(chain->lastHighGainDB - highDB) > 0.01f) {
        biquad_set_shelf(&chain->highShelf, sampleRate, 8500.0f, 0.9f, highDB, true);
        chain->lastHighGainDB = highDB;
    }
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

    chain->envelope = 0.0f;
    chain->compGainDB = 0.0f;
    chain->gateEnvelope = 0.0f;
    chain->noiseFloor = 0.0005f;
    chain->lastHpfHz = -1.0f;
    chain->lastLowGainDB = 1000.0f;
    chain->lastMidGainDB = 1000.0f;
    chain->lastHighGainDB = 1000.0f;
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
    biquad_reset(&chain->hpf);
    biquad_reset(&chain->lowShelf);
    biquad_reset(&chain->midPeak);
    biquad_reset(&chain->highShelf);
    chain->envelope = 0.0f;
    chain->compGainDB = 0.0f;
    chain->gateEnvelope = 0.0f;
    chain->noiseFloor = 0.0005f;
}

void dsp_chain_set_parameters(DSPChain* chain, DSPChainParameters parameters) {
    if (chain == NULL) {
        return;
    }

    atomic_store_explicit(&chain->inputGainDB, parameters.inputGainDB, memory_order_relaxed);
    atomic_store_explicit(&chain->hpfHz, parameters.hpfHz, memory_order_relaxed);
    atomic_store_explicit(&chain->lowGainDB, parameters.lowGainDB, memory_order_relaxed);
    atomic_store_explicit(&chain->midGainDB, parameters.midGainDB, memory_order_relaxed);
    atomic_store_explicit(&chain->highGainDB, parameters.highGainDB, memory_order_relaxed);

    atomic_store_explicit(&chain->compressorThresholdDB, parameters.compressorThresholdDB, memory_order_relaxed);
    atomic_store_explicit(&chain->compressorRatio, parameters.compressorRatio, memory_order_relaxed);
    atomic_store_explicit(&chain->compressorAttackMs, parameters.compressorAttackMs, memory_order_relaxed);
    atomic_store_explicit(&chain->compressorReleaseMs, parameters.compressorReleaseMs, memory_order_relaxed);
    atomic_store_explicit(&chain->makeupGainDB, parameters.makeupGainDB, memory_order_relaxed);
    atomic_store_explicit(&chain->limiterCeilingDB, parameters.limiterCeilingDB, memory_order_relaxed);
    atomic_store_explicit(&chain->outputGainDB, parameters.outputGainDB, memory_order_relaxed);

    atomic_store_explicit(&chain->denoiseEnabled, parameters.denoiseEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->denoiseStrength, parameters.denoiseStrength, memory_order_relaxed);

    atomic_store_explicit(&chain->gateEnabled, parameters.gateEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->gateThresholdDB, parameters.gateThresholdDB, memory_order_relaxed);

    atomic_store_explicit(&chain->deEsserEnabled, parameters.deEsserEnabled ? 1U : 0U, memory_order_relaxed);
    atomic_store_explicit(&chain->deEsserAmount, parameters.deEsserAmount, memory_order_relaxed);
}

DSPChainParameters dsp_chain_get_parameters(const DSPChain* chain) {
    DSPChainParameters params = dsp_chain_default_parameters();
    if (chain == NULL) {
        return params;
    }

    params.inputGainDB = atomic_load_explicit(&chain->inputGainDB, memory_order_relaxed);
    params.hpfHz = atomic_load_explicit(&chain->hpfHz, memory_order_relaxed);
    params.lowGainDB = atomic_load_explicit(&chain->lowGainDB, memory_order_relaxed);
    params.midGainDB = atomic_load_explicit(&chain->midGainDB, memory_order_relaxed);
    params.highGainDB = atomic_load_explicit(&chain->highGainDB, memory_order_relaxed);

    params.compressorThresholdDB = atomic_load_explicit(&chain->compressorThresholdDB, memory_order_relaxed);
    params.compressorRatio = atomic_load_explicit(&chain->compressorRatio, memory_order_relaxed);
    params.compressorAttackMs = atomic_load_explicit(&chain->compressorAttackMs, memory_order_relaxed);
    params.compressorReleaseMs = atomic_load_explicit(&chain->compressorReleaseMs, memory_order_relaxed);
    params.makeupGainDB = atomic_load_explicit(&chain->makeupGainDB, memory_order_relaxed);
    params.limiterCeilingDB = atomic_load_explicit(&chain->limiterCeilingDB, memory_order_relaxed);
    params.outputGainDB = atomic_load_explicit(&chain->outputGainDB, memory_order_relaxed);

    params.denoiseEnabled = atomic_load_explicit(&chain->denoiseEnabled, memory_order_relaxed) != 0U;
    params.denoiseStrength = atomic_load_explicit(&chain->denoiseStrength, memory_order_relaxed);
    params.gateEnabled = atomic_load_explicit(&chain->gateEnabled, memory_order_relaxed) != 0U;
    params.gateThresholdDB = atomic_load_explicit(&chain->gateThresholdDB, memory_order_relaxed);
    params.deEsserEnabled = atomic_load_explicit(&chain->deEsserEnabled, memory_order_relaxed) != 0U;
    params.deEsserAmount = atomic_load_explicit(&chain->deEsserAmount, memory_order_relaxed);
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
    outMeters->gainReductionDB = atomic_load_explicit(&chain->meterGainReductionDB, memory_order_relaxed);
    outMeters->clippedSamples = atomic_load_explicit(&chain->meterClippedSamples, memory_order_relaxed);
}

void dsp_chain_process_mono(DSPChain* chain, float* samples, uint32_t frames) {
    if (chain == NULL || samples == NULL || frames == 0U) {
        return;
    }

    dsp_chain_rebuild_filters(chain);

    const float sr = (float)chain->sampleRate;
    const float paramSmoothingMs = 8.0f;
    const float paramAlpha = 1.0f - expf(-1.0f / (fmaxf(1.0f, paramSmoothingMs) * 0.001f * sr));

    const float attackMs = fmaxf(0.1f, atomic_load_explicit(&chain->compressorAttackMs, memory_order_relaxed));
    const float releaseMs = fmaxf(1.0f, atomic_load_explicit(&chain->compressorReleaseMs, memory_order_relaxed));
    const float attackCoeff = expf(-1.0f / (attackMs * 0.001f * sr));
    const float releaseCoeff = expf(-1.0f / (releaseMs * 0.001f * sr));

    const float thresholdDB = atomic_load_explicit(&chain->compressorThresholdDB, memory_order_relaxed);
    const float ratio = fmaxf(1.0f, atomic_load_explicit(&chain->compressorRatio, memory_order_relaxed));
    const float makeupDB = atomic_load_explicit(&chain->makeupGainDB, memory_order_relaxed);

    const float limiterLinear = db_to_linear(clampf(atomic_load_explicit(&chain->limiterCeilingDB, memory_order_relaxed), -18.0f, 0.0f));

    const uint32_t denoiseEnabled = atomic_load_explicit(&chain->denoiseEnabled, memory_order_relaxed);
    const float denoiseStrength = clampf(atomic_load_explicit(&chain->denoiseStrength, memory_order_relaxed), 0.0f, 1.0f);

    const uint32_t gateEnabled = atomic_load_explicit(&chain->gateEnabled, memory_order_relaxed);
    const float gateThresholdLinear = db_to_linear(clampf(atomic_load_explicit(&chain->gateThresholdDB, memory_order_relaxed), -90.0f, -12.0f));

    const uint32_t deEsserEnabled = atomic_load_explicit(&chain->deEsserEnabled, memory_order_relaxed);
    const float deEsserAmount = clampf(atomic_load_explicit(&chain->deEsserAmount, memory_order_relaxed), 0.0f, 1.0f);

    float inputPeak = 0.0f;
    float outputPeak = 0.0f;
    float inputEnergy = 0.0f;
    float outputEnergy = 0.0f;
    float maxGainReduction = 0.0f;
    uint32_t clipped = 0U;

    for (uint32_t frame = 0; frame < frames; ++frame) {
        chain->smoothedInputGainDB += paramAlpha *
            (atomic_load_explicit(&chain->inputGainDB, memory_order_relaxed) - chain->smoothedInputGainDB);
        chain->smoothedOutputGainDB += paramAlpha *
            (atomic_load_explicit(&chain->outputGainDB, memory_order_relaxed) - chain->smoothedOutputGainDB);

        float x = samples[frame];
        const float inAbs = fabsf(x);
        inputPeak = fmaxf(inputPeak, inAbs);
        inputEnergy += x * x;

        x *= db_to_linear(chain->smoothedInputGainDB);

        x = biquad_process(&chain->hpf, x);
        x = biquad_process(&chain->lowShelf, x);
        x = biquad_process(&chain->midPeak, x);
        x = biquad_process(&chain->highShelf, x);

        if (denoiseEnabled != 0U) {
            const float currentAbs = fabsf(x);
            chain->noiseFloor = (0.9995f * chain->noiseFloor) + (0.0005f * fminf(currentAbs, 0.02f));
            const float suppressThreshold = fmaxf(chain->noiseFloor * (2.0f + denoiseStrength * 4.0f), 0.0008f);
            if (currentAbs < suppressThreshold) {
                const float attenuation = 1.0f - (denoiseStrength * 0.75f);
                x *= attenuation;
            }
        }

        if (gateEnabled != 0U) {
            const float gateIn = fabsf(x);
            const float gateCoeff = gateIn > chain->gateEnvelope ? 0.08f : 0.005f;
            chain->gateEnvelope += gateCoeff * (gateIn - chain->gateEnvelope);
            if (chain->gateEnvelope < gateThresholdLinear) {
                const float depth = clampf((gateThresholdLinear - chain->gateEnvelope) / gateThresholdLinear, 0.0f, 1.0f);
                x *= (1.0f - depth * 0.85f);
            }
        }

        if (deEsserEnabled != 0U && deEsserAmount > 0.0f) {
            // Lightweight placeholder de-esser: attenuate hot sibilant ranges by reducing positive peaks.
            const float sibilance = fmaxf(0.0f, fabsf(x) - 0.20f);
            x *= 1.0f - (sibilance * deEsserAmount * 0.35f);
        }

        const float detector = fabsf(x) + 0.0000001f;
        if (detector > chain->envelope) {
            chain->envelope = attackCoeff * chain->envelope + (1.0f - attackCoeff) * detector;
        } else {
            chain->envelope = releaseCoeff * chain->envelope + (1.0f - releaseCoeff) * detector;
        }

        const float envDB = linear_to_db(chain->envelope);
        float targetGainDB = 0.0f;
        if (envDB > thresholdDB) {
            const float compressedDB = thresholdDB + (envDB - thresholdDB) / ratio;
            targetGainDB = compressedDB - envDB;
        }

        const float grCoeff = targetGainDB < chain->compGainDB ? 0.15f : 0.03f;
        chain->compGainDB += grCoeff * (targetGainDB - chain->compGainDB);
        maxGainReduction = fmaxf(maxGainReduction, -chain->compGainDB);

        x *= db_to_linear(chain->compGainDB + makeupDB + chain->smoothedOutputGainDB);

        if (fabsf(x) > limiterLinear) {
            x = copysignf(limiterLinear, x);
            clipped += 1U;
        }

        const float outAbs = fabsf(x);
        outputPeak = fmaxf(outputPeak, outAbs);
        outputEnergy += x * x;
        samples[frame] = x;
    }

    const float invFrames = 1.0f / (float)frames;
    atomic_store_explicit(&chain->meterInputPeak, inputPeak, memory_order_relaxed);
    atomic_store_explicit(&chain->meterOutputPeak, outputPeak, memory_order_relaxed);
    atomic_store_explicit(&chain->meterInputRMS, sqrtf(inputEnergy * invFrames), memory_order_relaxed);
    atomic_store_explicit(&chain->meterOutputRMS, sqrtf(outputEnergy * invFrames), memory_order_relaxed);
    atomic_store_explicit(&chain->meterGainReductionDB, maxGainReduction, memory_order_relaxed);
    atomic_store_explicit(&chain->meterClippedSamples, clipped, memory_order_relaxed);
}
