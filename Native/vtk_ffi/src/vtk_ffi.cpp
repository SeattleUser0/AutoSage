// SPDX-License-Identifier: MIT

#include "vtk_ffi.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstring>
#include <exception>
#include <filesystem>
#include <string>
#include <vector>

#include <vtkActor.h>
#include <vtkCamera.h>
#include <vtkDataArray.h>
#include <vtkImageData.h>
#include <vtkMath.h>
#include <vtkNew.h>
#include <vtkOBJReader.h>
#include <vtkPNGWriter.h>
#include <vtkPointData.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkPolyDataNormals.h>
#include <vtkProperty.h>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkSTLReader.h>
#include <vtkSmartPointer.h>
#include <vtkTIFFWriter.h>
#include <vtkUnsignedCharArray.h>
#include <vtkWindowToImageFilter.h>

#if defined(__linux__)
#if __has_include(<vtkEGLRenderWindow.h>)
#include <vtkEGLRenderWindow.h>
#endif
#if __has_include(<vtkOSOpenGLRenderWindow.h>)
#include <vtkOSOpenGLRenderWindow.h>
#endif
#endif

namespace
{

constexpr int kMinDimension = 16;
constexpr int kMaxDimension = 8192;

struct ViewPaths
{
    std::string color;
    std::string depth;
    std::string normal;
};

char *duplicate_c_string(const std::string &text)
{
    const std::size_t size = text.size();
    char *copy = new char[size + 1];
    std::memcpy(copy, text.c_str(), size + 1);
    return copy;
}

VtkRenderOutput *make_error_output(int code, const std::string &message)
{
    auto *output = new VtkRenderOutput{};
    output->views = nullptr;
    output->num_views = 0;
    for (int i = 0; i < 9; ++i)
    {
        output->camera_intrinsics[i] = 0.0f;
    }
    output->error_code = code;
    output->error_message = message.empty() ? nullptr : duplicate_c_string(message);
    return output;
}

std::string to_lower_ascii(std::string value)
{
    for (char &ch : value)
    {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
}

std::string sanitize_view_token(const std::string &value)
{
    std::string token;
    token.reserve(value.size());
    for (char ch : value)
    {
        if (std::isalnum(static_cast<unsigned char>(ch)))
        {
            token.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(ch))));
        }
        else if (ch == '_' || ch == '-')
        {
            token.push_back(ch);
        }
    }
    if (token.empty())
    {
        return "view";
    }
    return token;
}

vtkSmartPointer<vtkPolyData> load_mesh(const std::filesystem::path &mesh_path, std::string &error)
{
    const std::string extension = to_lower_ascii(mesh_path.extension().string());
    vtkSmartPointer<vtkPolyData> data;

    if (extension == ".obj")
    {
        vtkNew<vtkOBJReader> reader;
        reader->SetFileName(mesh_path.string().c_str());
        reader->Update();
        data = reader->GetOutput();
    }
    else if (extension == ".stl")
    {
        vtkNew<vtkSTLReader> reader;
        reader->SetFileName(mesh_path.string().c_str());
        reader->Update();
        data = reader->GetOutput();
    }
    else
    {
        error = "unsupported mesh extension; expected .obj or .stl";
        return nullptr;
    }

    if (!data || data->GetNumberOfPoints() <= 0 || data->GetNumberOfCells() <= 0)
    {
        error = "loaded mesh is empty or invalid";
        return nullptr;
    }

    return data;
}

