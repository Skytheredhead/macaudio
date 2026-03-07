#include "RealtimeParameterStore.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct RTParameterStore {
    uint32_t capacity;
    _Atomic(float)* values;
};

RTParameterStore* rt_parameters_create(uint32_t capacity) {
    if (capacity == 0U) {
        return NULL;
    }

    RTParameterStore* store = (RTParameterStore*)calloc(1, sizeof(RTParameterStore));
    if (store == NULL) {
        return NULL;
    }

    store->values = (_Atomic(float)*)calloc(capacity, sizeof(_Atomic(float)));
    if (store->values == NULL) {
        free(store);
        return NULL;
    }

    store->capacity = capacity;
    return store;
}

void rt_parameters_destroy(RTParameterStore* store) {
    if (store == NULL) {
        return;
    }
    free(store->values);
    free(store);
}

uint32_t rt_parameters_capacity(const RTParameterStore* store) {
    return store == NULL ? 0U : store->capacity;
}

void rt_parameters_set(RTParameterStore* store, uint32_t index, float value) {
    if (store == NULL || index >= store->capacity) {
        return;
    }
    atomic_store_explicit(&store->values[index], value, memory_order_relaxed);
}

float rt_parameters_get(const RTParameterStore* store, uint32_t index) {
    if (store == NULL || index >= store->capacity) {
        return 0.0f;
    }
    return atomic_load_explicit(&store->values[index], memory_order_relaxed);
}

void rt_parameters_snapshot(const RTParameterStore* store, float* valuesOut, uint32_t maxCount) {
    if (store == NULL || valuesOut == NULL || maxCount == 0U) {
        return;
    }

    const uint32_t count = store->capacity < maxCount ? store->capacity : maxCount;
    for (uint32_t i = 0; i < count; ++i) {
        valuesOut[i] = atomic_load_explicit(&store->values[i], memory_order_relaxed);
    }
    if (count < maxCount) {
        memset(valuesOut + count, 0, (size_t)(maxCount - count) * sizeof(float));
    }
}
