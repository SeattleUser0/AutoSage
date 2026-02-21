// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "Advection.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
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

double require_positive_number(const json &object, const char *field_name)
{
    if (!object.contains(field_name) || !object[field_name].is_number())
    {
        throw std::runtime_error(std::string("config.") + field_name + " is required and must be numeric.");
    }
    const double value = object[field_name].get<double>();
    if (!(value > 0.0))
    {
        throw std::runtime_error(std::string("config.") + field_name + " must be > 0.");
    }
    return value;
}

int int_or_default(const json &object, const char *field_name, int fallback)
{
    if (!object.contains(field_name))
    {
        return fallback;
    }
    if (!object[field_name].is_number_integer())
    {
        throw std::runtime_error(std::string("config.") + field_name + " must be an integer.");
    }
    return object[field_name].get<int>();
}

class StepFunctionCoefficient final : public mfem::Coefficient
{
public:
    StepFunctionCoefficient(std::vector<double> center, double radius, double value)
        : center_(std::move(center)),
          radius_sq_(radius * radius),
          value_(value)
    {
    }

    mfem::real_t Eval(mfem::ElementTransformation &transformation, const mfem::IntegrationPoint &ip) override
    {
        mfem::Vector position;
        transformation.Transform(ip, position);

        double distance_sq = 0.0;
        const int dims = std::min(position.Size(), static_cast<int>(center_.size()));
        for (int i = 0; i < dims; ++i)
        {
            const double delta = position[i] - center_[static_cast<size_t>(i)];
            distance_sq += delta * delta;
        }
        return distance_sq <= radius_sq_ ? value_ : 0.0;
    }

private:
    std::vector<double> center_;
    double radius_sq_;
    double value_;
};

class DGSolverOperator final : public mfem::TimeDependentOperator
{
public:
    DGSolverOperator(
        mfem::SparseMatrix &mass_matrix,
        mfem::SparseMatrix &advection_matrix,
        const mfem::Vector &boundary_vector)
        : mfem::TimeDependentOperator(mass_matrix.Height()),
          mass_matrix_(mass_matrix),
          advection_matrix_(advection_matrix),
          boundary_vector_(boundary_vector),
          mass_preconditioner_(mass_matrix),
          mass_solver_(),
          z_(height)
    {
        mass_solver_.iterative_mode = false;
        mass_solver_.SetRelTol(1.0e-10);
        mass_solver_.SetAbsTol(0.0);
        mass_solver_.SetMaxIter(500);
        mass_solver_.SetPrintLevel(0);
        mass_solver_.SetPreconditioner(mass_preconditioner_);
        mass_solver_.SetOperator(mass_matrix_);
    }

    void Mult(const mfem::Vector &x, mfem::Vector &y) const override
    {
        advection_matrix_.Mult(x, z_);
        z_ += boundary_vector_;
        mass_solver_.Mult(z_, y);
    }

private:
    mfem::SparseMatrix &mass_matrix_;
    mfem::SparseMatrix &advection_matrix_;
    const mfem::Vector &boundary_vector_;

    mutable mfem::GSSmoother mass_preconditioner_;
    mutable mfem::CGSolver mass_solver_;
    mutable mfem::Vector z_;
};
} // namespace

