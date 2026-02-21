// SPDX-License-Identifier: MIT

#include "open3d_ffi.h"

#include <array>
#include <cmath>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <random>
#include <string>
#include <unordered_set>
#include <vector>

#include <open3d/Open3D.h>

namespace
{

constexpr std::size_t kSamplePointCount = 20000;
constexpr std::size_t kMinPointsForPrimitive = 64;
constexpr float kMinInlierRatio = 0.03f;
constexpr int kMaxExtractedPrimitives = 12;

enum class PrimitiveKind
{
    plane,
    cylinder,
    sphere
};

struct PrimitiveCandidate
{
    PrimitiveKind kind = PrimitiveKind::plane;
    std::array<float, 10> parameters{};
    std::vector<std::size_t> inliers;
    float inlier_ratio = 0.0f;
};

char *duplicate_c_string(const std::string &text)
{
    const std::size_t size = text.size();
    char *copy = new char[size + 1];
    std::memcpy(copy, text.c_str(), size + 1);
    return copy;
}

const char *kind_name(PrimitiveKind kind)
{
    switch (kind)
    {
    case PrimitiveKind::plane:
        return "plane";
    case PrimitiveKind::cylinder:
        return "cylinder";
    case PrimitiveKind::sphere:
        return "sphere";
    default:
        return "unknown";
    }
}

O3DResult *make_error_result(int code, const std::string &message)
{
    auto *result = new O3DResult{};
    result->primitives = nullptr;
    result->num_primitives = 0;
    result->unassigned_points_ratio = 1.0f;
    result->error_code = code;
    result->error_message = message.empty() ? nullptr : duplicate_c_string(message);
    return result;
}

bool sample_unique_indices(int count,
                           std::size_t upper_bound,
                           std::mt19937_64 &rng,
                           std::vector<std::size_t> &out_indices)
{
    out_indices.clear();
    if (count <= 0 || upper_bound < static_cast<std::size_t>(count))
    {
        return false;
    }

    std::unordered_set<std::size_t> seen;
    seen.reserve(static_cast<std::size_t>(count * 2));
    std::uniform_int_distribution<std::size_t> dist(0, upper_bound - 1);

    std::size_t attempts = 0;
    const std::size_t max_attempts = static_cast<std::size_t>(count) * 64;
    while (out_indices.size() < static_cast<std::size_t>(count) && attempts++ < max_attempts)
    {
        const std::size_t value = dist(rng);
        if (seen.insert(value).second)
        {
            out_indices.push_back(value);
        }
    }
    return out_indices.size() == static_cast<std::size_t>(count);
}

bool fit_sphere_from_four_points(const Eigen::Vector3d &p0,
                                 const Eigen::Vector3d &p1,
                                 const Eigen::Vector3d &p2,
                                 const Eigen::Vector3d &p3,
                                 Eigen::Vector3d &center,
                                 double &radius)
{
    Eigen::Matrix3d lhs;
    Eigen::Vector3d rhs;
    lhs.row(0) = (2.0 * (p1 - p0)).transpose();
    lhs.row(1) = (2.0 * (p2 - p0)).transpose();
    lhs.row(2) = (2.0 * (p3 - p0)).transpose();

    rhs(0) = p1.squaredNorm() - p0.squaredNorm();
    rhs(1) = p2.squaredNorm() - p0.squaredNorm();
    rhs(2) = p3.squaredNorm() - p0.squaredNorm();

    const double det = lhs.determinant();
    if (!std::isfinite(det) || std::abs(det) < 1.0e-12)
    {
        return false;
    }

    center = lhs.colPivHouseholderQr().solve(rhs);
    if (!center.allFinite())
    {
        return false;
    }

    radius = (center - p0).norm();
    if (!std::isfinite(radius) || radius <= 1.0e-9)
    {
        return false;
    }
    return true;
}

PrimitiveCandidate fit_sphere_candidate(const std::shared_ptr<open3d::geometry::PointCloud> &cloud,
                                        float distance_threshold,
                                        int num_iterations)
{
    PrimitiveCandidate best;
    best.kind = PrimitiveKind::sphere;

    const auto &points = cloud->points_;
    if (points.size() < 4)
    {
        return best;
    }

    std::mt19937_64 rng(std::random_device{}());
    std::vector<std::size_t> sample;

    for (int iteration = 0; iteration < num_iterations; ++iteration)
    {
        if (!sample_unique_indices(4, points.size(), rng, sample))
        {
            continue;
        }

        Eigen::Vector3d center;
        double radius = 0.0;
        if (!fit_sphere_from_four_points(points[sample[0]],
                                         points[sample[1]],
                                         points[sample[2]],
                                         points[sample[3]],
                                         center,
                                         radius))
        {
            continue;
        }

        std::vector<std::size_t> inliers;
        inliers.reserve(points.size() / 8);
        for (std::size_t idx = 0; idx < points.size(); ++idx)
        {
            const double radial = (points[idx] - center).norm();
            if (std::abs(radial - radius) <= static_cast<double>(distance_threshold))
            {
                inliers.push_back(idx);
            }
        }

        if (inliers.size() > best.inliers.size())
        {
            best.inliers = std::move(inliers);
            best.parameters = {};
            best.parameters[0] = static_cast<float>(center.x());
            best.parameters[1] = static_cast<float>(center.y());
            best.parameters[2] = static_cast<float>(center.z());
            best.parameters[3] = static_cast<float>(radius);
            best.inlier_ratio = static_cast<float>(best.inliers.size()) / static_cast<float>(points.size());
        }
    }

    return best;
}

PrimitiveCandidate fit_cylinder_candidate(const std::shared_ptr<open3d::geometry::PointCloud> &cloud,
                                          float distance_threshold,
                                          int num_iterations)
{
    PrimitiveCandidate best;
    best.kind = PrimitiveKind::cylinder;

    const auto &points = cloud->points_;
    if (points.size() < 3)
    {
        return best;
    }

    std::mt19937_64 rng(std::random_device{}());
    std::vector<std::size_t> sample;

    for (int iteration = 0; iteration < num_iterations; ++iteration)
    {
        if (!sample_unique_indices(3, points.size(), rng, sample))
        {
            continue;
        }

        const Eigen::Vector3d &p0 = points[sample[0]];
        const Eigen::Vector3d &p1 = points[sample[1]];
        const Eigen::Vector3d &p2 = points[sample[2]];

        Eigen::Vector3d axis = p1 - p0;
        const double axis_norm = axis.norm();
        if (!std::isfinite(axis_norm) || axis_norm <= 1.0e-9)
        {
            continue;
        }
        axis /= axis_norm;

        const Eigen::Vector3d v = p2 - p0;
        const Eigen::Vector3d radial_vec = v - v.dot(axis) * axis;
        const double radius = radial_vec.norm();
        if (!std::isfinite(radius) || radius <= 1.0e-9)
        {
            continue;
        }

        std::vector<std::size_t> inliers;
        inliers.reserve(points.size() / 8);
        for (std::size_t idx = 0; idx < points.size(); ++idx)
        {
            const Eigen::Vector3d offset = points[idx] - p0;
            const Eigen::Vector3d projected = offset.dot(axis) * axis;
            const double radial_distance = (offset - projected).norm();
            if (std::abs(radial_distance - radius) <= static_cast<double>(distance_threshold))
            {
                inliers.push_back(idx);
            }
        }

        if (inliers.size() > best.inliers.size())
        {
            best.inliers = std::move(inliers);
            best.parameters = {};
            best.parameters[0] = static_cast<float>(p0.x());
            best.parameters[1] = static_cast<float>(p0.y());
            best.parameters[2] = static_cast<float>(p0.z());
            best.parameters[3] = static_cast<float>(axis.x());
            best.parameters[4] = static_cast<float>(axis.y());
            best.parameters[5] = static_cast<float>(axis.z());
            best.parameters[6] = static_cast<float>(radius);
            best.inlier_ratio = static_cast<float>(best.inliers.size()) / static_cast<float>(points.size());
        }
    }

    return best;
}

PrimitiveCandidate fit_plane_candidate(const std::shared_ptr<open3d::geometry::PointCloud> &cloud,
                                       float distance_threshold,
                                       int ransac_n,
                                       int num_iterations)
{
    PrimitiveCandidate candidate;
    candidate.kind = PrimitiveKind::plane;

    if (cloud->points_.size() < static_cast<std::size_t>(std::max(3, ransac_n)))
    {
        return candidate;
    }

    auto segmentation = cloud->SegmentPlane(distance_threshold, ransac_n, num_iterations);
    const Eigen::Vector4d model = std::get<0>(segmentation);
    candidate.inliers = std::get<1>(segmentation);
    candidate.parameters = {};
    candidate.parameters[0] = static_cast<float>(model.x());
    candidate.parameters[1] = static_cast<float>(model.y());
    candidate.parameters[2] = static_cast<float>(model.z());
    candidate.parameters[3] = static_cast<float>(model.w());

    if (!cloud->points_.empty())
    {
        candidate.inlier_ratio = static_cast<float>(candidate.inliers.size()) /
                                 static_cast<float>(cloud->points_.size());
    }
    return candidate;
}

bool candidate_better(const PrimitiveCandidate &left, const PrimitiveCandidate &right)
{
    if (left.inliers.size() != right.inliers.size())
    {
        return left.inliers.size() > right.inliers.size();
    }
    return left.inlier_ratio > right.inlier_ratio;
}

O3DResult *extract_impl(const char *input_mesh_path,
                        float distance_threshold,
                        int ransac_n,
                        int num_iterations)
{
    if (input_mesh_path == nullptr || input_mesh_path[0] == '\0')
    {
        return make_error_result(O3D_ERR_INVALID_ARGUMENT, "input_mesh_path must be non-empty");
    }
    if (!std::isfinite(distance_threshold) || distance_threshold <= 0.0f)
    {
        return make_error_result(O3D_ERR_INVALID_ARGUMENT, "distance_threshold must be > 0");
    }
    if (ransac_n < 3)
    {
        return make_error_result(O3D_ERR_INVALID_ARGUMENT, "ransac_n must be >= 3");
    }
    if (num_iterations < 16)
    {
        return make_error_result(O3D_ERR_INVALID_ARGUMENT, "num_iterations must be >= 16");
    }

    open3d::geometry::TriangleMesh mesh;
    if (!open3d::io::ReadTriangleMesh(input_mesh_path, mesh, false))
    {
        return make_error_result(O3D_ERR_MESH_LOAD_FAILED, "failed to load mesh");
    }
    if (!mesh.HasVertices() || !mesh.HasTriangles())
    {
        return make_error_result(O3D_ERR_MESH_LOAD_FAILED, "mesh is empty or invalid");
    }

    std::shared_ptr<open3d::geometry::PointCloud> cloud = mesh.SamplePointsUniformly(kSamplePointCount, false);
    if (!cloud || cloud->points_.empty())
    {
        return make_error_result(O3D_ERR_POINTCLOUD_GENERATION_FAILED, "failed to sample point cloud from mesh");
    }

    const std::size_t original_points = cloud->points_.size();
    std::shared_ptr<open3d::geometry::PointCloud> active_cloud = cloud;

    std::vector<PrimitiveCandidate> extracted;
    extracted.reserve(kMaxExtractedPrimitives);

    for (int primitive_index = 0; primitive_index < kMaxExtractedPrimitives; ++primitive_index)
    {
        if (!active_cloud || active_cloud->points_.size() < kMinPointsForPrimitive)
        {
            break;
        }

        PrimitiveCandidate plane = fit_plane_candidate(active_cloud, distance_threshold, ransac_n, num_iterations);
        PrimitiveCandidate sphere = fit_sphere_candidate(active_cloud, distance_threshold, num_iterations);
        PrimitiveCandidate cylinder = fit_cylinder_candidate(active_cloud, distance_threshold, num_iterations);

        PrimitiveCandidate best = plane;
        if (candidate_better(sphere, best))
        {
            best = sphere;
        }
        if (candidate_better(cylinder, best))
        {
            best = cylinder;
        }

        if (best.inliers.empty() || best.inlier_ratio < kMinInlierRatio)
        {
            break;
        }

        auto remainder = active_cloud->SelectByIndex(best.inliers, true);
        if (!remainder || remainder->points_.size() >= active_cloud->points_.size())
        {
            break;
        }

        extracted.push_back(best);
        active_cloud = remainder;
    }

    if (extracted.empty())
    {
        return make_error_result(O3D_ERR_PRIMITIVE_FIT_TIMEOUT, "RANSAC failed to extract primitives");
    }

    auto *result = new O3DResult{};
    result->num_primitives = static_cast<int>(extracted.size());
    result->primitives = new O3DPrimitive[extracted.size()];
    for (std::size_t i = 0; i < extracted.size(); ++i)
    {
        const PrimitiveCandidate &candidate = extracted[i];
        O3DPrimitive &primitive = result->primitives[i];
        primitive.type = duplicate_c_string(kind_name(candidate.kind));
        for (int param_index = 0; param_index < 10; ++param_index)
        {
            primitive.parameters[param_index] = candidate.parameters[static_cast<std::size_t>(param_index)];
        }
        primitive.inlier_ratio = candidate.inlier_ratio;
    }

    const std::size_t remaining_points = active_cloud ? active_cloud->points_.size() : 0;
    result->unassigned_points_ratio = original_points > 0
                                              ? static_cast<float>(remaining_points) / static_cast<float>(original_points)
                                              : 1.0f;
    result->error_code = O3D_SUCCESS;
    result->error_message = nullptr;
    return result;
}

} // namespace

extern "C" O3DResult *open3d_extract_primitives(const char *input_mesh_path,
                                                 float distance_threshold,
                                                 int ransac_n,
                                                 int num_iterations)
{
    try
    {
        return extract_impl(input_mesh_path, distance_threshold, ransac_n, num_iterations);
    }
    catch (const std::exception &error)
    {
        return make_error_result(O3D_ERR_RUNTIME, std::string("unexpected Open3D failure: ") + error.what());
    }
    catch (...)
    {
        return make_error_result(O3D_ERR_RUNTIME, "unexpected non-standard exception in open3d_extract_primitives");
    }
}

extern "C" void open3d_free_result(O3DResult *result)
{
    if (result == nullptr)
    {
        return;
    }

    if (result->primitives != nullptr && result->num_primitives > 0)
    {
        for (int i = 0; i < result->num_primitives; ++i)
        {
            delete[] const_cast<char *>(result->primitives[i].type);
        }
        delete[] result->primitives;
    }

    delete[] const_cast<char *>(result->error_message);
    delete result;
}
