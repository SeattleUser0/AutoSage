// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "AnisotropicDiffusion.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace
{
std::string to_lower(std::string value)
{
    std::transform(
        value.begin(),
        value.end(),
        value.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

bool has_nonzero_entries(const std::vector<double> &values)
{
    for (double value : values)
    {
        if (std::abs(value) > 0.0)
        {
            return true;
        }
    }
    return false;
}
} // namespace

namespace autosage
{
const char *AnisotropicDiffusionSolver::Name() const
{
    return "AnisotropicDiffusion";
}

AnisotropicDiffusionSolver::AnisotropicConfig AnisotropicDiffusionSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    if (!config.contains("diffusion_tensor") || !config["diffusion_tensor"].is_array())
    {
        throw std::runtime_error("config.diffusion_tensor is required and must be an array.");
    }
    if (config["diffusion_tensor"].size() != 9)
    {
        throw std::runtime_error("config.diffusion_tensor must contain exactly 9 numeric values.");
    }

    AnisotropicConfig parsed;
    parsed.diffusion_tensor.reserve(9);
    for (const auto &value : config["diffusion_tensor"])
    {
        if (!value.is_number())
        {
            throw std::runtime_error("config.diffusion_tensor entries must be numeric.");
        }
        parsed.diffusion_tensor.push_back(value.get<double>());
    }

    if (config.contains("source_term"))
    {
        if (!config["source_term"].is_number())
        {
            throw std::runtime_error("config.source_term must be numeric when provided.");
        }
        parsed.source_term = config["source_term"].get<double>();
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.fixed_marker.assign(boundary_slots, 0);
    parsed.fixed_values.assign(boundary_slots, 0.0);
    parsed.flux_values.assign(boundary_slots, 0.0);

    if (boundary_slots == 0 && !config["bcs"].empty())
    {
        throw std::runtime_error("Mesh has no boundary attributes but config.bcs was provided.");
    }

    for (const auto &bc : config["bcs"])
    {
        if (!bc.is_object())
        {
            throw std::runtime_error("config.bcs entries must be objects.");
        }
        if (!bc.contains("attribute") || !bc["attribute"].is_number_integer())
        {
            throw std::runtime_error("config.bcs[].attribute is required and must be an integer.");
        }
        const int attribute = bc["attribute"].get<int>();
        if (attribute <= 0)
        {
            throw std::runtime_error("config.bcs[].attribute must be > 0.");
        }
        if (max_boundary_attribute > 0 && attribute > max_boundary_attribute)
        {
            throw std::runtime_error("config.bcs[].attribute exceeds mesh boundary attribute count.");
        }
        if (!bc.contains("value") || !bc["value"].is_number())
        {
            throw std::runtime_error("config.bcs[].value is required and must be numeric.");
        }
        const double value = bc["value"].get<double>();
        const std::string type = to_lower(bc.value("type", ""));
        if (type == "fixed")
        {
            parsed.fixed_marker[attribute - 1] = 1;
            parsed.fixed_values[attribute - 1] = value;
            continue;
        }
        if (type == "flux")
        {
            parsed.flux_values[attribute - 1] += value;
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be fixed or flux.");
    }

    const bool has_fixed = std::any_of(
        parsed.fixed_marker.begin(),
        parsed.fixed_marker.end(),
        [](int marker) { return marker != 0; }
    );
    if (!has_fixed)
    {
        throw std::runtime_error("config.bcs must include at least one fixed boundary condition.");
    }

    return parsed;
}

SolveSummary AnisotropicDiffusionSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    if (dim <= 0 || dim > 3)
    {
        throw std::runtime_error("AnisotropicDiffusion supports mesh dimensions 1, 2, or 3.");
    }
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const AnisotropicConfig parsed = ParseConfig(config, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);
    mfem::ParGridFunction solution(&fespace);
    solution = 0.0;

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.fixed_marker[i];
    }

    mfem::Vector fixed_values(max_boundary_attribute);
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        fixed_values[i] = parsed.fixed_values[i];
    }
    mfem::PWConstCoefficient fixed_coeff(fixed_values);
    if (max_boundary_attribute > 0)
    {
        solution.ProjectBdrCoefficient(fixed_coeff, ess_bdr);
    }

    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    mfem::DenseMatrix tensor_matrix(dim);
    tensor_matrix = 0.0;
    for (int r = 0; r < dim; ++r)
    {
        for (int c = 0; c < dim; ++c)
        {
            tensor_matrix(r, c) = parsed.diffusion_tensor[(r * 3) + c];
        }
    }
    mfem::MatrixConstantCoefficient tensor_coeff(tensor_matrix);

    mfem::ParBilinearForm stiffness(&fespace);
    stiffness.AddDomainIntegrator(new mfem::DiffusionIntegrator(tensor_coeff));

    mfem::ParLinearForm rhs(&fespace);
    std::unique_ptr<mfem::ConstantCoefficient> source_coeff;
    if (std::abs(parsed.source_term) > 0.0)
    {
        source_coeff = std::make_unique<mfem::ConstantCoefficient>(parsed.source_term);
        rhs.AddDomainIntegrator(new mfem::DomainLFIntegrator(*source_coeff));
    }
    std::unique_ptr<mfem::PWConstCoefficient> flux_coeff;
    if (max_boundary_attribute > 0 && has_nonzero_entries(parsed.flux_values))
    {
        mfem::Vector flux_values(max_boundary_attribute);
        for (int i = 0; i < max_boundary_attribute; ++i)
        {
            flux_values[i] = parsed.flux_values[i];
        }
        flux_coeff = std::make_unique<mfem::PWConstCoefficient>(flux_values);
        rhs.AddBoundaryIntegrator(new mfem::BoundaryLFIntegrator(*flux_coeff));
    }

    stiffness.Assemble();
    rhs.Assemble();

    mfem::OperatorPtr A;
    mfem::Vector X;
    mfem::Vector B;
    stiffness.FormLinearSystem(ess_tdof_list, solution, rhs, A, X, B);

    auto &A_hypre = dynamic_cast<mfem::HypreParMatrix &>(*A.Ptr());
    mfem::HypreParVector B_hypre(
        A_hypre.GetComm(),
        A_hypre.GetGlobalNumRows(),
        B,
        0,
        A_hypre.GetRowStarts()
    );
    mfem::HypreParVector X_hypre(
        A_hypre.GetComm(),
        A_hypre.GetGlobalNumRows(),
        X,
        0,
        A_hypre.GetRowStarts()
    );
    X_hypre = 0.0;

    mfem::HypreBoomerAMG amg(A_hypre);
    amg.SetPrintLevel(0);

    mfem::HyprePCG pcg(A_hypre);
    pcg.SetTol(1.0e-12);
    pcg.SetAbsTol(0.0);
    pcg.SetMaxIter(2000);
    pcg.SetPrintLevel(0);
    pcg.SetPreconditioner(amg);
    pcg.Mult(B_hypre, X_hypre);

    mfem::Vector residual(B.Size());
    mfem::HypreParVector residual_hypre(
        A_hypre.GetComm(),
        A_hypre.GetGlobalNumRows(),
        residual,
        0,
        A_hypre.GetRowStarts()
    );
    A_hypre.Mult(X_hypre, residual_hypre);
    residual_hypre -= B_hypre;
    for (int i = 0; i < ess_tdof_list.Size(); ++i)
    {
        const int tdof = ess_tdof_list[i];
        if (tdof >= 0 && tdof < residual.Size())
        {
            residual[tdof] = 0.0;
        }
    }

    stiffness.RecoverFEMSolution(X, rhs, solution);

    const fs::path vtk_path(context.vtk_path);
    const std::string collection_name = vtk_path.stem().empty() ? "solution" : vtk_path.stem().string();
    const std::string output_dir = vtk_path.has_parent_path()
        ? vtk_path.parent_path().string()
        : context.working_directory;
    fs::create_directories(output_dir);

    mfem::ParaViewDataCollection paraview(collection_name, &pmesh);
    paraview.SetPrefixPath(output_dir);
    paraview.SetLevelsOfDetail(1);
    paraview.SetDataFormat(mfem::VTKFormat::ASCII);
    paraview.RegisterField("solution", &solution);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# anisotropic diffusion field written to " << collection_name << ".pvd\n";

    int num_iterations = 0;
    pcg.GetNumIterations(num_iterations);

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), X, B);
    summary.iterations = num_iterations;
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    summary.dimension = dim;
    if (!std::isfinite(summary.error_norm))
    {
        throw std::runtime_error("AnisotropicDiffusion residual norm is non-finite.");
    }

    const fs::path metadata_path = fs::path(context.working_directory) / "anisotropic_diffusion.json";
    json metadata = {
        {"solver_class", "AnisotropicDiffusion"},
        {"solver_backend", "pcg_boomeramg"},
        {"dimension", dim},
        {"diffusion_tensor", parsed.diffusion_tensor},
        {"source_term", parsed.source_term},
        {"iterations", summary.iterations},
        {"residual_norm", summary.error_norm}
    };
    std::ofstream metadata_out(metadata_path);
    if (!metadata_out)
    {
        throw std::runtime_error("Unable to write anisotropic_diffusion.json.");
    }
    metadata_out << metadata.dump(2);

    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("AnisotropicDiffusion solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
