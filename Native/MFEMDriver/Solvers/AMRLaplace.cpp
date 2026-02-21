// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "AMRLaplace.hpp"

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
} // namespace

namespace autosage
{
const char *AMRLaplaceSolver::Name() const
{
    return "AMRLaplace";
}

AMRLaplaceSolver::ParsedConfig AMRLaplaceSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    ParsedConfig parsed;

    if (!config.contains("coefficient") || !config["coefficient"].is_number())
    {
        throw std::runtime_error("config.coefficient is required and must be numeric.");
    }
    parsed.coefficient = config["coefficient"].get<double>();
    if (!(parsed.coefficient > 0.0))
    {
        throw std::runtime_error("config.coefficient must be > 0.");
    }

    if (config.contains("source_term"))
    {
        if (!config["source_term"].is_number())
        {
            throw std::runtime_error("config.source_term must be numeric when provided.");
        }
        parsed.source_term = config["source_term"].get<double>();
    }

    if (!config.contains("amr_settings") || !config["amr_settings"].is_object())
    {
        throw std::runtime_error("config.amr_settings is required and must be an object.");
    }
    const json &amr_settings = config["amr_settings"];
    if (!amr_settings.contains("max_iterations") || !amr_settings["max_iterations"].is_number_integer())
    {
        throw std::runtime_error("config.amr_settings.max_iterations is required and must be an integer.");
    }
    if (!amr_settings.contains("max_dofs") || !amr_settings["max_dofs"].is_number_integer())
    {
        throw std::runtime_error("config.amr_settings.max_dofs is required and must be an integer.");
    }
    if (!amr_settings.contains("error_tolerance") || !amr_settings["error_tolerance"].is_number())
    {
        throw std::runtime_error("config.amr_settings.error_tolerance is required and must be numeric.");
    }
    parsed.max_iterations = amr_settings["max_iterations"].get<int>();
    parsed.max_dofs = amr_settings["max_dofs"].get<int>();
    parsed.error_tolerance = amr_settings["error_tolerance"].get<double>();
    if (parsed.max_iterations <= 0)
    {
        throw std::runtime_error("config.amr_settings.max_iterations must be > 0.");
    }
    if (parsed.max_dofs <= 0)
    {
        throw std::runtime_error("config.amr_settings.max_dofs must be > 0.");
    }
    if (!(parsed.error_tolerance > 0.0))
    {
        throw std::runtime_error("config.amr_settings.error_tolerance must be > 0.");
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
        if (!bc.contains("type") || !bc["type"].is_string())
        {
            throw std::runtime_error("config.bcs[].type is required and must be a string.");
        }
        if (!bc.contains("value") || !bc["value"].is_number())
        {
            throw std::runtime_error("config.bcs[].value is required and must be numeric.");
        }
        const std::string type = to_lower(bc["type"].get<std::string>());
        if (type != "fixed")
        {
            throw std::runtime_error("config.bcs[].type must be fixed.");
        }
        parsed.fixed_marker[attribute - 1] = 1;
        parsed.fixed_values[attribute - 1] = bc["value"].get<double>();
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

SolveSummary AMRLaplaceSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    if (dim <= 0 || dim > 3)
    {
        throw std::runtime_error("AMRLaplace supports mesh dimensions 1, 2, or 3.");
    }
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const ParsedConfig parsed = ParseConfig(config, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mesh.EnsureNCMesh();
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    const int sdim = pmesh.SpaceDimension();

    mfem::H1_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);

    mfem::ParBilinearForm a(&fespace);
    mfem::ParLinearForm b(&fespace);

    mfem::ConstantCoefficient coefficient(parsed.coefficient);
    mfem::ConstantCoefficient source(parsed.source_term);
    auto *diffusion_integrator = new mfem::DiffusionIntegrator(coefficient);
    a.AddDomainIntegrator(diffusion_integrator);
    b.AddDomainIntegrator(new mfem::DomainLFIntegrator(source));

    mfem::ParGridFunction x(&fespace);
    x = 0.0;

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
        x.ProjectBdrCoefficient(fixed_coeff, ess_bdr);
    }

