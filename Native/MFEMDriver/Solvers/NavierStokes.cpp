// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "NavierStokes.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
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

double number_or_default(const json &value, const char *key, double fallback)
{
    if (!value.contains(key)) { return fallback; }
    if (!value[key].is_number())
    {
        throw std::runtime_error(std::string(key) + " must be a number.");
    }
    return value[key].get<double>();
}

int int_or_default(const json &value, const char *key, int fallback)
{
    if (!value.contains(key)) { return fallback; }
    if (!value[key].is_number_integer())
    {
        throw std::runtime_error(std::string(key) + " must be an integer.");
    }
    return value[key].get<int>();
}

std::vector<double> parse_vector_components(const json &entry, const char *key, int dim, bool required)
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

mfem::Vector build_body_force(const std::vector<double> &body_force, int dim)
{
    mfem::Vector force(dim);
    force = 0.0;
    const int count = std::min(dim, static_cast<int>(body_force.size()));
    for (int i = 0; i < count; ++i)
    {
        force[i] = body_force[i];
    }
    return force;
}
} // namespace

namespace autosage
{
const char *NavierStokesSolver::Name() const
{
    return "NavierStokes";
}

NavierStokesSolver::NavierConfig NavierStokesSolver::ParseConfig(
    const json &config,
    int dim,
    int max_boundary_attribute) const
{
    NavierConfig parsed;
    parsed.viscosity = number_or_default(config, "viscosity", parsed.viscosity);
    parsed.density = number_or_default(config, "density", parsed.density);
    parsed.t_final = number_or_default(config, "t_final", parsed.t_final);
    parsed.dt = number_or_default(config, "dt", parsed.dt);
    parsed.output_interval_steps = int_or_default(config, "output_interval_steps", parsed.output_interval_steps);

    if (parsed.viscosity <= 0.0) { throw std::runtime_error("viscosity must be > 0."); }
    if (parsed.density <= 0.0) { throw std::runtime_error("density must be > 0."); }
    if (parsed.t_final <= 0.0) { throw std::runtime_error("t_final must be > 0."); }
    if (parsed.dt <= 0.0) { throw std::runtime_error("dt must be > 0."); }
    if (parsed.output_interval_steps <= 0) { throw std::runtime_error("output_interval_steps must be > 0."); }

    parsed.body_force = parse_vector_components(config, "g", dim, false);
    if (config.contains("body_force"))
    {
        parsed.body_force = parse_vector_components(config, "body_force", dim, false);
    }

    if (!config.contains("bcs"))
    {
        return parsed;
    }
    if (!config["bcs"].is_array())
    {
        throw std::runtime_error("bcs must be an array.");
    }
    if (max_boundary_attribute == 0 && !config["bcs"].empty())
    {
        throw std::runtime_error("Mesh has no boundary attributes, but config.bcs is non-empty.");
    }

    for (const auto &item : config["bcs"])
    {
        if (!item.is_object()) { continue; }
        BoundaryCondition bc;
        if (!item.contains("attr") || !item["attr"].is_number_integer())
        {
            throw std::runtime_error("Each bcs item must include integer attr.");
        }
        bc.attr = item["attr"].get<int>();
        if (bc.attr <= 0)
        {
            throw std::runtime_error("bcs[].attr must be > 0.");
        }
        if (max_boundary_attribute > 0 && bc.attr > max_boundary_attribute)
        {
            throw std::runtime_error("bcs[].attr exceeds mesh boundary attribute count.");
        }

        bc.type = to_lower(item.value("type", ""));
        if (bc.type != "inlet" && bc.type != "outlet" && bc.type != "wall")
        {
            throw std::runtime_error("bcs[].type must be inlet, outlet, or wall.");
        }

        if (bc.type == "inlet")
        {
            bc.velocity = parse_vector_components(item, "velocity", dim, true);
        }
        else if (bc.type == "wall")
        {
            bc.velocity = parse_vector_components(item, "velocity", dim, false);
        }
        else if (bc.type == "outlet")
        {
            if (item.contains("pressure"))
            {
                if (!item["pressure"].is_number())
                {
                    throw std::runtime_error("bcs[].pressure must be numeric for outlet.");
                }
                bc.pressure = item["pressure"].get<double>();
            }
            else
            {
                bc.pressure = 0.0;
            }
        }

        parsed.bcs.push_back(std::move(bc));
    }

    return parsed;
}

SolveSummary NavierStokesSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const NavierConfig cfg = ParseConfig(config, dim, max_boundary_attribute);