bool set_view_pose(vtkCamera *camera,
                   const std::string &view,
                   const std::array<double, 3> &center,
                   double distance,
                   std::string &error)
{
    std::array<double, 3> direction{1.0, 1.0, 1.0};
    std::array<double, 3> up{0.0, 1.0, 0.0};

    if (view == "isometric" || view == "iso")
    {
        direction = {1.0, 1.0, 1.0};
        up = {0.0, 1.0, 0.0};
    }
    else if (view == "front")
    {
        direction = {0.0, 0.0, 1.0};
    }
    else if (view == "back")
    {
        direction = {0.0, 0.0, -1.0};
    }
    else if (view == "left")
    {
        direction = {-1.0, 0.0, 0.0};
    }
    else if (view == "right")
    {
        direction = {1.0, 0.0, 0.0};
    }
    else if (view == "top")
    {
        direction = {0.0, 1.0, 0.0};
        up = {0.0, 0.0, -1.0};
    }
    else if (view == "bottom")
    {
        direction = {0.0, -1.0, 0.0};
        up = {0.0, 0.0, 1.0};
    }
    else
    {
        error = "unsupported view: " + view;
        return false;
    }

    const double magnitude = std::sqrt(direction[0] * direction[0] +
                                       direction[1] * direction[1] +
                                       direction[2] * direction[2]);
    if (magnitude <= 0.0)
    {
        error = "invalid camera direction for view: " + view;
        return false;
    }

    direction[0] /= magnitude;
    direction[1] /= magnitude;
    direction[2] /= magnitude;

    camera->SetFocalPoint(center[0], center[1], center[2]);
    camera->SetPosition(center[0] + direction[0] * distance,
                        center[1] + direction[1] * distance,
                        center[2] + direction[2] * distance);
    camera->SetViewUp(up[0], up[1], up[2]);
    camera->OrthogonalizeViewUp();
    return true;
}

void compute_camera_intrinsics(vtkCamera *camera, int width, int height, float *out_intrinsics)
{
    const double view_angle_rad = vtkMath::RadiansFromDegrees(camera->GetViewAngle());
    const double fy = static_cast<double>(height) / (2.0 * std::tan(view_angle_rad / 2.0));
    const double fx = fy;
    const double cx = (static_cast<double>(width) - 1.0) * 0.5;
    const double cy = (static_cast<double>(height) - 1.0) * 0.5;

    out_intrinsics[0] = static_cast<float>(fx);
    out_intrinsics[1] = 0.0f;
    out_intrinsics[2] = static_cast<float>(cx);
    out_intrinsics[3] = 0.0f;
    out_intrinsics[4] = static_cast<float>(fy);
    out_intrinsics[5] = static_cast<float>(cy);
    out_intrinsics[6] = 0.0f;
    out_intrinsics[7] = 0.0f;
    out_intrinsics[8] = 1.0f;
}

bool write_rgb_capture(vtkRenderWindow *render_window, const std::filesystem::path &path, std::string &error)
{
    vtkNew<vtkWindowToImageFilter> capture;
    capture->SetInput(render_window);
    capture->ReadFrontBufferOff();
    capture->SetInputBufferTypeToRGB();
    capture->Update();

    vtkNew<vtkPNGWriter> writer;
    writer->SetFileName(path.string().c_str());
    writer->SetInputConnection(capture->GetOutputPort());
    writer->Write();

    if (!std::filesystem::exists(path))
    {
        error = "failed to write RGB buffer to " + path.string();
        return false;
    }
    return true;
}

bool write_depth_capture(vtkRenderer *renderer,
                         vtkRenderWindow *render_window,
                         int width,
                         int height,
                         const std::filesystem::path &path,
                         std::string &error)
{
    vtkNew<vtkWindowToImageFilter> depth_capture;
    depth_capture->SetInput(render_window);
    depth_capture->ReadFrontBufferOff();
    depth_capture->SetInputBufferTypeToZBuffer();
    depth_capture->Update();

    vtkImageData *z_image = depth_capture->GetOutput();
    if (!z_image)
    {
        error = "failed to capture Z-buffer image";
        return false;
    }

    int dims[3] = {0, 0, 0};
    z_image->GetDimensions(dims);
    if (dims[0] != width || dims[1] != height)
    {
        error = "unexpected Z-buffer dimensions";
        return false;
    }

    double clip[2] = {0.0, 0.0};
    renderer->GetActiveCamera()->GetClippingRange(clip);
    const double near_clip = std::max(1.0e-6, clip[0]);
    const double far_clip = std::max(near_clip + 1.0e-6, clip[1]);

    vtkNew<vtkImageData> linear_depth;
    linear_depth->SetDimensions(width, height, 1);
    linear_depth->AllocateScalars(VTK_FLOAT, 1);

    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            const double z_buffer = z_image->GetScalarComponentAsDouble(x, y, 0, 0);
            const double z_ndc = (2.0 * z_buffer) - 1.0;
            const double denom = far_clip + near_clip - z_ndc * (far_clip - near_clip);
            double linear_value = (2.0 * near_clip * far_clip) / denom;
            if (!std::isfinite(linear_value))
            {
                linear_value = far_clip;
            }
            linear_depth->SetScalarComponentFromFloat(x, y, 0, 0, static_cast<float>(linear_value));
        }
    }

    vtkNew<vtkTIFFWriter> writer;
    writer->SetFileName(path.string().c_str());
    writer->SetInputData(linear_depth);
    writer->Write();

    if (!std::filesystem::exists(path))
    {
        error = "failed to write depth buffer to " + path.string();
        return false;
    }
    return true;
}

