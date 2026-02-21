// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "DPGLaplace.hpp"

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
const char *DPGLaplaceSolver::Name() const
{
    return "DPGLaplace";
}

DPGLaplaceSolver::ParsedConfig DPGLaplaceSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    ParsedConfig parsed;

    if (!config.contains("coefficient") || !config["coefficient"].is_number())
    {
        throw std::runtime_error("config.coefficient is required and must be numeric.");
    }
    parsed.coefficient = config["coefficient"].get<double>();
    if (!std::isfinite(parsed.coefficient) || !(parsed.coefficient > 0.0))
    {
        throw std::runtime_error("config.coefficient must be finite and > 0.");
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

    if (config.contains("order"))
    {
        if (!config["order"].is_number_integer())
        {
            throw std::runtime_error("config.order must be an integer when provided.");
        }
        parsed.order = config["order"].get<int>();
    }
    if (parsed.order < 1)
    {
        throw std::runtime_error("config.order must be >= 1.");
    }
    if (parsed.order > 8)
    {
        throw std::runtime_error("config.order must be <= 8.");
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

SolveSummary DPGLaplaceSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    if (dim <= 0 || dim > 3)
    {
        throw std::runtime_error("DPGLaplace supports mesh dimensions 1, 2, and 3.");
    }

    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const ParsedConfig parsed = ParseConfig(config, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);

    const unsigned int trial_order = static_cast<unsigned int>(parsed.order);
    const unsigned int trace_order = trial_order > 0 ? (trial_order - 1u) : 0u;
    unsigned int test_order = trial_order;
    if (dim == 2 && (trial_order % 2u == 0u ||
                     ((pmesh.MeshGenerator() & 2) != 0 && trial_order > 1u)))
    {
        test_order++;
    }

    mfem::H1_FECollection x0_fec(static_cast<int>(trial_order), dim);
    mfem::RT_Trace_FECollection xhat_fec(static_cast<int>(trace_order), dim);
    mfem::L2_FECollection test_fec(static_cast<int>(test_order), dim);

    mfem::ParFiniteElementSpace x0_space(&pmesh, &x0_fec);
    mfem::ParFiniteElementSpace xhat_space(&pmesh, &xhat_fec);
    mfem::ParFiniteElementSpace test_space(&pmesh, &test_fec);

    mfem::ConstantCoefficient diffusion_coeff(parsed.coefficient);
    mfem::ConstantCoefficient source_coeff(parsed.source_term);
    mfem::ConstantCoefficient one_coeff(1.0);

    mfem::ParLinearForm F(&test_space);
    F.AddDomainIntegrator(new mfem::DomainLFIntegrator(source_coeff));
    F.Assemble();

    mfem::ParGridFunction x0(&x0_space);
    x0 = 0.0;

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
        x0.ProjectBdrCoefficient(fixed_coeff, ess_bdr);
    }

    mfem::Array<int> ess_dof;
    if (max_boundary_attribute > 0)
    {
        x0_space.GetEssentialVDofs(ess_bdr, ess_dof);
    }

    mfem::ParMixedBilinearForm B0(&x0_space, &test_space);
    B0.AddDomainIntegrator(new mfem::DiffusionIntegrator(diffusion_coeff));
    B0.Assemble();
    B0.EliminateEssentialBCFromTrialDofs(ess_dof, x0, F);
    B0.Finalize();

    mfem::ParMixedBilinearForm Bhat(&xhat_space, &test_space);
    Bhat.AddTraceFaceIntegrator(new mfem::TraceJumpIntegrator());
    Bhat.Assemble();
    Bhat.Finalize();

    mfem::ParBilinearForm Sinv(&test_space);
    auto *sum = new mfem::SumIntegrator();
    sum->AddIntegrator(new mfem::DiffusionIntegrator(diffusion_coeff));
    sum->AddIntegrator(new mfem::MassIntegrator(one_coeff));
    Sinv.AddDomainIntegrator(new mfem::InverseIntegrator(sum));
    Sinv.Assemble();
    Sinv.Finalize();

    mfem::ParBilinearForm S0(&x0_space);
    S0.AddDomainIntegrator(new mfem::DiffusionIntegrator(diffusion_coeff));
    S0.Assemble();
    if (max_boundary_attribute > 0)
    {
        S0.EliminateEssentialBC(ess_bdr);
    }
    S0.Finalize();

    std::unique_ptr<mfem::HypreParMatrix> matB0(B0.ParallelAssemble());
    std::unique_ptr<mfem::HypreParMatrix> matBhat(Bhat.ParallelAssemble());
    std::unique_ptr<mfem::HypreParMatrix> matSinv(Sinv.ParallelAssemble());
    std::unique_ptr<mfem::HypreParMatrix> matS0(S0.ParallelAssemble());

    enum
    {
        x0_var,
        xhat_var,
        nvar
    };
    (void)xhat_var;

    mfem::Array<int> true_offsets(nvar + 1);
    true_offsets[0] = 0;
    true_offsets[1] = x0_space.TrueVSize();
    true_offsets[2] = true_offsets[1] + xhat_space.TrueVSize();

    mfem::Array<int> test_offsets(2);
    test_offsets[0] = 0;
    test_offsets[1] = test_space.TrueVSize();

    mfem::BlockVector x(true_offsets);
    mfem::BlockVector b(true_offsets);
    x = 0.0;
    b = 0.0;

    mfem::BlockOperator B(test_offsets, true_offsets);
    B.SetBlock(0, 0, matB0.get());
    B.SetBlock(0, 1, matBhat.get());

    mfem::RAPOperator A(B, *matSinv, B);

    std::unique_ptr<mfem::HypreParVector> true_f(F.ParallelAssemble());
    {
        mfem::HypreParVector sinv_f(&test_space);
        matSinv->Mult(*true_f, sinv_f);
        B.MultTranspose(sinv_f, b);
    }

    std::unique_ptr<mfem::HypreBoomerAMG> s0_inverse =
        std::make_unique<mfem::HypreBoomerAMG>(*matS0);
    s0_inverse->SetPrintLevel(0);

    std::unique_ptr<mfem::HypreParMatrix> shat(mfem::RAP(matSinv.get(), matBhat.get()));
    std::unique_ptr<mfem::HypreSolver> shat_inverse;
    std::string trace_preconditioner;
    if (dim == 2)
    {
        shat_inverse = std::make_unique<mfem::HypreAMS>(*shat, &xhat_space);
        trace_preconditioner = "hypre_ams";
    }
    else if (dim == 3)
    {
        shat_inverse = std::make_unique<mfem::HypreADS>(*shat, &xhat_space);
        trace_preconditioner = "hypre_ads";
    }
    else
    {
        shat_inverse = std::make_unique<mfem::HypreBoomerAMG>(*shat);
        trace_preconditioner = "hypre_boomeramg";
    }

    mfem::BlockDiagonalPreconditioner preconditioner(true_offsets);
    preconditioner.SetDiagonalBlock(0, s0_inverse.get());
    preconditioner.SetDiagonalBlock(1, shat_inverse.get());

    mfem::CGSolver pcg(MPI_COMM_WORLD);
    pcg.SetOperator(A);
    pcg.SetPreconditioner(preconditioner);
    pcg.SetRelTol(1.0e-8);
    pcg.SetAbsTol(0.0);
    pcg.SetMaxIter(500);
    pcg.SetPrintLevel(0);
    pcg.Mult(b, x);

    mfem::HypreParVector residual(&test_space);
    mfem::HypreParVector weighted_residual(&test_space);
    B.Mult(x, residual);
    residual -= *true_f;
    matSinv->Mult(residual, weighted_residual);

    const double weighted_residual_sq = mfem::InnerProduct(residual, weighted_residual);
    const double weighted_residual_norm = std::sqrt(std::max(0.0, weighted_residual_sq));
    if (!std::isfinite(weighted_residual_norm))
    {
        throw std::runtime_error("DPGLaplace residual norm is non-finite.");
    }

    x0.Distribute(x.GetBlock(x0_var));

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
    paraview.RegisterField("u", &x0);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    if (!vtk_stub)
    {
        throw std::runtime_error("Unable to write solution.vtk stub for DPGLaplace.");
    }
    vtk_stub << "# DPG Laplace field written to " << collection_name << ".pvd\n";

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(x, b);
    summary.iterations = pcg.GetNumIterations();
    summary.error_norm = weighted_residual_norm;
    summary.dimension = dim;

    const fs::path metadata_path = fs::path(context.working_directory) / "dpg_laplace.json";
    json metadata = {
        {"solver_class", "DPGLaplace"},
        {"solver_backend", "dpg_normal_equation_pcg"},
        {"trace_preconditioner", trace_preconditioner},
        {"coefficient", parsed.coefficient},
        {"source_term", parsed.source_term},
        {"order", parsed.order},
        {"trial_true_dofs", x0_space.TrueVSize()},
        {"trace_true_dofs", xhat_space.TrueVSize()},
        {"test_true_dofs", test_space.TrueVSize()},
        {"iterations", summary.iterations},
        {"residual_norm", summary.error_norm}
    };
    std::ofstream metadata_out(metadata_path);
    if (!metadata_out)
    {
        throw std::runtime_error("Unable to write dpg_laplace.json.");
    }
    metadata_out << metadata.dump(2);

    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("DPGLaplace solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