    mfem::L2_FECollection flux_fec(1, dim);
    mfem::ParFiniteElementSpace flux_fes(&pmesh, &flux_fec, sdim);
    std::unique_ptr<mfem::FiniteElementCollection> smooth_flux_fec;
    std::unique_ptr<mfem::ParFiniteElementSpace> smooth_flux_fes;
    if (dim > 1)
    {
        smooth_flux_fec = std::make_unique<mfem::RT_FECollection>(0, dim);
        smooth_flux_fes = std::make_unique<mfem::ParFiniteElementSpace>(&pmesh, smooth_flux_fec.get(), 1);
    }
    else
    {
        smooth_flux_fec = std::make_unique<mfem::H1_FECollection>(1, dim);
        smooth_flux_fes = std::make_unique<mfem::ParFiniteElementSpace>(&pmesh, smooth_flux_fec.get(), dim);
    }

    mfem::L2ZienkiewiczZhuEstimator estimator(*diffusion_integrator, x, flux_fes, *smooth_flux_fes);
    mfem::ThresholdRefiner refiner(estimator);
    refiner.SetTotalErrorFraction(0.7);
    refiner.SetTotalErrorGoal(parsed.error_tolerance);
    refiner.PreferNonconformingRefinement();

    double final_energy = 0.0;
    double final_residual_norm = 0.0;
    double final_total_error = 0.0;
    int final_linear_iterations = 0;
    int amr_iterations_completed = 0;
    std::string stop_reason = "max_iterations";

    for (int iteration = 0; iteration < parsed.max_iterations; ++iteration)
    {
        const HYPRE_BigInt global_dofs = fespace.GlobalTrueVSize();
        if (global_dofs >= static_cast<HYPRE_BigInt>(parsed.max_dofs))
        {
            stop_reason = "max_dofs";
            break;
        }

        if (max_boundary_attribute > 0)
        {
            x.ProjectBdrCoefficient(fixed_coeff, ess_bdr);
        }

        mfem::Array<int> ess_tdof_list;
        if (max_boundary_attribute > 0)
        {
            fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
        }

        b.Assemble();
        a.Assemble();

        mfem::OperatorPtr A;
        mfem::Vector B;
        mfem::Vector X;
        const int copy_interior = 1;
        a.FormLinearSystem(ess_tdof_list, x, b, A, X, B, copy_interior);

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
        pcg.SetTol(1.0e-6);
        pcg.SetAbsTol(0.0);
        pcg.SetMaxIter(2000);
        pcg.SetPrintLevel(0);
        pcg.SetPreconditioner(amg);
        pcg.Mult(B_hypre, X_hypre);

        a.RecoverFEMSolution(X, b, x);

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

        int linear_iterations = 0;
        pcg.GetNumIterations(linear_iterations);

        final_energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), X, B);
        final_linear_iterations = linear_iterations;
        final_residual_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
        (void)estimator.GetLocalErrors();
        final_total_error = estimator.GetTotalError();
        amr_iterations_completed = iteration + 1;

        if (!std::isfinite(final_residual_norm))
        {
            throw std::runtime_error("AMRLaplace residual norm is non-finite.");
        }
        if (!std::isfinite(final_total_error))
        {
            throw std::runtime_error("AMRLaplace estimator error is non-finite.");
        }

        if (final_total_error <= parsed.error_tolerance)
        {
            stop_reason = "error_tolerance";
            break;
        }

        refiner.Apply(pmesh);
        if (refiner.Stop())
        {
            stop_reason = "refiner_stop";
            break;
        }

        fespace.Update();
        x.Update();
        a.Update();
        b.Update();
    }

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
    paraview.RegisterField("solution", &x);
    paraview.SetCycle(amr_iterations_completed);
    paraview.SetTime(static_cast<double>(amr_iterations_completed));
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# AMR Laplace field written to " << collection_name << ".pvd\n";

    const fs::path metadata_path = fs::path(context.working_directory) / "amr_laplace.json";
    json metadata = {
        {"solver_class", "AMRLaplace"},
        {"solver_backend", "pcg_boomeramg"},
        {"dimension", dim},
        {"amr_iterations_completed", amr_iterations_completed},
        {"final_linear_iterations", final_linear_iterations},
        {"final_residual_norm", final_residual_norm},
        {"final_total_error", final_total_error},
        {"stop_reason", stop_reason}
    };
    std::ofstream metadata_out(metadata_path);
    if (!metadata_out)
    {
        throw std::runtime_error("Unable to write amr_laplace.json.");
    }
    metadata_out << metadata.dump(2);

    SolveSummary summary;
    summary.energy = final_energy;
    summary.iterations = amr_iterations_completed;
    summary.error_norm = final_total_error;
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("AMRLaplace solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