    mfem::H1_FECollection fec(1, dim);
    mfem::FiniteElementSpace velocity_fespace(&mesh, &fec, dim);
    mfem::FiniteElementSpace pressure_fespace(&mesh, &fec);

    mfem::GridFunction u_n(&velocity_fespace);
    mfem::GridFunction u_star(&velocity_fespace);
    mfem::GridFunction u_np1(&velocity_fespace);
    mfem::GridFunction p_n(&pressure_fespace);
    mfem::GridFunction p_np1(&pressure_fespace);
    u_n = 0.0;
    u_star = 0.0;
    u_np1 = 0.0;
    p_n = 0.0;
    p_np1 = 0.0;

    mfem::Array<int> velocity_ess_bdr(max_boundary_attribute);
    mfem::Array<int> pressure_ess_bdr(max_boundary_attribute);
    velocity_ess_bdr = 0;
    pressure_ess_bdr = 0;

    const int boundary_slots = std::max(1, max_boundary_attribute);
    std::vector<mfem::Vector> velocity_components;
    velocity_components.reserve(dim);
    for (int d = 0; d < dim; ++d)
    {
        velocity_components.emplace_back(boundary_slots);
        velocity_components.back() = 0.0;
    }
    mfem::Vector outlet_pressure(boundary_slots);
    outlet_pressure = 0.0;

    for (const BoundaryCondition &bc : cfg.bcs)
    {
        const int idx = bc.attr - 1;
        if (bc.type == "inlet" || bc.type == "wall")
        {
            velocity_ess_bdr[idx] = 1;
            for (int d = 0; d < dim; ++d)
            {
                velocity_components[d][idx] = bc.velocity[d];
            }
        }
        if (bc.type == "outlet")
        {
            pressure_ess_bdr[idx] = 1;
            outlet_pressure[idx] = bc.pressure.value_or(0.0);
        }
    }

    mfem::VectorArrayCoefficient velocity_bdr_coeff(dim);
    for (int d = 0; d < dim; ++d)
    {
        velocity_bdr_coeff.Set(d, new mfem::PWConstCoefficient(velocity_components[d]), true);
    }
    mfem::PWConstCoefficient pressure_bdr_coeff(outlet_pressure);

    if (max_boundary_attribute > 0)
    {
        u_n.ProjectBdrCoefficient(velocity_bdr_coeff, velocity_ess_bdr);
        p_n.ProjectBdrCoefficient(pressure_bdr_coeff, pressure_ess_bdr);
    }

    mfem::Array<int> velocity_ess_tdofs;
    mfem::Array<int> pressure_ess_tdofs;
    if (max_boundary_attribute > 0)
    {
        velocity_fespace.GetEssentialTrueDofs(velocity_ess_bdr, velocity_ess_tdofs);
        pressure_fespace.GetEssentialTrueDofs(pressure_ess_bdr, pressure_ess_tdofs);
    }

    mfem::ConstantCoefficient one(1.0);
    mfem::BilinearForm mass_form(&velocity_fespace);
    mass_form.AddDomainIntegrator(new mfem::VectorMassIntegrator(one));
    mass_form.Assemble();
    mass_form.Finalize();
    mfem::SparseMatrix mass_matrix(mass_form.SpMat());

    mfem::BilinearForm diffusion_form(&velocity_fespace);
    diffusion_form.AddDomainIntegrator(new mfem::VectorDiffusionIntegrator(one));
    diffusion_form.Assemble();
    diffusion_form.Finalize();
    mfem::SparseMatrix diffusion_matrix(diffusion_form.SpMat());

    mfem::BilinearForm pressure_form(&pressure_fespace);
    pressure_form.AddDomainIntegrator(new mfem::DiffusionIntegrator(one));
    pressure_form.Assemble();
    pressure_form.Finalize();
    mfem::SparseMatrix pressure_matrix_base(pressure_form.SpMat());