vtkSmartPointer<vtkPolyData> make_normal_colored_polydata(vtkPolyData *mesh, std::string &error)
{
    vtkNew<vtkPolyDataNormals> normals_filter;
    normals_filter->SetInputData(mesh);
    normals_filter->ComputePointNormalsOn();
    normals_filter->ComputeCellNormalsOff();
    normals_filter->SplittingOff();
    normals_filter->ConsistencyOn();
    normals_filter->AutoOrientNormalsOn();
    normals_filter->Update();

    vtkSmartPointer<vtkPolyData> normals_poly = normals_filter->GetOutput();
    if (!normals_poly || normals_poly->GetNumberOfPoints() <= 0)
    {
        error = "failed to compute mesh normals";
        return nullptr;
    }

    vtkDataArray *normals = normals_poly->GetPointData()->GetNormals();
    if (!normals)
    {
        error = "mesh normals are unavailable";
        return nullptr;
    }

    vtkNew<vtkUnsignedCharArray> normal_colors;
    normal_colors->SetName("NormalColors");
    normal_colors->SetNumberOfComponents(3);
    normal_colors->SetNumberOfTuples(normals->GetNumberOfTuples());

    double tuple[3] = {0.0, 0.0, 0.0};
    for (vtkIdType i = 0; i < normals->GetNumberOfTuples(); ++i)
    {
        normals->GetTuple(i, tuple);
        unsigned char rgb[3] = {0, 0, 0};
        for (int c = 0; c < 3; ++c)
        {
            const double mapped = std::clamp((tuple[c] * 0.5 + 0.5) * 255.0, 0.0, 255.0);
            rgb[c] = static_cast<unsigned char>(mapped);
        }
        normal_colors->SetTypedTuple(i, rgb);
    }

    normals_poly->GetPointData()->SetScalars(normal_colors);
    return normals_poly;
}

