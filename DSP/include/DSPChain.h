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
    bool eqEnabled;
    bool highPassEnabled;
    float highPassHz;
    bool band1Enabled;
    float band1FrequencyHz;
    float band1GainDB;
    float band1Q;
    bool band2Enabled;
    float band2FrequencyHz;
    float band2GainDB;
    float band2Q;
    bool band3Enabled;
    float band3FrequencyHz;
    float band3GainDB;
    float band3Q;
    bool compressorEnabled;
    float compressorThresholdDB;
    float compressorRatio;
    float compressorAttackMs;
    float compressorReleaseMs;
    float makeupGainDB;
    bool limiterEnabled;
    float limiterCeilingDB;
    float outputGainDB;
    bool denoiseEnabled;
    float denoiseStrength;
    bool gateEnabled;
    float gateThresholdDB;
    float gateAttackMs;
    float gateReleaseMs;
} DSPChainParameters;

typedef struct DSPChainMeters {
    float inputPeak;
    float inputRMS;
    float outputPeak;
    float outputRMS;
    float compressorInputRMS;
    float compressorOutputRMS;
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
