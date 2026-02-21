// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "DarcyFlow.hpp"

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
const char *DarcyFlowSolver::Name() const
{
    return "DarcyFlow";
}

DarcyFlowSolver::DarcyConfig DarcyFlowSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    if (!config.contains("permeability") || !config["permeability"].is_number())
    {
        throw std::runtime_error("config.permeability is required and must be numeric.");
    }
    DarcyConfig parsed;
    parsed.permeability = config["permeability"].get<double>();
    if (!(parsed.permeability > 0.0))
    {
        throw std::runtime_error("config.permeability must be > 0.");
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
    parsed.no_flow_marker.assign(boundary_slots, 0);
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

        const std::string type = to_lower(bc.value("type", ""));
        if (type == "no_flow" || type == "noflow" || type == "no-flow")
        {
            parsed.no_flow_marker[attribute - 1] = 1;
            continue;
        }
        if (type == "fixed_pressure" || type == "fixed-pressure" || type == "fixedpressure")
        {
            if (!bc.contains("value") || !bc["value"].is_number())
            {
                throw std::runtime_error("config.bcs[].value is required and must be numeric for fixed_pressure.");
            }
            PressureBoundary pressure_boundary;
            pressure_boundary.attribute = attribute;
            pressure_boundary.value = bc["value"].get<double>();
            parsed.fixed_pressure_boundaries.push_back(pressure_boundary);
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be fixed_pressure or no_flow.");
    }

    if (parsed.fixed_pressure_boundaries.empty())
    {
        throw std::runtime_error("config.bcs must include at least one fixed_pressure boundary condition.");
    }

    return parsed;
}

