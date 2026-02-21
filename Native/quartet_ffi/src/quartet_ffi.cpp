// SPDX-License-Identifier: MIT

#include "quartet_ffi.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <exception>
#include <filesystem>
#include <limits>
#include <new>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "feature.h"
#include "make_signed_distance.h"
#include "make_tet_mesh.h"
#include "read_obj.h"
#include "sdf.h"
#include "tet_mesh.h"
#include "tet_quality.h"
#include "trimesh.h"
#include "vec.h"

namespace
{

constexpr int kMinSurfaceTriangles = 4;
constexpr int kMinSurfaceVertices = 4;
constexpr float kMinBBoxDiagonal = 1.0e-6f;
constexpr float kMinimumAbsoluteDx = 1.0e-6f;
constexpr float kRelativeMinDxFactor = 1.0f / 2000.0f;
constexpr float kRelativeMaxDxFactor = 2.0f;
constexpr int kMaxGridAxisCells = 2048;
constexpr long long kMaxGridCellCount = 512LL * 512LL * 512LL;

struct EdgeKey
{
    int a;
    int b;

    bool operator==(const EdgeKey &other) const
    {
        return a == other.a && b == other.b;
    }
};

struct EdgeKeyHash
{
    std::size_t operator()(const EdgeKey &edge) const noexcept
    {
        const std::size_t h1 = static_cast<std::size_t>(edge.a) * 73856093ULL;
        const std::size_t h2 = static_cast<std::size_t>(edge.b) * 19349663ULL;
        return h1 ^ h2;
    }
};

char *duplicate_c_string(const std::string &text)
{
    const std::size_t size = text.size();
    char *copy = new char[size + 1];
    std::memcpy(copy, text.c_str(), size + 1);
    return copy;
}

QuartetResult *make_result(const QuartetStats &stats, int code, const std::string &message)
{
    auto *result = new QuartetResult{};
    result->stats = stats;
    result->error_code = code;
    result->error_message = message.empty() ? nullptr : duplicate_c_string(message);
    return result;
}

bool is_non_empty_path(const char *value)
{
    return value != nullptr && value[0] != '\0';
}

bool mesh_has_valid_indices(const std::vector<Vec3f> &vertices, const std::vector<Vec3i> &triangles)
{
    const int max_index = static_cast<int>(vertices.size());
    for (const Vec3i &triangle : triangles)
    {
        const int i0 = triangle[0];
        const int i1 = triangle[1];
        const int i2 = triangle[2];
        if (i0 < 0 || i1 < 0 || i2 < 0)
        {
            return false;
        }
        if (i0 >= max_index || i1 >= max_index || i2 >= max_index)
        {
            return false;
        }
        if (i0 == i1 || i1 == i2 || i0 == i2)
        {
            return false;
        }
    }
    return true;
}

void add_undirected_edge(std::unordered_map<EdgeKey, int, EdgeKeyHash> &edge_counts, int u, int v)
{
    const EdgeKey edge = (u < v) ? EdgeKey{u, v} : EdgeKey{v, u};
    auto iter = edge_counts.find(edge);
    if (iter == edge_counts.end())
    {
        edge_counts.emplace(edge, 1);
        return;
    }
    ++(iter->second);
}

bool is_watertight_manifold(const std::vector<Vec3i> &triangles)
{
    std::unordered_map<EdgeKey, int, EdgeKeyHash> edge_counts;
    edge_counts.reserve(triangles.size() * 3);

    for (const Vec3i &triangle : triangles)
    {
        add_undirected_edge(edge_counts, triangle[0], triangle[1]);
        add_undirected_edge(edge_counts, triangle[1], triangle[2]);
        add_undirected_edge(edge_counts, triangle[2], triangle[0]);
    }

    if (edge_counts.empty())
    {
        return false;
    }

    for (const auto &entry : edge_counts)
    {
        if (entry.second != 2)
        {
            return false;
        }
    }
    return true;
}

void compute_bounds(const std::vector<Vec3f> &vertices, Vec3f &bbox_min, Vec3f &bbox_max)
{
    bbox_min = vertices.front();
    bbox_max = vertices.front();
    for (std::size_t i = 1; i < vertices.size(); ++i)
    {
        const Vec3f &position = vertices[i];
        bbox_min[0] = std::min(bbox_min[0], position[0]);
        bbox_min[1] = std::min(bbox_min[1], position[1]);
        bbox_min[2] = std::min(bbox_min[2], position[2]);
        bbox_max[0] = std::max(bbox_max[0], position[0]);
        bbox_max[1] = std::max(bbox_max[1], position[1]);
        bbox_max[2] = std::max(bbox_max[2], position[2]);
    }
}

bool validate_dx(float dx, const Vec3f &bbox_min, const Vec3f &bbox_max, std::string &reason)
{
    if (!std::isfinite(dx) || dx <= 0.0f)
    {
        reason = "dx must be a finite positive value";
        return false;
    }

    const float span_x = bbox_max[0] - bbox_min[0];
    const float span_y = bbox_max[1] - bbox_min[1];
    const float span_z = bbox_max[2] - bbox_min[2];
    const float diagonal = std::sqrt(span_x * span_x + span_y * span_y + span_z * span_z);
    if (!std::isfinite(diagonal) || diagonal < kMinBBoxDiagonal)
    {
        reason = "input mesh bounding box is degenerate";
        return false;
    }

    const float min_dx = std::max(kMinimumAbsoluteDx, diagonal * kRelativeMinDxFactor);
    const float max_dx = std::max(min_dx, diagonal * kRelativeMaxDxFactor);
    if (dx < min_dx)
    {
        reason = "dx is too small for the mesh bounding box";
        return false;
    }
    if (dx > max_dx)
    {
        reason = "dx is too large for the mesh bounding box";
        return false;
    }

    const int ni = static_cast<int>(std::ceil(span_x / dx)) + 5;
    const int nj = static_cast<int>(std::ceil(span_y / dx)) + 5;
    const int nk = static_cast<int>(std::ceil(span_z / dx)) + 5;

    if (ni <= 0 || nj <= 0 || nk <= 0)
    {
        reason = "dx produced an invalid voxel grid size";
        return false;
    }
    if (ni > kMaxGridAxisCells || nj > kMaxGridAxisCells || nk > kMaxGridAxisCells)
    {
        reason = "dx would create an excessive voxel grid extent";
        return false;
    }

    const long long total_cells = static_cast<long long>(ni) * static_cast<long long>(nj) * static_cast<long long>(nk);
    if (total_cells <= 0 || total_cells > kMaxGridCellCount)
    {
        reason = "dx would create an excessive voxel grid allocation";
        return false;
    }

    return true;
}

float compute_worst_element_quality(const TetMesh &mesh)
{
    if (mesh.tSize() == 0)
    {
        return 0.0f;
    }

    float worst_quality = std::numeric_limits<float>::infinity();
    for (std::size_t index = 0; index < mesh.tSize(); ++index)
    {
        const Tet tet = mesh.getTet(static_cast<int>(index));
        const float quality = compute_tet_quality(tet);
        if (!std::isfinite(quality))
        {
            return 0.0f;
        }
        worst_quality = std::min(worst_quality, quality);
    }

    if (!std::isfinite(worst_quality))
    {
        return 0.0f;
    }
    return worst_quality;
}

QuartetResult *generate_mesh_impl(const char *input_obj_path,
                                  const char *output_tet_path,
                                  float dx,
                                  int optimize_quality,
                                  float feature_angle_threshold)
{
    QuartetStats stats{};
    if (!is_non_empty_path(input_obj_path) || !is_non_empty_path(output_tet_path))
    {
        return make_result(stats, QUARTET_ERR_INVALID_ARGUMENT, "input and output paths must be non-empty");
    }

    const std::filesystem::path input_path(input_obj_path);
    const std::filesystem::path output_path(output_tet_path);
    if (!std::filesystem::exists(input_path))
    {
        return make_result(stats, QUARTET_ERR_IO, "input OBJ mesh path does not exist");
    }

    std::vector<Vec3f> surface_vertices;
    std::vector<Vec3i> surface_triangles;
    if (!read_objfile(surface_vertices, surface_triangles, "%s", input_path.string().c_str()))
    {
        return make_result(stats, QUARTET_ERR_IO, "failed to read OBJ surface mesh");
    }

    if (surface_vertices.size() < kMinSurfaceVertices || surface_triangles.size() < kMinSurfaceTriangles)
    {
        return make_result(stats, QUARTET_ERR_NOT_WATERTIGHT, "surface mesh is too small to have a closed interior");
    }

    if (!mesh_has_valid_indices(surface_vertices, surface_triangles))
    {
        return make_result(stats, QUARTET_ERR_INVALID_ARGUMENT, "surface mesh contains invalid triangle indices");
    }

    if (!is_watertight_manifold(surface_triangles))
    {
        return make_result(stats, QUARTET_ERR_NOT_WATERTIGHT, "surface mesh is not watertight");
    }

    Vec3f bbox_min;
    Vec3f bbox_max;
    compute_bounds(surface_vertices, bbox_min, bbox_max);

    std::string dx_reason;
    if (!validate_dx(dx, bbox_min, bbox_max, dx_reason))
    {
        return make_result(stats, QUARTET_ERR_INVALID_DX, dx_reason);
    }

    const float span_x = bbox_max[0] - bbox_min[0];
    const float span_y = bbox_max[1] - bbox_min[1];
    const float span_z = bbox_max[2] - bbox_min[2];
    const Vec3f origin = bbox_min - Vec3f(2.0f * dx, 2.0f * dx, 2.0f * dx);
    const int ni = static_cast<int>(std::ceil(span_x / dx)) + 5;
    const int nj = static_cast<int>(std::ceil(span_y / dx)) + 5;
    const int nk = static_cast<int>(std::ceil(span_z / dx)) + 5;

    SDF sdf(origin, dx, ni, nj, nk);
    make_signed_distance(surface_triangles, surface_vertices, sdf);

    TetMesh tet_mesh;
    const bool optimize = (optimize_quality != 0);
    const bool detect_features = std::isfinite(feature_angle_threshold) &&
                                 feature_angle_threshold > 0.0f &&
                                 feature_angle_threshold < 180.0f;

    if (detect_features)
    {
        TriMesh triangle_mesh(surface_vertices, surface_triangles);
        FeatureSet feature_set;
        feature_set.autoDetectFeatures(triangle_mesh, feature_angle_threshold);
        make_tet_mesh(tet_mesh, sdf, feature_set, optimize, false, false);
    }
    else
    {
        make_tet_mesh(tet_mesh, sdf, optimize, false, false);
    }

    if (tet_mesh.vSize() == 0 || tet_mesh.tSize() == 0)
    {
        return make_result(stats, QUARTET_ERR_RUNTIME, "quartet generated an empty tetrahedral mesh");
    }

    try
    {
        if (!output_path.parent_path().empty())
        {
            std::filesystem::create_directories(output_path.parent_path());
        }
    }
    catch (const std::exception &error)
    {
        return make_result(stats, QUARTET_ERR_IO, std::string("failed creating output directory: ") + error.what());
    }

    if (!tet_mesh.writeToFile(output_path.string().c_str()))
    {
        return make_result(stats, QUARTET_ERR_IO, "failed to write output .tet mesh");
    }

    stats.node_count = static_cast<int>(tet_mesh.vSize());
    stats.tetrahedra_count = static_cast<int>(tet_mesh.tSize());
    stats.worst_element_quality = compute_worst_element_quality(tet_mesh);

    return make_result(stats, QUARTET_SUCCESS, "");
}

} // namespace

extern "C" QuartetResult *quartet_generate_mesh(const char *input_obj_path,
                                                  const char *output_tet_path,
                                                  float dx,
                                                  int optimize_quality,
                                                  float feature_angle_threshold)
{
    try
    {
        return generate_mesh_impl(input_obj_path, output_tet_path, dx, optimize_quality, feature_angle_threshold);
    }
    catch (const std::bad_alloc &)
    {
        QuartetStats stats{};
        return make_result(stats, QUARTET_ERR_BAD_ALLOC, "quartet meshing ran out of memory");
    }
    catch (const std::exception &error)
    {
        QuartetStats stats{};
        return make_result(stats, QUARTET_ERR_RUNTIME, std::string("unexpected Quartet failure: ") + error.what());
    }
    catch (...)
    {
        QuartetStats stats{};
        return make_result(stats, QUARTET_ERR_RUNTIME, "unexpected non-standard exception in quartet_generate_mesh");
    }
}

extern "C" void quartet_free_result(QuartetResult *result)
{
    if (!result)
    {
        return;
    }

    char *message = const_cast<char *>(result->error_message);
    delete[] message;
    delete result;
}
