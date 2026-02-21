// SPDX-License-Identifier: MIT

#ifndef OPEN3D_FFI_H
#define OPEN3D_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

enum O3DErrorCode
{
    O3D_SUCCESS = 0,
    O3D_ERR_INVALID_ARGUMENT = 1,
    O3D_ERR_MESH_LOAD_FAILED = 2,
    O3D_ERR_POINTCLOUD_GENERATION_FAILED = 3,
    O3D_ERR_PRIMITIVE_FIT_TIMEOUT = 4,
    O3D_ERR_RUNTIME = 5
};

typedef struct O3DPrimitive
{
    const char *type;
    float parameters[10];
    float inlier_ratio;
} O3DPrimitive;

typedef struct O3DResult
{
    O3DPrimitive *primitives;
    int num_primitives;
    float unassigned_points_ratio;
    int error_code;
    const char *error_message;
} O3DResult;

O3DResult *open3d_extract_primitives(const char *input_mesh_path,
                                     float distance_threshold,
                                     int ransac_n,
                                     int num_iterations);

void open3d_free_result(O3DResult *result);

#ifdef __cplusplus
}
#endif

#endif // OPEN3D_FFI_H
