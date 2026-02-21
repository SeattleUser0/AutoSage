// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "StokesFlow.hpp"

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

std::vector<double> parse_vector_components(
    const json &entry,
    const char *key,
    int dim,
    bool required)
{
    if (!entry.contains(key))
    {
        if (required)
        {
            throw std::runtime_error(std::string(key) + " is required.");
        }
        return std::vector<double>(dim, 0.0);
    }

    if (!entry[key].is_array())
    {
        throw std::runtime_error(std::string(key) + " must be an array.");
    }

    std::vector<double> values;
    values.reserve(entry[key].size());
    for (const auto &component : entry[key])
    {
        if (!component.is_number())
        {
            throw std::runtime_error(std::string(key) + " components must be numeric.");
        }
        values.push_back(component.get<double>());
    }

    if (static_cast<int>(values.size()) < dim)
    {
        throw std::runtime_error(std::string(key) + " must provide at least mesh-dimension components.");
    }
    values.resize(dim);
    return values;
}
} // namespace

namespace autosage
{
const char *StokesFlowSolver::Name() const
{
    return "StokesFlow";
}

StokesFlowSolver::StokesConfig StokesFlowSolver::ParseConfig(
    const json &config,
    int dimension,
    int max_boundary_attribute) const
{
    if (!config.contains("dynamic_viscosity") || !config["dynamic_viscosity"].is_number())
    {
        throw std::runtime_error("config.dynamic_viscosity is required and must be numeric.");
    }
    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    StokesConfig parsed;
    parsed.dynamic_viscosity = config["dynamic_viscosity"].get<double>();
    parsed.body_force = parse_vector_components(config, "body_force", dimension, false);
    if (!(parsed.dynamic_viscosity > 0.0))
    {
        throw std::runtime_error("config.dynamic_viscosity must be > 0.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.essential_marker.assign(boundary_slots, 0);
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
        if (type == "no_slip" || type == "noslip" || type == "no-slip")
        {
            parsed.essential_marker[attribute - 1] = 1;
            continue;
        }
        if (type == "inflow")
        {
            InflowBoundary inflow;
            inflow.attribute = attribute;
            inflow.velocity = parse_vector_components(bc, "velocity", dimension, true);
            parsed.inflow_boundaries.push_back(inflow);
            parsed.essential_marker[attribute - 1] = 1;
            continue;
        }

        throw std::runtime_error("config.bcs[].type must be no_slip or inflow.");
    }

    if (boundary_slots > 0)
    {
        const bool has_essential = std::any_of(
            parsed.essential_marker.begin(),
            parsed.essential_marker.end(),
            [](int marker) { return marker != 0; }
        );
        if (!has_essential)
        {
            throw std::runtime_error("config.bcs must include at least one no_slip or inflow boundary condition.");
        }
    }

    return parsed;
}

SolveSummary StokesFlowSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    const StokesConfig parsed = ParseConfig(config, dim, max_boundary_attribute);

    const int pressure_order = 1;
    const int velocity_order = pressure_order + 1;
    mfem::H1_FECollection velocity_collection(velocity_order, dim);
    mfem::H1_FECollection pressure_collection(pressure_order, dim);
    mfem::ParFiniteElementSpace velocity_space(&pmesh, &velocity_collection, dim);
    mfem::ParFiniteElementSpace pressure_space(&pmesh, &pressure_collection);

    mfem::ParGridFunction velocity(&velocity_space);
    mfem::ParGridFunction pressure(&pressure_space);
    velocity = 0.0;
    pressure = 0.0;

    mfem::Array<int> velocity_ess_bdr(max_boundary_attribute);
    velocity_ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        velocity_ess_bdr[i] = parsed.essential_marker[i];
    }

