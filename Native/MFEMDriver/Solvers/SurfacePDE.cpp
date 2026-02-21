// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "SurfacePDE.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>

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
} // namespace

namespace autosage
{
const char *SurfacePDESolver::Name() const
{
    return "SurfacePDE";
}

SurfacePDESolver::SurfacePDEConfig SurfacePDESolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    SurfacePDEConfig parsed;

    if (!config.contains("diffusion_coefficient") || !config["diffusion_coefficient"].is_number())
    {
        throw std::runtime_error("config.diffusion_coefficient is required and must be numeric.");
    }
    parsed.diffusion_coefficient = config["diffusion_coefficient"].get<double>();
    if (!std::isfinite(parsed.diffusion_coefficient) || !(parsed.diffusion_coefficient > 0.0))
    {
        throw std::runtime_error("config.diffusion_coefficient must be finite and > 0.");
    }

    if (config.contains("source_term"))
    {
        if (!config["source_term"].is_number())
        {
            throw std::runtime_error("config.source_term must be numeric when provided.");
        }
        parsed.source_term = config["source_term"].get<double>();
        if (!std::isfinite(parsed.source_term))
        {
            throw std::runtime_error("config.source_term must be finite when provided.");
        }
    }

    if (config.contains("is_closed_surface"))
    {
        if (!config["is_closed_surface"].is_boolean())
        {
            throw std::runtime_error("config.is_closed_surface must be boolean when provided.");
        }
        parsed.is_closed_surface = config["is_closed_surface"].get<bool>();
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.fixed_marker.assign(boundary_slots, 0);
    parsed.fixed_values.assign(boundary_slots, 0.0);

    if (boundary_slots == 0 && !config["bcs"].empty())
    {
        throw std::runtime_error("Mesh has no boundary attributes but config.bcs was provided.");
    }

    bool has_fixed_boundary = false;
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
        if (!bc.contains("type") || !bc["type"].is_string())
        {
            throw std::runtime_error("config.bcs[].type is required and must be a string.");
        }
        if (!bc.contains("value") || !bc["value"].is_number())
        {
            throw std::runtime_error("config.bcs[].value is required and must be numeric.");
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

        const std::string type = to_lower(bc["type"].get<std::string>());
        if (type != "fixed")
        {
            throw std::runtime_error("config.bcs[].type must be fixed.");
        }

        const double value = bc["value"].get<double>();
        if (!std::isfinite(value))
        {
            throw std::runtime_error("config.bcs[].value must be finite.");
        }

        parsed.fixed_marker[attribute - 1] = 1;
        parsed.fixed_values[attribute - 1] = value;
        has_fixed_boundary = true;
    }

    if (!parsed.is_closed_surface && !has_fixed_boundary)
    {
        throw std::runtime_error("config.bcs must include at least one fixed boundary condition for open surfaces.");
    }

    return parsed;
}

SolveSummary SurfacePDESolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    if (dim != 2)
    {
        throw std::runtime_error("SurfacePDE requires a 2D surface mesh.");
    }

    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const SurfacePDEConfig parsed = ParseConfig(config, max_boundary_attribute);

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

    bool gauge_fix_applied = false;
    if (parsed.is_closed_surface && ess_tdof_list.Size() == 0)
    {
        if (fespace.GetTrueVSize() <= 0)
        {
            throw std::runtime_error("SurfacePDE mesh produced zero true dofs.");
        }
        ess_tdof_list.SetSize(1);
        ess_tdof_list[0] = 0;
        gauge_fix_applied = true;
    }

    mfem::ConstantCoefficient diffusion_coeff(parsed.diffusion_coefficient);
    mfem::ParBilinearForm stiffness(&fespace);
    stiffness.AddDomainIntegrator(new mfem::DiffusionIntegrator(diffusion_coeff));

    mfem::ParLinearForm rhs(&fespace);
    std::unique_ptr<mfem::ConstantCoefficient> source_coeff;
    if (std::abs(parsed.source_term) > 0.0)
    {
        source_coeff = std::make_unique<mfem::ConstantCoefficient>(parsed.source_term);
        rhs.AddDomainIntegrator(new mfem::DomainLFIntegrator(*source_coeff));
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
    vtk_stub << "# surface PDE field written to " << collection_name << ".pvd\n";

    int num_iterations = 0;
    pcg.GetNumIterations(num_iterations);

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), X, B);
    summary.iterations = num_iterations;
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    summary.dimension = dim;
    if (!std::isfinite(summary.error_norm))
    {
        throw std::runtime_error("SurfacePDE residual norm is non-finite.");
    }

    const fs::path metadata_path = fs::path(context.working_directory) / "surface_pde.json";
    json metadata = {
        {"solver_class", "SurfacePDE"},
        {"solver_backend", "pcg_boomeramg"},
        {"dimension", dim},
        {"space_dimension", mesh.SpaceDimension()},
        {"diffusion_coefficient", parsed.diffusion_coefficient},
        {"source_term", parsed.source_term},
        {"is_closed_surface", parsed.is_closed_surface},
        {"gauge_fix_applied", gauge_fix_applied},
        {"iterations", summary.iterations},
        {"residual_norm", summary.error_norm}
    };
    std::ofstream metadata_out(metadata_path);
    if (!metadata_out)
    {
        throw std::runtime_error("Unable to write surface_pde.json.");
    }
    metadata_out << metadata.dump(2);

    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("SurfacePDE solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
