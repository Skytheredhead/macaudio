#ifndef DSP_CHAIN_H
#define DSP_CHAIN_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DSPChain DSPChain;

typedef struct DSPChainParameters {
    float inputGainDB;
    float hpfHz;
    float lowGainDB;
    float midGainDB;
    float highGainDB;
    float compressorThresholdDB;
    float compressorRatio;
    float compressorAttackMs;
    float compressorReleaseMs;
    float makeupGainDB;
    float limiterCeilingDB;
    float outputGainDB;
    bool denoiseEnabled;
    float denoiseStrength;
    bool gateEnabled;
    float gateThresholdDB;
    bool deEsserEnabled;
    float deEsserAmount;
} DSPChainParameters;

typedef struct DSPChainMeters {
    float inputPeak;
    float inputRMS;
    float outputPeak;
    float outputRMS;
    float gainReductionDB;
    uint32_t clippedSamples;
} DSPChainMeters;

DSPChain* dsp_chain_create(double sampleRate, uint32_t channels);
void dsp_chain_destroy(DSPChain* chain);
void dsp_chain_reset(DSPChain* chain);

void dsp_chain_set_parameters(DSPChain* chain, DSPChainParameters parameters);
DSPChainParameters dsp_chain_get_parameters(const DSPChain* chain);

void dsp_chain_process_mono(DSPChain* chain, float* samples, uint32_t frames);
void dsp_chain_copy_meters(const DSPChain* chain, DSPChainMeters* outMeters);

#ifdef __cplusplus
}
#endif

#endif