namespace autosage
{
const char *AdvectionSolver::Name() const
{
    return "Advection";
}

AdvectionSolver::AdvectionConfig AdvectionSolver::ParseConfig(
    const json &config,
    int dim,
    int max_boundary_attribute) const
{
    AdvectionConfig parsed;
    parsed.dt = require_positive_number(config, "dt");
    parsed.t_final = require_positive_number(config, "t_final");
    parsed.order = int_or_default(config, "order", parsed.order);
    parsed.output_interval_steps = int_or_default(config, "output_interval_steps", parsed.output_interval_steps);

    if (parsed.order < 0)
    {
        throw std::runtime_error("config.order must be >= 0.");
    }
    if (parsed.output_interval_steps <= 0)
    {
        throw std::runtime_error("config.output_interval_steps must be > 0.");
    }

    if (!config.contains("velocity_field") || !config["velocity_field"].is_array())
    {
        throw std::runtime_error("config.velocity_field is required and must be an array.");
    }
    if (config["velocity_field"].empty())
    {
        throw std::runtime_error("config.velocity_field must not be empty.");
    }

    parsed.velocity_field.reserve(config["velocity_field"].size());
    for (const auto &component : config["velocity_field"])
    {
        if (!component.is_number())
        {
            throw std::runtime_error("config.velocity_field entries must be numeric.");
        }
        parsed.velocity_field.push_back(component.get<double>());
    }
    if (static_cast<int>(parsed.velocity_field.size()) < dim)
    {
        parsed.velocity_field.resize(dim, 0.0);
    }
    if (static_cast<int>(parsed.velocity_field.size()) > dim)
    {
        parsed.velocity_field.resize(dim);
    }

    if (!config.contains("initial_condition") || !config["initial_condition"].is_object())
    {
        throw std::runtime_error("config.initial_condition is required and must be an object.");
    }
    const json &initial = config["initial_condition"];
    const std::string type = to_lower(initial.value("type", ""));
    if (type != "step_function" && type != "step-function" && type != "stepfunction")
    {
        throw std::runtime_error("config.initial_condition.type must be step_function.");
    }

    if (!initial.contains("center") || !initial["center"].is_array())
    {
        throw std::runtime_error("config.initial_condition.center is required and must be an array.");
    }
    if (initial["center"].empty())
    {
        throw std::runtime_error("config.initial_condition.center must not be empty.");
    }

    parsed.initial_condition.center.reserve(initial["center"].size());
    for (const auto &component : initial["center"])
    {
        if (!component.is_number())
        {
            throw std::runtime_error("config.initial_condition.center entries must be numeric.");
        }
        parsed.initial_condition.center.push_back(component.get<double>());
    }
    if (static_cast<int>(parsed.initial_condition.center.size()) < dim)
    {
        parsed.initial_condition.center.resize(dim, 0.0);
    }
    if (static_cast<int>(parsed.initial_condition.center.size()) > dim)
    {
        parsed.initial_condition.center.resize(dim);
    }

    if (!initial.contains("radius") || !initial["radius"].is_number())
    {
        throw std::runtime_error("config.initial_condition.radius is required and must be numeric.");
    }
    parsed.initial_condition.radius = initial["radius"].get<double>();
    if (!(parsed.initial_condition.radius > 0.0))
    {
        throw std::runtime_error("config.initial_condition.radius must be > 0.");
    }
    if (!initial.contains("value") || !initial["value"].is_number())
    {
        throw std::runtime_error("config.initial_condition.value is required and must be numeric.");
    }
    parsed.initial_condition.value = initial["value"].get<double>();

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    if (max_boundary_attribute == 0 && !config["bcs"].empty())
    {
        throw std::runtime_error("Mesh has no boundary attributes but config.bcs was provided.");
    }

    parsed.inflow_boundaries.reserve(config["bcs"].size());
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

        const std::string bc_type = to_lower(bc.value("type", ""));
        if (bc_type != "inflow")
        {
            throw std::runtime_error("config.bcs[].type must be inflow.");
        }

        if (!bc.contains("value") || !bc["value"].is_number())
        {
            throw std::runtime_error("config.bcs[].value is required and must be numeric.");
        }

        InflowBoundary inflow;
        inflow.attribute = attribute;
        inflow.value = bc["value"].get<double>();
        parsed.inflow_boundaries.push_back(inflow);
    }

    return parsed;
}