    mfem::MixedBilinearForm divergence_form(&velocity_fespace, &pressure_fespace);
    divergence_form.AddDomainIntegrator(new mfem::VectorDivergenceIntegrator(one));
    divergence_form.Assemble();
    divergence_form.Finalize();
    mfem::SparseMatrix divergence_matrix(divergence_form.SpMat());

    mfem::MixedBilinearForm gradient_form(&pressure_fespace, &velocity_fespace);
    gradient_form.AddDomainIntegrator(new mfem::GradientIntegrator(one));
    gradient_form.Assemble();
    gradient_form.Finalize();
    mfem::SparseMatrix gradient_matrix(gradient_form.SpMat());

    mfem::NonlinearForm convection_form(&velocity_fespace);
    convection_form.AddDomainIntegrator(new mfem::VectorConvectionNLFIntegrator(one));

    const mfem::Vector body_force = build_body_force(cfg.body_force, dim);
    mfem::VectorConstantCoefficient body_force_coeff(body_force);
    mfem::LinearForm body_force_form(&velocity_fespace);
    body_force_form.AddDomainIntegrator(new mfem::VectorDomainLFIntegrator(body_force_coeff));
    body_force_form.Assemble();
    const int velocity_true_size = velocity_fespace.GetTrueVSize();
    const int pressure_true_size = pressure_fespace.GetTrueVSize();
    mfem::Vector body_force_true(velocity_true_size);
    if (body_force_form.Size() == body_force_true.Size())
    {
        body_force_true = body_force_form;
    }
    else
    {
        body_force_true = 0.0;
    }

    const fs::path vtk_path(context.vtk_path);
    const std::string collection_name = vtk_path.stem().empty() ? "solution" : vtk_path.stem().string();
    const std::string output_dir = vtk_path.has_parent_path()
        ? vtk_path.parent_path().string()
        : context.working_directory;
    fs::create_directories(output_dir);

    mfem::ParaViewDataCollection paraview(collection_name, &mesh);
    paraview.SetPrefixPath(output_dir);
    paraview.SetLevelsOfDetail(1);
    paraview.SetDataFormat(mfem::VTKFormat::ASCII);
    paraview.SetHighOrderOutput(true);
    paraview.RegisterField("velocity", &u_n);
    paraview.RegisterField("pressure", &p_n);

    auto save_step = [&](int step, double time) {
        paraview.SetCycle(step);
        paraview.SetTime(time);
        paraview.Save();
    };

    mfem::Vector u_n_true(velocity_true_size);
    mfem::Vector u_star_true(velocity_true_size);
    mfem::Vector u_np1_true(velocity_true_size);
    mfem::Vector u_bc_true(velocity_true_size);
    mfem::Vector p_n_true(pressure_true_size);
    mfem::Vector p_np1_true(pressure_true_size);
    mfem::Vector p_bc_true(pressure_true_size);

    u_n.GetTrueDofs(u_n_true);
    p_n.GetTrueDofs(p_n_true);
    if (max_boundary_attribute > 0)
    {
        u_n.GetTrueDofs(u_bc_true);
        p_n.GetTrueDofs(p_bc_true);
    }
    else
    {
        u_bc_true = 0.0;
        p_bc_true = 0.0;
    }

    int total_iterations = 0;
    int step = 0;
    double time = 0.0;
    save_step(step, time);