VtkRenderOutput *render_pack_impl(const char *input_mesh_path,
                                  const char *output_directory,
                                  int width,
                                  int height,
                                  const char *const *views,
                                  int num_views,
                                  int output_color,
                                  int output_depth,
                                  int output_normal)
{
    if (input_mesh_path == nullptr || input_mesh_path[0] == '\0' ||
        output_directory == nullptr || output_directory[0] == '\0')
    {
        return make_error_output(VTK_ERR_INVALID_ARGUMENT, "input_mesh_path and output_directory are required");
    }
    if (width < kMinDimension || width > kMaxDimension ||
        height < kMinDimension || height > kMaxDimension)
    {
        return make_error_output(VTK_ERR_INVALID_ARGUMENT, "width and height must be between 16 and 8192");
    }
    if (num_views <= 0 || views == nullptr)
    {
        return make_error_output(VTK_ERR_INVALID_ARGUMENT, "at least one view must be specified");
    }
    if (output_color == 0 && output_depth == 0 && output_normal == 0)
    {
        return make_error_output(VTK_ERR_INVALID_ARGUMENT, "at least one output buffer must be enabled");
    }

    std::vector<std::string> requested_views;
    requested_views.reserve(static_cast<std::size_t>(num_views));
    for (int i = 0; i < num_views; ++i)
    {
        if (views[i] == nullptr || views[i][0] == '\0')
        {
            return make_error_output(VTK_ERR_INVALID_ARGUMENT, "view names must be non-empty strings");
        }
        requested_views.push_back(to_lower_ascii(std::string(views[i])));
    }

    const std::filesystem::path mesh_path(input_mesh_path);
    const std::filesystem::path output_dir(output_directory);
    if (!std::filesystem::exists(mesh_path))
    {
        return make_error_output(VTK_ERR_IO, "input mesh path does not exist");
    }

    try
    {
        std::filesystem::create_directories(output_dir);
    }
    catch (const std::exception &error)
    {
        return make_error_output(VTK_ERR_IO, std::string("failed to create output directory: ") + error.what());
    }

    std::string load_error;
    vtkSmartPointer<vtkPolyData> mesh = load_mesh(mesh_path, load_error);
    if (!mesh)
    {
        return make_error_output(VTK_ERR_MESH_LOAD_FAILED, load_error);
    }

    vtkNew<vtkRenderWindow> render_window;
#ifdef __APPLE__
    render_window->SetOffScreenRendering(1);
#elif defined(__linux__)
    render_window->SetWindowName("AutoSage_Headless_Context");
    render_window->SetOffScreenRendering(1);
#else
#error "Unsupported platform for VTK rendering"
#endif
    if (render_window->GetOffScreenRendering() != 1)
    {
        return make_error_output(VTK_ERR_HEADLESS_CONTEXT_FAILED, "VTK off-screen rendering is unavailable");
    }
    render_window->SetSize(width, height);

    vtkNew<vtkRenderer> renderer;
    renderer->SetBackground(0.0, 0.0, 0.0);
    render_window->AddRenderer(renderer);

    vtkNew<vtkPolyDataMapper> color_mapper;
    color_mapper->SetInputData(mesh);
    color_mapper->ScalarVisibilityOff();

    vtkNew<vtkActor> color_actor;
    color_actor->SetMapper(color_mapper);
    color_actor->GetProperty()->SetColor(0.85, 0.85, 0.9);
    color_actor->GetProperty()->SetInterpolationToPhong();
    renderer->AddActor(color_actor);

    std::string normals_error;
    vtkSmartPointer<vtkPolyData> normal_poly = make_normal_colored_polydata(mesh, normals_error);
    if (!normal_poly)
    {
        return make_error_output(VTK_ERR_BUFFER_EXTRACTION_FAILED, normals_error);
    }

    vtkNew<vtkPolyDataMapper> normal_mapper;
    normal_mapper->SetInputData(normal_poly);
    normal_mapper->ScalarVisibilityOn();
    normal_mapper->SetScalarModeToUsePointData();
    normal_mapper->SetColorModeToDirectScalars();
    normal_mapper->SelectColorArray("NormalColors");

    vtkNew<vtkActor> normal_actor;
    normal_actor->SetMapper(normal_mapper);
    normal_actor->GetProperty()->LightingOff();
    normal_actor->SetVisibility(0);
    renderer->AddActor(normal_actor);

    // Validate that an off-screen context can be created before processing views.
    try
    {
        render_window->Render();
    }
    catch (const std::exception &error)
    {
        return make_error_output(VTK_ERR_HEADLESS_CONTEXT_FAILED, std::string("headless context initialization failed: ") + error.what());
    }
    catch (...)
    {
        return make_error_output(VTK_ERR_HEADLESS_CONTEXT_FAILED, "headless context initialization failed with unknown exception");
    }

    double bounds[6] = {0, 0, 0, 0, 0, 0};
    mesh->GetBounds(bounds);
    const std::array<double, 3> center = {
        (bounds[0] + bounds[1]) * 0.5,
        (bounds[2] + bounds[3]) * 0.5,
        (bounds[4] + bounds[5]) * 0.5};
    const double span_x = bounds[1] - bounds[0];
    const double span_y = bounds[3] - bounds[2];
    const double span_z = bounds[5] - bounds[4];
    const double diagonal = std::max(1.0e-3, std::sqrt(span_x * span_x + span_y * span_y + span_z * span_z));
    const double camera_distance = diagonal * 2.0;

    std::vector<ViewPaths> output_paths(static_cast<std::size_t>(num_views));
    std::array<float, 9> intrinsics = {0, 0, 0, 0, 0, 0, 0, 0, 1};

    vtkCamera *camera = renderer->GetActiveCamera();
    for (int index = 0; index < num_views; ++index)
    {
        const std::string &view_name = requested_views[static_cast<std::size_t>(index)];
        std::string pose_error;
        if (!set_view_pose(camera, view_name, center, camera_distance, pose_error))
        {
            return make_error_output(VTK_ERR_INVALID_ARGUMENT, pose_error);
        }
        renderer->ResetCameraClippingRange(bounds);

        try
        {
            render_window->Render();
        }
        catch (const std::exception &error)
        {
            return make_error_output(VTK_ERR_HEADLESS_CONTEXT_FAILED, std::string("headless render failed: ") + error.what());
        }
        catch (...)
        {
            return make_error_output(VTK_ERR_HEADLESS_CONTEXT_FAILED, "headless render failed with unknown exception");
        }

        compute_camera_intrinsics(camera, width, height, intrinsics.data());

        const std::string token = sanitize_view_token(view_name);
        const std::string prefix = std::to_string(index) + "_" + token;
        ViewPaths &paths = output_paths[static_cast<std::size_t>(index)];
        std::string buffer_error;

        if (output_color != 0)
        {
            std::filesystem::path color_path = output_dir / (prefix + "_color.png");
            color_actor->SetVisibility(1);
            normal_actor->SetVisibility(0);
            if (!write_rgb_capture(render_window, color_path, buffer_error))
            {
                return make_error_output(VTK_ERR_BUFFER_EXTRACTION_FAILED, buffer_error);
            }
            paths.color = std::filesystem::absolute(color_path).string();
        }

        if (output_depth != 0)
        {
            std::filesystem::path depth_path = output_dir / (prefix + "_depth.tiff");
            color_actor->SetVisibility(1);
            normal_actor->SetVisibility(0);
            if (!write_depth_capture(renderer, render_window, width, height, depth_path, buffer_error))
            {
                return make_error_output(VTK_ERR_BUFFER_EXTRACTION_FAILED, buffer_error);
            }
            paths.depth = std::filesystem::absolute(depth_path).string();
        }

        if (output_normal != 0)
        {
            std::filesystem::path normal_path = output_dir / (prefix + "_normal.png");
            color_actor->SetVisibility(0);
            normal_actor->SetVisibility(1);
            try
            {
                render_window->Render();
            }
            catch (const std::exception &error)
            {
                return make_error_output(VTK_ERR_RENDER_FAILED, std::string("normal-buffer render failed: ") + error.what());
            }
            catch (...)
            {
                return make_error_output(VTK_ERR_RENDER_FAILED, "normal-buffer render failed with unknown exception");
            }
            if (!write_rgb_capture(render_window, normal_path, buffer_error))
            {
                return make_error_output(VTK_ERR_BUFFER_EXTRACTION_FAILED, buffer_error);
            }
            paths.normal = std::filesystem::absolute(normal_path).string();
            color_actor->SetVisibility(1);
            normal_actor->SetVisibility(0);
        }
    }

    auto *result = new VtkRenderOutput{};
    result->num_views = num_views;
    result->views = new VtkViewResult[static_cast<std::size_t>(num_views)];
    for (int i = 0; i < 9; ++i)
    {
        result->camera_intrinsics[i] = intrinsics[static_cast<std::size_t>(i)];
    }
    result->error_code = VTK_SUCCESS;
    result->error_message = nullptr;

    for (int index = 0; index < num_views; ++index)
    {
        const ViewPaths &paths = output_paths[static_cast<std::size_t>(index)];
        result->views[index].color_path = paths.color.empty() ? nullptr : duplicate_c_string(paths.color);
        result->views[index].depth_path = paths.depth.empty() ? nullptr : duplicate_c_string(paths.depth);
        result->views[index].normal_path = paths.normal.empty() ? nullptr : duplicate_c_string(paths.normal);
    }

    return result;
}

} // namespace

