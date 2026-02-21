// SPDX-License-Identifier: MIT

#ifndef QUARTET_FFI_H
#define QUARTET_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum QuartetErrorCode
{
    QUARTET_SUCCESS = 0,
    QUARTET_ERR_INVALID_ARGUMENT = 1,
    QUARTET_ERR_IO = 2,
    QUARTET_ERR_NOT_WATERTIGHT = 3,
    QUARTET_ERR_INVALID_DX = 4,
    QUARTET_ERR_BAD_ALLOC = 5,
    QUARTET_ERR_RUNTIME = 6
};

typedef struct QuartetStats
{
    int node_count;
    int tetrahedra_count;
    float worst_element_quality;
} QuartetStats;

typedef struct QuartetResult
{
    QuartetStats stats;
    int error_code;
    const char *error_message;
} QuartetResult;

QuartetResult *quartet_generate_mesh(const char *input_obj_path,
                                     const char *output_tet_path,
                                     float dx,
                                     int optimize_quality,
                                     float feature_angle_threshold);

void quartet_free_result(QuartetResult *result);

#ifdef __cplusplus
}
#endif

#endif // QUARTET_FFI_H