SolveSummary AdvectionSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    if (dim <= 0)
    {
        throw std::runtime_error("Advection solver requires a positive mesh dimension.");
    }

    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const AdvectionConfig parsed = ParseConfig(config, dim, max_boundary_attribute);

    mfem::L2_FECollection fec(parsed.order, dim);
    mfem::FiniteElementSpace fespace(&mesh, &fec);

    mfem::Vector velocity_vector(dim);
    velocity_vector = 0.0;
    for (int i = 0; i < dim; ++i)
    {
        velocity_vector[i] = parsed.velocity_field[static_cast<size_t>(i)];
    }
    mfem::VectorConstantCoefficient velocity_coefficient(velocity_vector);

    constexpr double alpha = -1.0;

    mfem::BilinearForm mass_form(&fespace);
    mass_form.AddDomainIntegrator(new mfem::MassIntegrator());

    mfem::BilinearForm advection_form(&fespace);
    advection_form.AddDomainIntegrator(new mfem::ConvectionIntegrator(velocity_coefficient, alpha));
    advection_form.AddInteriorFaceIntegrator(new mfem::NonconservativeDGTraceIntegrator(velocity_coefficient, alpha));
    advection_form.AddBdrFaceIntegrator(new mfem::NonconservativeDGTraceIntegrator(velocity_coefficient, alpha));

    mass_form.Assemble();
    mass_form.Finalize();
    advection_form.Assemble(0);
    advection_form.Finalize(0);

    mfem::SparseMatrix mass_matrix(mass_form.SpMat());
    mfem::SparseMatrix advection_matrix(advection_form.SpMat());

    mfem::Vector boundary_rhs(fespace.GetVSize());
    boundary_rhs = 0.0;
    if (max_boundary_attribute > 0 && !parsed.inflow_boundaries.empty())
    {
        mfem::Vector inflow_values(max_boundary_attribute);
        inflow_values = 0.0;
        mfem::Array<int> inflow_marker(max_boundary_attribute);
        inflow_marker = 0;

        for (const InflowBoundary &inflow : parsed.inflow_boundaries)
        {
            inflow_values[inflow.attribute - 1] = inflow.value;
            inflow_marker[inflow.attribute - 1] = 1;
        }

        mfem::PWConstCoefficient inflow_coefficient(inflow_values);
        mfem::LinearForm boundary_form(&fespace);
        boundary_form.AddBdrFaceIntegrator(
            new mfem::BoundaryFlowIntegrator(inflow_coefficient, velocity_coefficient, alpha),
            inflow_marker
        );
        boundary_form.Assemble();
        if (boundary_form.Size() == boundary_rhs.Size())
        {
            boundary_rhs = boundary_form;
        }
    }

    StepFunctionCoefficient initial_condition(
        parsed.initial_condition.center,
        parsed.initial_condition.radius,
        parsed.initial_condition.value
    );

    mfem::GridFunction solution(&fespace);
    solution.ProjectCoefficient(initial_condition);

    DGSolverOperator evolution(mass_matrix, advection_matrix, boundary_rhs);
    mfem::RK4Solver ode_solver;
    ode_solver.Init(evolution);

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
    paraview.RegisterField("concentration", &solution);

    auto save_step = [&](int step, double time) {
        paraview.SetCycle(step);
        paraview.SetTime(time);
        paraview.Save();
    };

    double time = 0.0;
    int step = 0;
    save_step(step, time);

    while (time + 1.0e-12 < parsed.t_final)
    {
        mfem::real_t step_dt = std::min(parsed.dt, parsed.t_final - time);
        ode_solver.Step(solution, time, step_dt);
        ++step;

        if (step % parsed.output_interval_steps == 0 || time + 1.0e-12 >= parsed.t_final)
        {
            save_step(step, time);
        }
    }

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# advection field written to " << collection_name << ".pvd\n";

    mfem::Vector du_dt(solution.Size());
    evolution.Mult(solution, du_dt);

    mfem::Vector mass_solution(solution.Size());
    mass_matrix.Mult(solution, mass_solution);

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(solution, mass_solution);
    summary.iterations = step;
    summary.error_norm = du_dt.Norml2();
    summary.dimension = dim;
    return summary;
}
} // namespace autosage
