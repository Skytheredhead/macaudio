#ifndef VIRTUAL_MIC_RING_BUFFER_H
#define VIRTUAL_MIC_RING_BUFFER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VM_RING_VERSION 1U
#define VM_RING_DEFAULT_NAME "/macaudio-vm"

typedef struct VMRingHandle VMRingHandle;

typedef struct VMRealtimeStats {
    uint32_t overruns;
    uint32_t underruns;
    uint64_t frameClock;
    uint64_t writeIndex;
    uint64_t readIndex;
} VMRealtimeStats;

bool vm_ring_is_power_of_two(uint32_t value);

int vm_ring_create_writer(const char* shmName,
                          uint32_t capacityFrames,
                          uint32_t channels,
                          VMRingHandle** outHandle);

int vm_ring_open_reader(const char* shmName, VMRingHandle** outHandle);

void vm_ring_close(VMRingHandle* handle);

int vm_ring_unlink(const char* shmName);

void vm_ring_set_sample_rate(VMRingHandle* handle, uint32_t sampleRate);
uint32_t vm_ring_get_sample_rate(const VMRingHandle* handle);
uint32_t vm_ring_get_channels(const VMRingHandle* handle);
uint32_t vm_ring_get_capacity(const VMRingHandle* handle);

uint32_t vm_ring_write(VMRingHandle* handle,
                       const float* interleavedSamples,
                       uint32_t frames);

uint32_t vm_ring_read(VMRingHandle* handle,
                      float* interleavedSamplesOut,
                      uint32_t frames);

void vm_ring_get_stats(const VMRingHandle* handle, VMRealtimeStats* outStats);

#ifdef __cplusplus
}
#endif

#endif
