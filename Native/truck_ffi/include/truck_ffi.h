// SPDX-License-Identifier: MIT

#ifndef TRUCK_FFI_H
#define TRUCK_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum TruckErrorCode {
  TruckErrorCode_Ok = 0,
  TruckErrorCode_ErrInvalidArgument = 1,
  TruckErrorCode_ErrIo = 2,
  TruckErrorCode_ErrStepUnsupportedSchema = 3,
  TruckErrorCode_ErrTessellationFailed = 4,
  TruckErrorCode_ErrPanic = 5,
} TruckErrorCode;

typedef struct TruckMeshResult {
  float *vertices;
  size_t vertex_count;
  size_t vertex_capacity;
  uint32_t *indices;
  size_t index_count;
  size_t index_capacity;
  double volume;
  double surface_area;
  double bbox_min_x;
  double bbox_min_y;
  double bbox_min_z;
  double bbox_max_x;
  double bbox_max_y;
  double bbox_max_z;
  uint8_t watertight;
  int32_t error_code;
  char *error_message;
} TruckMeshResult;

TruckMeshResult *truck_load_step(const char *step_path, double linear_deflection);
void truck_free_result(TruckMeshResult *result_ptr);

#ifdef __cplusplus
}
#endif

#endif // TRUCK_FFI_H
