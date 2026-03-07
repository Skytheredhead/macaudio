#ifndef REALTIME_PARAMETER_STORE_H
#define REALTIME_PARAMETER_STORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RTParameterStore RTParameterStore;

RTParameterStore* rt_parameters_create(uint32_t capacity);
void rt_parameters_destroy(RTParameterStore* store);

uint32_t rt_parameters_capacity(const RTParameterStore* store);
void rt_parameters_set(RTParameterStore* store, uint32_t index, float value);
float rt_parameters_get(const RTParameterStore* store, uint32_t index);
void rt_parameters_snapshot(const RTParameterStore* store, float* valuesOut, uint32_t maxCount);

#ifdef __cplusplus
}
#endif

#endif
