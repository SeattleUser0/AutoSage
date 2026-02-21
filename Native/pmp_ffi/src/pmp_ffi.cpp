// SPDX-License-Identifier: MIT

#include "pmp_ffi.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>
#include <filesystem>
#include <limits>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

#include <pmp/algorithms/decimation.h>
#include <pmp/algorithms/differential_geometry.h>
#include <pmp/algorithms/hole_filling.h>
#include <pmp/io/io.h>
#include <pmp/surface_mesh.h>

namespace {

constexpr double kDegenerateFaceAreaEpsilon = 1.0e-12;

char *duplicate_c_string(const std::string &text)
{
    const auto size = text.size();
    auto *copy = new char[size + 1];
    std::memcpy(copy, text.c_str(), size + 1);
    return copy;
}

PmpResult *make_result(const PmpDefectReport &report, int code, const std::string &message)
{
    auto *result = new PmpResult{};
    result->report = report;
    result->error_code = code;
    result->error_message = message.empty() ? nullptr : duplicate_c_string(message);
    return result;
}

bool is_non_empty_path(const char *value)
{
    return value != nullptr && value[0] != '\0';
}

int count_non_manifold_vertices(const pmp::SurfaceMesh &mesh)
{
    int count = 0;
    for (auto vertex : mesh.vertices())
    {
        if (!mesh.is_manifold(vertex))
        {
            ++count;
        }
    }
    return count;
}

int count_degenerate_faces(const pmp::SurfaceMesh &mesh)
{
    int count = 0;
    for (auto face : mesh.faces())
    {
        const auto area = pmp::face_area(mesh, face);
        if (!std::isfinite(area) || area <= kDegenerateFaceAreaEpsilon)
        {
            ++count;
        }
    }
    return count;
}

pmp::Halfedge next_boundary_halfedge(const pmp::SurfaceMesh &mesh, pmp::Halfedge halfedge)
{
    auto next = mesh.next_halfedge(halfedge);
    std::size_t guard = 0;
    const std::size_t max_steps = std::max<std::size_t>(4, mesh.n_halfedges() + 4);
    while (next.is_valid() && !mesh.is_boundary(next) && guard++ < max_steps)
    {
        next = mesh.opposite_halfedge(mesh.next_halfedge(next));
    }
    return next;
}

std::vector<pmp::Halfedge> collect_boundary_loops(const pmp::SurfaceMesh &mesh)
{
    std::unordered_set<pmp::IndexType> visited;
    std::vector<pmp::Halfedge> loops;

    for (auto halfedge : mesh.halfedges())
    {
        if (!mesh.is_boundary(halfedge))
        {
            continue;
        }
        if (visited.find(halfedge.idx()) != visited.end())
        {
            continue;
        }

        loops.push_back(halfedge);

        auto current = halfedge;
        std::size_t guard = 0;
        const std::size_t max_steps = std::max<std::size_t>(4, mesh.n_halfedges() + 4);
        do
        {
            visited.insert(current.idx());
            current = next_boundary_halfedge(mesh, current);
            if (!current.is_valid())
            {
                break;
            }
            if (guard++ >= max_steps)
            {
                break;
            }
        } while (current != halfedge);
    }

    return loops;
}

int target_vertices_from_faces(int target_faces)
{
    if (target_faces <= 0)
    {
        return 0;
    }
    return std::max(4, target_faces / 2);
}

PmpResult *process_mesh_impl(const char *input_path,
                             const char *repaired_output_path,
                             const char *decimated_output_path,
                             int target_decimation_faces,
                             int fill_holes,
                             int resolve_intersections)
{
    PmpDefectReport report{};

    if (!is_non_empty_path(input_path) ||
        !is_non_empty_path(repaired_output_path) ||
        !is_non_empty_path(decimated_output_path))
    {
        return make_result(report, PMP_ERR_INVALID_ARGUMENT, "input and output paths must be non-empty");
    }

    if (target_decimation_faces <= 0)
    {
        return make_result(report, PMP_ERR_INVALID_ARGUMENT, "target_decimation_faces must be > 0");
    }

    const std::filesystem::path input(input_path);
    const std::filesystem::path repaired_output(repaired_output_path);
    const std::filesystem::path decimated_output(decimated_output_path);

    if (!std::filesystem::exists(input))
    {
        return make_result(report, PMP_ERR_IO, "input mesh path does not exist");
    }

    pmp::SurfaceMesh mesh;
    try
    {
        pmp::read(mesh, input);
    }
    catch (const std::exception &error)
    {
        return make_result(report, PMP_ERR_IO, std::string("failed to read input mesh: ") + error.what());
    }

    report.initial_holes = static_cast<int>(collect_boundary_loops(mesh).size());
    report.initial_non_manifold_edges = count_non_manifold_vertices(mesh);
    report.initial_degenerate_faces = count_degenerate_faces(mesh);

    int unresolved = 0;

    if (fill_holes != 0)
    {
        auto loop_starts = collect_boundary_loops(mesh);
        for (auto halfedge : loop_starts)
        {
            if (!mesh.is_valid(halfedge) || !mesh.is_boundary(halfedge))
            {
                continue;
            }
            try
            {
                pmp::fill_hole(mesh, halfedge);
            }
            catch (...)
            {
                ++unresolved;
            }
        }
    }

    const int current_non_manifold = count_non_manifold_vertices(mesh);
    if (resolve_intersections != 0)
    {
        try
        {
            mesh.garbage_collection();
        }
        catch (...)
        {
            unresolved += std::max(0, current_non_manifold);
        }

        const int remaining_non_manifold = count_non_manifold_vertices(mesh);
        unresolved += std::max(0, remaining_non_manifold);
    }
    else if (current_non_manifold > 0)
    {
        unresolved += current_non_manifold;
    }

    report.unresolved_errors = unresolved;

    try
    {
        pmp::write(mesh, repaired_output);
    }
    catch (const std::exception &error)
    {
        return make_result(report, PMP_ERR_IO, std::string("failed to write repaired mesh: ") + error.what());
    }

    pmp::SurfaceMesh decimated_mesh(mesh);
    const int target_vertices = target_vertices_from_faces(target_decimation_faces);
    if (target_vertices > 0 && static_cast<int>(decimated_mesh.n_vertices()) > target_vertices)
    {
        try
        {
            pmp::decimate(decimated_mesh, static_cast<unsigned int>(target_vertices));
        }
        catch (const std::exception &error)
        {
            return make_result(report, PMP_ERR_ALGORITHM, std::string("mesh decimation failed: ") + error.what());
        }
    }

    try
    {
        pmp::write(decimated_mesh, decimated_output);
    }
    catch (const std::exception &error)
    {
        return make_result(report, PMP_ERR_IO, std::string("failed to write decimated mesh: ") + error.what());
    }

    if (report.unresolved_errors > 0)
    {
        if (fill_holes != 0 && report.initial_holes > 0)
        {
            return make_result(report, PMP_ERR_HOLE_FILL_FAILED, "hole filling left unresolved defects");
        }
        return make_result(report, PMP_ERR_NON_MANIFOLD_UNRESOLVABLE, "non-manifold defects remain after processing");
    }

    return make_result(report, PMP_SUCCESS, "");
}

} // namespace

extern "C" PmpResult *pmp_process_mesh(const char *input_path,
                                         const char *repaired_output_path,
                                         const char *decimated_output_path,
                                         int target_decimation_faces,
                                         int fill_holes,
                                         int resolve_intersections)
{
    try
    {
        return process_mesh_impl(input_path,
                                 repaired_output_path,
                                 decimated_output_path,
                                 target_decimation_faces,
                                 fill_holes,
                                 resolve_intersections);
    }
    catch (const std::exception &error)
    {
        PmpDefectReport report{};
        return make_result(report, PMP_ERR_ALGORITHM, std::string("unexpected PMP failure: ") + error.what());
    }
    catch (...)
    {
        PmpDefectReport report{};
        return make_result(report, PMP_ERR_ALGORITHM, "unexpected non-standard exception in pmp_process_mesh");
    }
}

extern "C" void pmp_free_result(PmpResult *result)
{
    if (!result)
    {
        return;
    }

    auto *message = const_cast<char *>(result->error_message);
    delete[] message;
    delete result;
}