    while (time + 1.0e-12 < cfg.t_final)
    {
        const double current_dt = std::min(cfg.dt, cfg.t_final - time);

        // Step 1: tentative velocity solve.
        mfem::Vector convection_dofs(velocity_fespace.GetVSize());
        convection_form.Mult(u_n, convection_dofs);
        mfem::Vector convection_true(velocity_true_size);
        if (convection_true.Size() == convection_dofs.Size())
        {
            convection_true = convection_dofs;
        }
        else
        {
            convection_true = 0.0;
        }

        std::unique_ptr<mfem::SparseMatrix> predictor_matrix(
            mfem::Add(cfg.density / current_dt, mass_matrix, cfg.viscosity, diffusion_matrix));
        if (!predictor_matrix)
        {
            throw std::runtime_error("Failed to assemble tentative velocity matrix.");
        }

        mfem::Vector predictor_rhs(velocity_true_size);
        mass_matrix.Mult(u_n_true, predictor_rhs);
        predictor_rhs *= (cfg.density / current_dt);
        predictor_rhs -= convection_true;
        predictor_rhs += body_force_true;

        for (int i = 0; i < velocity_ess_tdofs.Size(); ++i)
        {
            const int tdof = velocity_ess_tdofs[i];
            predictor_matrix->EliminateRowCol(
                tdof,
                u_bc_true[tdof],
                predictor_rhs,
                mfem::Operator::DIAG_ONE
            );
        }

        mfem::GSSmoother predictor_preconditioner(*predictor_matrix);
        mfem::CGSolver predictor_solver;
        predictor_solver.SetRelTol(1.0e-8);
        predictor_solver.SetAbsTol(0.0);
        predictor_solver.SetMaxIter(400);
        predictor_solver.SetPrintLevel(0);
        predictor_solver.SetOperator(*predictor_matrix);
        predictor_solver.SetPreconditioner(predictor_preconditioner);
        predictor_solver.Mult(predictor_rhs, u_star_true);
        total_iterations += predictor_solver.GetNumIterations();

        u_star.SetFromTrueDofs(u_star_true);

        // Step 2: pressure Poisson solve.
        mfem::SparseMatrix pressure_matrix(pressure_matrix_base);
        mfem::Vector pressure_rhs(pressure_true_size);
        divergence_matrix.Mult(u_star_true, pressure_rhs);
        pressure_rhs *= (cfg.density / current_dt);

        for (int i = 0; i < pressure_ess_tdofs.Size(); ++i)
        {
            const int tdof = pressure_ess_tdofs[i];
            pressure_matrix.EliminateRowCol(
                tdof,
                p_bc_true[tdof],
                pressure_rhs,
                mfem::Operator::DIAG_ONE
            );
        }
        if (pressure_ess_tdofs.Size() == 0 && pressure_rhs.Size() > 0)
        {
            pressure_matrix.EliminateRowCol(0, 0.0, pressure_rhs, mfem::Operator::DIAG_ONE);
        }

        mfem::GSSmoother pressure_preconditioner(pressure_matrix);
        mfem::CGSolver pressure_solver;
        pressure_solver.SetRelTol(1.0e-10);
        pressure_solver.SetAbsTol(0.0);
        pressure_solver.SetMaxIter(400);
        pressure_solver.SetPrintLevel(0);
        pressure_solver.SetOperator(pressure_matrix);
        pressure_solver.SetPreconditioner(pressure_preconditioner);
        pressure_solver.Mult(pressure_rhs, p_np1_true);
        total_iterations += pressure_solver.GetNumIterations();

        p_np1.SetFromTrueDofs(p_np1_true);

        // Step 3: velocity correction.
        mfem::Vector grad_pressure_true(velocity_true_size);
        gradient_matrix.Mult(p_np1_true, grad_pressure_true);
        u_np1_true = u_star_true;
        u_np1_true.Add(-current_dt / cfg.density, grad_pressure_true);
        for (int i = 0; i < velocity_ess_tdofs.Size(); ++i)
        {
            const int tdof = velocity_ess_tdofs[i];
            u_np1_true[tdof] = u_bc_true[tdof];
        }
        u_np1.SetFromTrueDofs(u_np1_true);

        // Advance state.
        u_n = u_np1;
        p_n = p_np1;
        u_n.GetTrueDofs(u_n_true);
        p_n.GetTrueDofs(p_n_true);

        ++step;
        time += current_dt;
        if (step % cfg.output_interval_steps == 0 || time + 1.0e-12 >= cfg.t_final)
        {
            save_step(step, time);
        }
    }

    mfem::Vector kinetic_tmp(velocity_true_size);
    mass_matrix.Mult(u_n_true, kinetic_tmp);

    SolveSummary summary;
    summary.energy = 0.5 * cfg.density * mfem::InnerProduct(u_n_true, kinetic_tmp);
    summary.iterations = total_iterations;
    summary.error_norm = 0.0;
    summary.dimension = dim;
    return summary;
}
} // namespace autosage
