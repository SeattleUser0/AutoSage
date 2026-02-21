// SPDX-License-Identifier: MIT

#ifndef VTK_FFI_H
#define VTK_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

enum VtkErrorCode
{
    VTK_SUCCESS = 0,
    VTK_ERR_INVALID_ARGUMENT = 1,
    VTK_ERR_HEADLESS_CONTEXT_FAILED = 2,
    VTK_ERR_MESH_LOAD_FAILED = 3,
    VTK_ERR_RENDER_FAILED = 4,
    VTK_ERR_BUFFER_EXTRACTION_FAILED = 5,
    VTK_ERR_IO = 6,
    VTK_ERR_RUNTIME = 7
};

typedef struct VtkViewResult
{
    const char *color_path;
    const char *depth_path;
    const char *normal_path;
} VtkViewResult;

typedef struct VtkRenderOutput
{
    VtkViewResult *views;
    int num_views;
    float camera_intrinsics[9];
    int error_code;
    const char *error_message;
} VtkRenderOutput;

VtkRenderOutput *vtk_render_pack(const char *input_mesh_path,
                                 const char *output_directory,
                                 int width,
                                 int height,
                                 const char *const *views,
                                 int num_views,
                                 int output_color,
                                 int output_depth,
                                 int output_normal);

void vtk_free_result(VtkRenderOutput *result);

#ifdef __cplusplus
}
#endif

#endif // VTK_FFI_H
