#include "VirtualMicRingBuffer.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define VM_RING_MAGIC 0x564D5242U

typedef struct VMRingSharedMemory {
    uint32_t magic;
    uint32_t version;
    uint32_t capacityFrames;
    uint32_t channelCount;
    _Atomic(uint32_t) sampleRate;
    _Atomic(uint64_t) writeIndex;
    _Atomic(uint64_t) readIndex;
    _Atomic(uint64_t) frameClock;
    _Atomic(uint32_t) overruns;
    _Atomic(uint32_t) underruns;
    uint8_t reserved[32];
    float samples[];
} VMRingSharedMemory;

struct VMRingHandle {
    int fd;
    size_t mappingSize;
    bool isWriter;
    VMRingSharedMemory* shared;
};

static size_t vm_ring_mapping_size(uint32_t capacityFrames, uint32_t channelCount) {
    return sizeof(VMRingSharedMemory) + ((size_t)capacityFrames * (size_t)channelCount * sizeof(float));
}

bool vm_ring_is_power_of_two(uint32_t value) {
    return value != 0U && (value & (value - 1U)) == 0U;
}

static int vm_ring_validate_shared(const VMRingSharedMemory* shared) {
    if (shared == NULL) {
        return EINVAL;
    }
    if (shared->magic != VM_RING_MAGIC || shared->version != VM_RING_VERSION) {
        return EPROTO;
    }
    if (!vm_ring_is_power_of_two(shared->capacityFrames) || shared->channelCount == 0U) {
        return EINVAL;
    }
    return 0;
}

int vm_ring_create_writer(const char* shmName,
                          uint32_t capacityFrames,
                          uint32_t channels,
                          VMRingHandle** outHandle) {
    if (shmName == NULL || outHandle == NULL || channels == 0U || !vm_ring_is_power_of_two(capacityFrames)) {
        return EINVAL;
    }

    *outHandle = NULL;

    const size_t mappingSize = vm_ring_mapping_size(capacityFrames, channels);
    const int fd = shm_open(shmName, O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        return errno;
    }

    if (ftruncate(fd, (off_t)mappingSize) != 0) {
        const int err = errno;
        close(fd);
        return err;
    }

    void* mapping = mmap(NULL, mappingSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        const int err = errno;
        close(fd);
        return err;
    }

    VMRingSharedMemory* shared = (VMRingSharedMemory*)mapping;
    memset(shared, 0, mappingSize);
    shared->magic = VM_RING_MAGIC;
    shared->version = VM_RING_VERSION;
    shared->capacityFrames = capacityFrames;
    shared->channelCount = channels;
    atomic_store_explicit(&shared->sampleRate, 48000U, memory_order_relaxed);

    VMRingHandle* handle = (VMRingHandle*)calloc(1, sizeof(VMRingHandle));
    if (handle == NULL) {
        munmap(mapping, mappingSize);
        close(fd);
        return ENOMEM;
    }

    handle->fd = fd;
    handle->mappingSize = mappingSize;
    handle->isWriter = true;
    handle->shared = shared;
    *outHandle = handle;

    return 0;
}

int vm_ring_open_reader(const char* shmName, VMRingHandle** outHandle) {
    if (shmName == NULL || outHandle == NULL) {
        return EINVAL;
    }

    *outHandle = NULL;

    const int fd = shm_open(shmName, O_RDWR, 0);
    if (fd < 0) {
        return errno;
    }

    struct stat fileInfo;
    if (fstat(fd, &fileInfo) != 0) {
        const int err = errno;
        close(fd);
        return err;
    }

    if (fileInfo.st_size < (off_t)sizeof(VMRingSharedMemory)) {
        close(fd);
        return EPROTO;
    }

    void* mapping = mmap(NULL, (size_t)fileInfo.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        const int err = errno;
        close(fd);
        return err;
    }

    VMRingSharedMemory* shared = (VMRingSharedMemory*)mapping;
    const int validation = vm_ring_validate_shared(shared);
    if (validation != 0) {
        munmap(mapping, (size_t)fileInfo.st_size);
        close(fd);
        return validation;
    }

    const size_t expected = vm_ring_mapping_size(shared->capacityFrames, shared->channelCount);
    if ((size_t)fileInfo.st_size < expected) {
        munmap(mapping, (size_t)fileInfo.st_size);
        close(fd);
        return EPROTO;
    }

    VMRingHandle* handle = (VMRingHandle*)calloc(1, sizeof(VMRingHandle));
    if (handle == NULL) {
        munmap(mapping, (size_t)fileInfo.st_size);
        close(fd);
        return ENOMEM;
    }

    handle->fd = fd;
    handle->mappingSize = (size_t)fileInfo.st_size;
    handle->isWriter = false;
    handle->shared = shared;
    *outHandle = handle;

    return 0;
}

void vm_ring_close(VMRingHandle* handle) {
    if (handle == NULL) {
        return;
    }

    if (handle->shared != NULL && handle->mappingSize > 0U) {
        munmap(handle->shared, handle->mappingSize);
    }
    if (handle->fd >= 0) {
        close(handle->fd);
    }
    free(handle);
}

int vm_ring_unlink(const char* shmName) {
    if (shmName == NULL) {
        return EINVAL;
    }

    if (shm_unlink(shmName) != 0) {
        return errno;
    }
    return 0;
}