extern "C" VtkRenderOutput *vtk_render_pack(const char *input_mesh_path,
                                             const char *output_directory,
                                             int width,
                                             int height,
                                             const char *const *views,
                                             int num_views,
                                             int output_color,
                                             int output_depth,
                                             int output_normal)
{
    try
    {
        return render_pack_impl(input_mesh_path,
                                output_directory,
                                width,
                                height,
                                views,
                                num_views,
                                output_color,
                                output_depth,
                                output_normal);
    }
    catch (const std::exception &error)
    {
        return make_error_output(VTK_ERR_RUNTIME, std::string("unexpected VTK failure: ") + error.what());
    }
    catch (...)
    {
        return make_error_output(VTK_ERR_RUNTIME, "unexpected non-standard exception in vtk_render_pack");
    }
}

extern "C" void vtk_free_result(VtkRenderOutput *result)
{
    if (result == nullptr)
    {
        return;
    }

    if (result->views != nullptr && result->num_views > 0)
    {
        for (int i = 0; i < result->num_views; ++i)
        {
            delete[] const_cast<char *>(result->views[i].color_path);
            delete[] const_cast<char *>(result->views[i].depth_path);
            delete[] const_cast<char *>(result->views[i].normal_path);
        }
        delete[] result->views;
    }

    delete[] const_cast<char *>(result->error_message);
    delete result;
}