SolveSummary DarcyFlowSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    const DarcyConfig parsed = ParseConfig(config, max_boundary_attribute);

    mfem::RT_FECollection velocity_collection(1, dim);
    mfem::L2_FECollection pressure_collection(1, dim);
    mfem::ParFiniteElementSpace velocity_space(&pmesh, &velocity_collection);
    mfem::ParFiniteElementSpace pressure_space(&pmesh, &pressure_collection);

    mfem::Array<int> velocity_ess_bdr(max_boundary_attribute);
    velocity_ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        velocity_ess_bdr[i] = parsed.no_flow_marker[i];
    }
    mfem::Array<int> velocity_ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        velocity_space.GetEssentialTrueDofs(velocity_ess_bdr, velocity_ess_tdof_list);
    }

    mfem::ParBilinearForm mass_form(&velocity_space);
    mfem::ConstantCoefficient inv_permeability_coeff(1.0 / parsed.permeability);
    mass_form.AddDomainIntegrator(new mfem::VectorFEMassIntegrator(inv_permeability_coeff));
    mass_form.Assemble();
    mass_form.Finalize();

    mfem::ParMixedBilinearForm divergence_form(&velocity_space, &pressure_space);
    divergence_form.AddDomainIntegrator(new mfem::VectorFEDivergenceIntegrator());
    divergence_form.Assemble();
    divergence_form.Finalize();

    mfem::ParLinearForm velocity_rhs_form(&velocity_space);
    std::vector<std::unique_ptr<mfem::ConstantCoefficient>> pressure_coeffs;
    std::vector<mfem::Array<int>> pressure_markers;
    pressure_coeffs.reserve(parsed.fixed_pressure_boundaries.size());
    pressure_markers.reserve(parsed.fixed_pressure_boundaries.size());
    for (const PressureBoundary &boundary : parsed.fixed_pressure_boundaries)
    {
        pressure_coeffs.push_back(std::make_unique<mfem::ConstantCoefficient>(-boundary.value));
        pressure_markers.emplace_back(max_boundary_attribute);
        pressure_markers.back() = 0;
        pressure_markers.back()[boundary.attribute - 1] = 1;
        velocity_rhs_form.AddBoundaryIntegrator(
            new mfem::VectorFEBoundaryFluxLFIntegrator(*pressure_coeffs.back()),
            pressure_markers.back()
        );
    }
    velocity_rhs_form.Assemble();

    mfem::ParLinearForm pressure_rhs_form(&pressure_space);
    std::unique_ptr<mfem::ConstantCoefficient> source_coeff;
    if (std::abs(parsed.source_term) > 0.0)
    {
        source_coeff = std::make_unique<mfem::ConstantCoefficient>(-parsed.source_term);
        pressure_rhs_form.AddDomainIntegrator(new mfem::DomainLFIntegrator(*source_coeff));
    }
    pressure_rhs_form.Assemble();

    mfem::OperatorHandle op_m(mfem::Operator::Hypre_ParCSR);
    mfem::OperatorHandle op_b(mfem::Operator::Hypre_ParCSR);
    const mfem::Array<int> empty_tdof_list;
    mass_form.FormSystemMatrix(velocity_ess_tdof_list, op_m);
    divergence_form.FormRectangularSystemMatrix(velocity_ess_tdof_list, empty_tdof_list, op_b);

    auto *mass_matrix = dynamic_cast<mfem::HypreParMatrix *>(op_m.Ptr());
    auto *divergence_matrix = dynamic_cast<mfem::HypreParMatrix *>(op_b.Ptr());
    if (mass_matrix == nullptr || divergence_matrix == nullptr)
    {
        throw std::runtime_error("Failed to assemble Darcy block matrices as HypreParMatrix.");
    }
    (*divergence_matrix) *= -1.0;

    mfem::Array<int> block_true_offsets(3);
    block_true_offsets[0] = 0;
    block_true_offsets[1] = velocity_space.TrueVSize();
    block_true_offsets[2] = pressure_space.TrueVSize();
    block_true_offsets.PartialSum();

    mfem::BlockVector true_rhs(block_true_offsets);
    true_rhs = 0.0;
    velocity_rhs_form.ParallelAssemble(true_rhs.GetBlock(0));
    pressure_rhs_form.ParallelAssemble(true_rhs.GetBlock(1));
    for (int i = 0; i < velocity_ess_tdof_list.Size(); ++i)
    {
        const int tdof = velocity_ess_tdof_list[i];
        if (tdof >= 0 && tdof < true_rhs.GetBlock(0).Size())
        {
            true_rhs.GetBlock(0)[tdof] = 0.0;
        }
    }

    auto *transpose_b = new mfem::TransposeOperator(divergence_matrix);
    mfem::BlockOperator darcy_operator(block_true_offsets);
    darcy_operator.SetBlock(0, 0, mass_matrix);
    darcy_operator.SetBlock(0, 1, transpose_b);
    darcy_operator.SetBlock(1, 0, divergence_matrix);

    mfem::Vector mass_diag(mass_matrix->GetNumRows());
    mass_matrix->GetDiag(mass_diag);

    auto *minv_bt = divergence_matrix->Transpose();
    minv_bt->InvScaleRows(mass_diag);
    auto *schur_approx = mfem::ParMult(divergence_matrix, minv_bt);
    schur_approx->EliminateZeroRows();

    mfem::Vector schur_diag(schur_approx->GetNumRows());
    schur_approx->GetDiag(schur_diag);
    const mfem::Array<int> empty_schur_tdof_list;

    auto *inv_mass = new mfem::OperatorJacobiSmoother(mass_diag, velocity_ess_tdof_list);
    auto *inv_schur = new mfem::OperatorJacobiSmoother(schur_diag, empty_schur_tdof_list);
    inv_mass->iterative_mode = false;
    inv_schur->iterative_mode = false;

    mfem::BlockDiagonalPreconditioner darcy_preconditioner(block_true_offsets);
    darcy_preconditioner.SetDiagonalBlock(0, inv_mass);
    darcy_preconditioner.SetDiagonalBlock(1, inv_schur);

    mfem::BlockVector true_solution(block_true_offsets);
    true_solution = 0.0;

    mfem::MINRESSolver solver(MPI_COMM_WORLD);
    solver.SetAbsTol(1.0e-10);
    solver.SetRelTol(1.0e-6);
    solver.SetMaxIter(500);
    solver.SetPrintLevel(0);
    solver.SetOperator(darcy_operator);
    solver.SetPreconditioner(darcy_preconditioner);
    solver.Mult(true_rhs, true_solution);

    mfem::ParGridFunction velocity(&velocity_space);
    mfem::ParGridFunction pressure(&pressure_space);
    velocity = 0.0;
    pressure = 0.0;
    velocity.Distribute(&(true_solution.GetBlock(0)));
    pressure.Distribute(&(true_solution.GetBlock(1)));

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
    paraview.RegisterField("velocity", &velocity);
    paraview.RegisterField("pressure", &pressure);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# Darcy velocity/pressure written to " << collection_name << ".pvd\n";

    mfem::Vector residual(true_rhs.Size());
    darcy_operator.Mult(true_solution, residual);
    residual -= true_rhs;

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(true_solution, true_rhs);
    summary.iterations = solver.GetNumIterations();
    summary.error_norm = residual.Norml2();
    summary.dimension = dim;

    delete inv_schur;
    delete inv_mass;
    delete schur_approx;
    delete minv_bt;
    delete transpose_b;

    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("DarcyFlow solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