void vm_ring_set_sample_rate(VMRingHandle* handle, uint32_t sampleRate) {
    if (handle == NULL || handle->shared == NULL || sampleRate == 0U) {
        return;
    }
    atomic_store_explicit(&handle->shared->sampleRate, sampleRate, memory_order_relaxed);
}

uint32_t vm_ring_get_sample_rate(const VMRingHandle* handle) {
    if (handle == NULL || handle->shared == NULL) {
        return 0U;
    }
    return atomic_load_explicit(&handle->shared->sampleRate, memory_order_relaxed);
}

uint32_t vm_ring_get_channels(const VMRingHandle* handle) {
    return (handle == NULL || handle->shared == NULL) ? 0U : handle->shared->channelCount;
}

uint32_t vm_ring_get_capacity(const VMRingHandle* handle) {
    return (handle == NULL || handle->shared == NULL) ? 0U : handle->shared->capacityFrames;
}

uint32_t vm_ring_write(VMRingHandle* handle,
                       const float* interleavedSamples,
                       uint32_t frames) {
    if (handle == NULL || handle->shared == NULL || !handle->isWriter || interleavedSamples == NULL || frames == 0U) {
        return 0U;
    }

    VMRingSharedMemory* shared = handle->shared;
    const uint32_t channels = shared->channelCount;
    const uint32_t capacity = shared->capacityFrames;
    const uint64_t readIndex = atomic_load_explicit(&shared->readIndex, memory_order_acquire);
    const uint64_t writeIndex = atomic_load_explicit(&shared->writeIndex, memory_order_relaxed);

    const uint64_t used = writeIndex - readIndex;
    const uint64_t freeFrames = (uint64_t)capacity > used ? ((uint64_t)capacity - used) : 0U;
    const uint32_t framesToWrite = (uint32_t)((uint64_t)frames < freeFrames ? frames : freeFrames);

    if (framesToWrite < frames) {
        atomic_fetch_add_explicit(&shared->overruns, 1U, memory_order_relaxed);
    }

    if (framesToWrite == 0U) {
        return 0U;
    }

    const uint32_t mask = capacity - 1U;
    uint32_t start = (uint32_t)(writeIndex & (uint64_t)mask);
    uint32_t firstFrames = capacity - start;
    if (firstFrames > framesToWrite) {
        firstFrames = framesToWrite;
    }

    memcpy(shared->samples + ((size_t)start * channels),
           interleavedSamples,
           (size_t)firstFrames * channels * sizeof(float));

    const uint32_t remaining = framesToWrite - firstFrames;
    if (remaining > 0U) {
        memcpy(shared->samples,
               interleavedSamples + ((size_t)firstFrames * channels),
               (size_t)remaining * channels * sizeof(float));
    }

    atomic_store_explicit(&shared->writeIndex, writeIndex + framesToWrite, memory_order_release);
    atomic_fetch_add_explicit(&shared->frameClock, framesToWrite, memory_order_relaxed);
    return framesToWrite;
}

uint32_t vm_ring_read(VMRingHandle* handle,
                      float* interleavedSamplesOut,
                      uint32_t frames) {
    if (handle == NULL || handle->shared == NULL || interleavedSamplesOut == NULL || frames == 0U) {
        return 0U;
    }

    VMRingSharedMemory* shared = handle->shared;
    const uint32_t channels = shared->channelCount;
    const uint32_t capacity = shared->capacityFrames;
    const uint64_t writeIndex = atomic_load_explicit(&shared->writeIndex, memory_order_acquire);
    const uint64_t readIndex = atomic_load_explicit(&shared->readIndex, memory_order_relaxed);

    const uint64_t available = writeIndex - readIndex;
    const uint32_t framesToRead = (uint32_t)((uint64_t)frames < available ? frames : available);

    if (framesToRead < frames) {
        atomic_fetch_add_explicit(&shared->underruns, 1U, memory_order_relaxed);
    }

    if (framesToRead > 0U) {
        const uint32_t mask = capacity - 1U;
        uint32_t start = (uint32_t)(readIndex & (uint64_t)mask);
        uint32_t firstFrames = capacity - start;
        if (firstFrames > framesToRead) {
            firstFrames = framesToRead;
        }

        memcpy(interleavedSamplesOut,
               shared->samples + ((size_t)start * channels),
               (size_t)firstFrames * channels * sizeof(float));

        const uint32_t remaining = framesToRead - firstFrames;
        if (remaining > 0U) {
            memcpy(interleavedSamplesOut + ((size_t)firstFrames * channels),
                   shared->samples,
                   (size_t)remaining * channels * sizeof(float));
        }

        atomic_store_explicit(&shared->readIndex, readIndex + framesToRead, memory_order_release);
    }

    return framesToRead;
}

void vm_ring_get_stats(const VMRingHandle* handle, VMRealtimeStats* outStats) {
    if (handle == NULL || handle->shared == NULL || outStats == NULL) {
        return;
    }

    VMRingSharedMemory* shared = handle->shared;
    outStats->overruns = atomic_load_explicit(&shared->overruns, memory_order_relaxed);
    outStats->underruns = atomic_load_explicit(&shared->underruns, memory_order_relaxed);
    outStats->frameClock = atomic_load_explicit(&shared->frameClock, memory_order_relaxed);
    outStats->writeIndex = atomic_load_explicit(&shared->writeIndex, memory_order_relaxed);
    outStats->readIndex = atomic_load_explicit(&shared->readIndex, memory_order_relaxed);
}