    const int boundary_slots = std::max(1, max_boundary_attribute);
    std::vector<mfem::Vector> velocity_components;
    velocity_components.reserve(dim);
    for (int d = 0; d < dim; ++d)
    {
        velocity_components.emplace_back(boundary_slots);
        velocity_components.back() = 0.0;
    }
    for (const InflowBoundary &inflow : parsed.inflow_boundaries)
    {
        const int idx = inflow.attribute - 1;
        for (int d = 0; d < dim; ++d)
        {
            velocity_components[d][idx] = inflow.velocity[d];
        }
    }

    if (max_boundary_attribute > 0)
    {
        mfem::VectorArrayCoefficient velocity_bdr_coeff(dim);
        for (int d = 0; d < dim; ++d)
        {
            velocity_bdr_coeff.Set(d, new mfem::PWConstCoefficient(velocity_components[d]), true);
        }
        velocity.ProjectBdrCoefficient(velocity_bdr_coeff, velocity_ess_bdr);
    }

    mfem::Array<int> velocity_ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        velocity_space.GetEssentialTrueDofs(velocity_ess_bdr, velocity_ess_tdof_list);
    }

    mfem::ConstantCoefficient viscosity_coeff(parsed.dynamic_viscosity);
    mfem::ParBilinearForm velocity_form(&velocity_space);
    velocity_form.AddDomainIntegrator(new mfem::VectorDiffusionIntegrator(viscosity_coeff));
    velocity_form.Assemble();

    mfem::ParLinearForm velocity_rhs_form(&velocity_space);
    const bool has_body_force = std::any_of(
        parsed.body_force.begin(),
        parsed.body_force.end(),
        [](double value) { return std::fabs(value) > 0.0; }
    );
    std::unique_ptr<mfem::VectorConstantCoefficient> body_force_coeff;
    if (has_body_force)
    {
        mfem::Vector body_force(dim);
        for (int d = 0; d < dim; ++d)
        {
            body_force[d] = parsed.body_force[d];
        }
        body_force_coeff = std::make_unique<mfem::VectorConstantCoefficient>(body_force);
        velocity_rhs_form.AddDomainIntegrator(new mfem::VectorDomainLFIntegrator(*body_force_coeff));
    }
    velocity_rhs_form.Assemble();

    mfem::OperatorPtr velocity_operator;
    mfem::Vector velocity_true;
    mfem::Vector velocity_rhs_true;
    velocity_form.FormLinearSystem(
        velocity_ess_tdof_list,
        velocity,
        velocity_rhs_form,
        velocity_operator,
        velocity_true,
        velocity_rhs_true
    );

    auto *velocity_matrix = dynamic_cast<mfem::HypreParMatrix *>(velocity_operator.Ptr());
    if (velocity_matrix == nullptr)
    {
        throw std::runtime_error("Failed to assemble Stokes velocity block as HypreParMatrix.");
    }
    const mfem::Vector velocity_bc_true = velocity_true;

    mfem::ParMixedBilinearForm divergence_form(&velocity_space, &pressure_space);
    divergence_form.AddDomainIntegrator(new mfem::VectorDivergenceIntegrator());
    divergence_form.Assemble();
    divergence_form.Finalize();

    std::unique_ptr<mfem::HypreParMatrix> divergence_full(divergence_form.ParallelAssemble());

    mfem::OperatorHandle divergence_handle(mfem::Operator::Hypre_ParCSR);
    const mfem::Array<int> empty_tdof_list;
    divergence_form.FormRectangularSystemMatrix(velocity_ess_tdof_list, empty_tdof_list, divergence_handle);
    auto *divergence_matrix = dynamic_cast<mfem::HypreParMatrix *>(divergence_handle.Ptr());
    if (divergence_matrix == nullptr)
    {
        throw std::runtime_error("Failed to assemble Stokes divergence block as HypreParMatrix.");
    }

    mfem::Vector pressure_rhs_true(pressure_space.TrueVSize());
    pressure_rhs_true = 0.0;
    if (divergence_full != nullptr && velocity_bc_true.Size() == velocity_space.TrueVSize())
    {
        divergence_full->Mult(velocity_bc_true, pressure_rhs_true);
        pressure_rhs_true *= -1.0;
    }

    mfem::Array<int> block_true_offsets(3);
    block_true_offsets[0] = 0;
    block_true_offsets[1] = velocity_space.TrueVSize();
    block_true_offsets[2] = pressure_space.TrueVSize();
    block_true_offsets.PartialSum();

    mfem::BlockVector rhs(block_true_offsets);
    rhs = 0.0;
    rhs.GetBlock(0) = velocity_rhs_true;
    rhs.GetBlock(1) = pressure_rhs_true;

    mfem::BlockVector solution(block_true_offsets);
    solution = 0.0;
    solution.GetBlock(0) = velocity_true;

    auto *gradient_operator = new mfem::TransposeOperator(divergence_matrix);
    mfem::BlockOperator stokes_operator(block_true_offsets);
    stokes_operator.SetBlock(0, 0, velocity_matrix);
    stokes_operator.SetBlock(0, 1, gradient_operator);
    stokes_operator.SetBlock(1, 0, divergence_matrix);

    auto *velocity_preconditioner = new mfem::HypreBoomerAMG(*velocity_matrix);
    velocity_preconditioner->SetPrintLevel(0);

    mfem::ParBilinearForm pressure_mass_form(&pressure_space);
    mfem::ConstantCoefficient inv_viscosity_coeff(1.0 / parsed.dynamic_viscosity);
    pressure_mass_form.AddDomainIntegrator(new mfem::MassIntegrator(inv_viscosity_coeff));
    pressure_mass_form.Assemble();
    pressure_mass_form.Finalize();

    mfem::OperatorHandle pressure_mass_handle(mfem::Operator::Hypre_ParCSR);
    pressure_mass_form.FormSystemMatrix(empty_tdof_list, pressure_mass_handle);
    auto *pressure_mass_matrix = dynamic_cast<mfem::HypreParMatrix *>(pressure_mass_handle.Ptr());
    if (pressure_mass_matrix == nullptr)
    {
        delete velocity_preconditioner;
        delete gradient_operator;
        throw std::runtime_error("Failed to assemble Stokes pressure mass preconditioner matrix.");
    }

    mfem::Vector pressure_diag(pressure_mass_matrix->GetNumRows());
    pressure_mass_matrix->GetDiag(pressure_diag);
    auto *pressure_preconditioner = new mfem::OperatorJacobiSmoother(pressure_diag, empty_tdof_list);
    pressure_preconditioner->iterative_mode = false;

    mfem::BlockDiagonalPreconditioner preconditioner(block_true_offsets);
    preconditioner.SetDiagonalBlock(0, velocity_preconditioner);
    preconditioner.SetDiagonalBlock(1, pressure_preconditioner);

    mfem::MINRESSolver solver(MPI_COMM_WORLD);
    solver.SetAbsTol(1.0e-10);
    solver.SetRelTol(1.0e-8);
    solver.SetMaxIter(500);
    solver.SetPrintLevel(0);
    solver.SetOperator(stokes_operator);
    solver.SetPreconditioner(preconditioner);
    solver.Mult(rhs, solution);

    velocity_form.RecoverFEMSolution(solution.GetBlock(0), velocity_rhs_form, velocity);
    pressure.Distribute(&(solution.GetBlock(1)));

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
    vtk_stub << "# Stokes velocity/pressure written to " << collection_name << ".pvd\n";

    mfem::Vector residual(rhs.Size());
    stokes_operator.Mult(solution, residual);
    residual -= rhs;

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(solution.GetBlock(0), rhs.GetBlock(0));
    summary.iterations = solver.GetNumIterations();
    summary.error_norm = residual.Norml2();
    summary.dimension = dim;

    delete pressure_preconditioner;
    delete velocity_preconditioner;
    delete gradient_operator;
    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("StokesFlow solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
