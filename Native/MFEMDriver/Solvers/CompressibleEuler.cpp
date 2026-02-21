// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "CompressibleEuler.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
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

mfem::Vector conservative_state(
    double density,
    double velocity_x,
    double pressure,
    int dim,
    double gamma)
{
    mfem::Vector state(dim + 2);
    state = 0.0;

    const double rho = density;
    const double vx = velocity_x;
    const double kinetic = 0.5 * rho * vx * vx;
    const double internal = pressure / (gamma - 1.0);

    state[0] = rho;
    state[1] = rho * vx;
    state[dim + 1] = internal + kinetic;
    return state;
}

class ShockTubeInitialConditionCoefficient final : public mfem::VectorCoefficient
{
public:
    ShockTubeInitialConditionCoefficient(
        const mfem::Vector &left_state,
        const mfem::Vector &right_state,
        double split_position)
        : mfem::VectorCoefficient(left_state.Size()),
          left_state_(left_state),
          right_state_(right_state),
          split_position_(split_position)
    {
    }

    void Eval(mfem::Vector &state, mfem::ElementTransformation &transformation, const mfem::IntegrationPoint &ip) override
    {
        mfem::Vector position;
        transformation.Transform(ip, position);
        if (position.Size() == 0 || position[0] <= split_position_)
        {
            state = left_state_;
        }
        else
        {
            state = right_state_;
        }
    }

private:
    mfem::Vector left_state_;
    mfem::Vector right_state_;
    double split_position_;
};

class ConstantEulerBoundaryStateCoefficient final : public mfem::VectorCoefficient
{
public:
    explicit ConstantEulerBoundaryStateCoefficient(const mfem::Vector &state)
        : mfem::VectorCoefficient(state.Size()),
          state_(state)
    {
    }

    void Eval(mfem::Vector &state, mfem::ElementTransformation &transformation, const mfem::IntegrationPoint &ip) override
    {
        (void)transformation;
        (void)ip;
        state = state_;
    }

private:
    mfem::Vector state_;
};

class DGEulerOperator final : public mfem::TimeDependentOperator
{
public:
    DGEulerOperator(
        mfem::FiniteElementSpace &vfes,
        double specific_heat_ratio,
        mfem::Array<int> slip_wall_marker,
        mfem::VectorCoefficient *slip_wall_state)
        : mfem::TimeDependentOperator(vfes.GetTrueVSize()),
          vfes_(vfes),
          num_equations_(vfes.GetVDim()),
          slip_wall_marker_(slip_wall_marker),
          z_(height)
    {
        if (num_equations_ < 3)
        {
            throw std::runtime_error("Compressible Euler requires at least 1D (num_equations >= 3).");
        }

        const int dim = vfes_.GetMesh()->Dimension();
        flux_function_ = std::make_unique<mfem::EulerFlux>(dim, specific_heat_ratio);
        numerical_flux_ = std::make_unique<mfem::RusanovFlux>(*flux_function_);
        form_integrator_ = std::make_unique<mfem::HyperbolicFormIntegrator>(*numerical_flux_, 1);

        nonlinear_form_ = std::make_unique<mfem::NonlinearForm>(&vfes_);
        nonlinear_form_->AddDomainIntegrator(form_integrator_.get());
        nonlinear_form_->AddInteriorFaceIntegrator(form_integrator_.get());

        if (slip_wall_state != nullptr && slip_wall_marker_.Size() > 0)
        {
            bdr_integrator_ = std::make_unique<mfem::BdrHyperbolicDirichletIntegrator>(
                *numerical_flux_,
                *slip_wall_state,
                1
            );
            nonlinear_form_->AddBdrFaceIntegrator(bdr_integrator_.get(), slip_wall_marker_);
        }
        nonlinear_form_->UseExternalIntegrators();

        ComputeInverseMass();
    }

    void Mult(const mfem::Vector &x, mfem::Vector &y) const override
    {
        form_integrator_->ResetMaxCharSpeed();
        if (bdr_integrator_)
        {
            bdr_integrator_->ResetMaxCharSpeed();
        }

        nonlinear_form_->Mult(x, z_);

        mfem::Vector zval;
        mfem::DenseMatrix current_zmat;
        mfem::DenseMatrix current_ymat;
        mfem::Array<int> vdofs;
        for (int i = 0; i < vfes_.GetNE(); ++i)
        {
            const int dof = vfes_.GetFE(i)->GetDof();
            vfes_.GetElementVDofs(i, vdofs);
            z_.GetSubVector(vdofs, zval);
            current_zmat.UseExternalData(zval.GetData(), dof, num_equations_);
            current_ymat.SetSize(dof, num_equations_);
            mfem::Mult(inverse_mass_[i], current_zmat, current_ymat);
            y.SetSubVector(vdofs, current_ymat.GetData());
        }

        max_char_speed_ = form_integrator_->GetMaxCharSpeed();
        if (bdr_integrator_)
        {
            max_char_speed_ = std::max(max_char_speed_, bdr_integrator_->GetMaxCharSpeed());
        }
    }

    double MaxCharSpeed() const
    {
        return max_char_speed_;
    }

private:
    void ComputeInverseMass()
    {
        mfem::InverseIntegrator inv_mass(new mfem::MassIntegrator());
        inverse_mass_.resize(vfes_.GetNE());
        for (int i = 0; i < vfes_.GetNE(); ++i)
        {
            const int dof = vfes_.GetFE(i)->GetDof();
            inverse_mass_[i].SetSize(dof);
            inv_mass.AssembleElementMatrix(
                *vfes_.GetFE(i),
                *vfes_.GetElementTransformation(i),
                inverse_mass_[i]
            );
        }
    }

    mfem::FiniteElementSpace &vfes_;
    int num_equations_;
    std::vector<mfem::DenseMatrix> inverse_mass_;
    mfem::Array<int> slip_wall_marker_;

    std::unique_ptr<mfem::EulerFlux> flux_function_;
    std::unique_ptr<mfem::RusanovFlux> numerical_flux_;
    std::unique_ptr<mfem::HyperbolicFormIntegrator> form_integrator_;
    std::unique_ptr<mfem::BdrHyperbolicDirichletIntegrator> bdr_integrator_;
    std::unique_ptr<mfem::NonlinearForm> nonlinear_form_;

    mutable mfem::Vector z_;
    mutable double max_char_speed_ = 0.0;
};
} // namespace

namespace autosage
{
const char *CompressibleEulerSolver::Name() const
{
    return "CompressibleEuler";
}

CompressibleEulerSolver::CompressibleEulerConfig CompressibleEulerSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    CompressibleEulerConfig parsed;
    parsed.specific_heat_ratio = require_positive_number(config, "specific_heat_ratio");
    if (parsed.specific_heat_ratio <= 1.0)
    {
        throw std::runtime_error("config.specific_heat_ratio must be > 1.");
    }
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

    if (!config.contains("initial_condition") || !config["initial_condition"].is_object())
    {
        throw std::runtime_error("config.initial_condition is required and must be an object.");
    }
    const json &initial_condition = config["initial_condition"];
    const std::string initial_type = to_lower(initial_condition.value("type", ""));
    if (initial_type != "shock_tube" && initial_type != "shock-tube" && initial_type != "shocktube")
    {
        throw std::runtime_error("config.initial_condition.type must be shock_tube.");
    }

    auto parse_primitive = [](const json &state_value, const char *field_name) {
        if (!state_value.is_array())
        {
            throw std::runtime_error(std::string("config.initial_condition.") + field_name + " must be an array.");
        }
        if (state_value.size() < 3)
        {
            throw std::runtime_error(std::string("config.initial_condition.") + field_name + " must contain [density, velocity_x, pressure].");
        }
        for (const auto &component : state_value)
        {
            if (!component.is_number())
            {
                throw std::runtime_error(std::string("config.initial_condition.") + field_name + " entries must be numeric.");
            }
        }

        PrimitiveState primitive;
        primitive.density = state_value[0].get<double>();
        primitive.velocity_x = state_value[1].get<double>();
        primitive.pressure = state_value[2].get<double>();
        if (!(primitive.density > 0.0))
        {
            throw std::runtime_error(std::string("config.initial_condition.") + field_name + " density must be > 0.");
        }
        if (!(primitive.pressure > 0.0))
        {
            throw std::runtime_error(std::string("config.initial_condition.") + field_name + " pressure must be > 0.");
        }
        return primitive;
    };

    if (!initial_condition.contains("left_state"))
    {
        throw std::runtime_error("config.initial_condition.left_state is required.");
    }
    if (!initial_condition.contains("right_state"))
    {
        throw std::runtime_error("config.initial_condition.right_state is required.");
    }

    parsed.left_state = parse_primitive(initial_condition["left_state"], "left_state");
    parsed.right_state = parse_primitive(initial_condition["right_state"], "right_state");

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }
    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.slip_wall_marker.assign(boundary_slots, 0);
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
        if (type == "slip_wall" || type == "slip-wall" || type == "slipwall")
        {
            parsed.slip_wall_marker[attribute - 1] = 1;
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be slip_wall.");
    }

    return parsed;
}

SolveSummary CompressibleEulerSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    if (dim <= 0)
    {
        throw std::runtime_error("CompressibleEuler solver requires a positive mesh dimension.");
    }

    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const CompressibleEulerConfig parsed = ParseConfig(config, max_boundary_attribute);

    const int num_equations = dim + 2;
    mfem::L2_FECollection fec(parsed.order, dim);
    mfem::FiniteElementSpace scalar_fespace(&mesh, &fec);
    mfem::FiniteElementSpace momentum_fespace(&mesh, &fec, dim, mfem::Ordering::byNODES);
    mfem::FiniteElementSpace vector_fespace(&mesh, &fec, num_equations, mfem::Ordering::byNODES);

    mfem::Vector left_conservative = conservative_state(
        parsed.left_state.density,
        parsed.left_state.velocity_x,
        parsed.left_state.pressure,
        dim,
        parsed.specific_heat_ratio
    );
    mfem::Vector right_conservative = conservative_state(
        parsed.right_state.density,
        parsed.right_state.velocity_x,
        parsed.right_state.pressure,
        dim,
        parsed.specific_heat_ratio
    );

    double x_min = std::numeric_limits<double>::infinity();
    double x_max = -std::numeric_limits<double>::infinity();
    for (int i = 0; i < mesh.GetNV(); ++i)
    {
        const double *vertex = mesh.GetVertex(i);
        x_min = std::min(x_min, vertex[0]);
        x_max = std::max(x_max, vertex[0]);
    }
    if (!std::isfinite(x_min) || !std::isfinite(x_max))
    {
        throw std::runtime_error("Failed to determine mesh x-extents for shock_tube initialization.");
    }
    const double split_position = 0.5 * (x_min + x_max);

    ShockTubeInitialConditionCoefficient initial_condition(left_conservative, right_conservative, split_position);
    mfem::GridFunction state(&vector_fespace);
    state.ProjectCoefficient(initial_condition);

    mfem::Array<int> slip_wall_marker(max_boundary_attribute);
    slip_wall_marker = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        slip_wall_marker[i] = parsed.slip_wall_marker[i];
    }

    const mfem::Vector boundary_state = conservative_state(
        0.5 * (parsed.left_state.density + parsed.right_state.density),
        0.0,
        0.5 * (parsed.left_state.pressure + parsed.right_state.pressure),
        dim,
        parsed.specific_heat_ratio
    );
    bool has_slip_wall = false;
    for (int i = 0; i < slip_wall_marker.Size(); ++i)
    {
        if (slip_wall_marker[i] != 0)
        {
            has_slip_wall = true;
            break;
        }
    }
    ConstantEulerBoundaryStateCoefficient slip_wall_state(boundary_state);

    DGEulerOperator euler_operator(
        vector_fespace,
        parsed.specific_heat_ratio,
        slip_wall_marker,
        has_slip_wall ? &slip_wall_state : nullptr
    );

    mfem::RK4Solver ode_solver;
    ode_solver.Init(euler_operator);

    const int scalar_ndofs = scalar_fespace.GetNDofs();
    mfem::GridFunction density(&scalar_fespace, state.GetData() + 0 * scalar_ndofs);
    mfem::GridFunction momentum(&momentum_fespace, state.GetData() + scalar_ndofs);
    mfem::GridFunction total_energy(&scalar_fespace, state.GetData() + (num_equations - 1) * scalar_ndofs);
    mfem::GridFunction pressure(&scalar_fespace);

    auto update_pressure = [&]() {
        const double *state_data = state.GetData();
        for (int i = 0; i < scalar_ndofs; ++i)
        {
            const double rho = std::max(state_data[i], 1.0e-12);
            double momentum_sq = 0.0;
            for (int d = 0; d < dim; ++d)
            {
                const double m = state_data[(1 + d) * scalar_ndofs + i];
                momentum_sq += m * m;
            }
            const double rhoE = state_data[(num_equations - 1) * scalar_ndofs + i];
            const double p = (parsed.specific_heat_ratio - 1.0) * (rhoE - 0.5 * momentum_sq / rho);
            pressure(i) = std::max(p, 0.0);
        }
    };

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
    paraview.RegisterField("density", &density);
    paraview.RegisterField("momentum", &momentum);
    paraview.RegisterField("total_energy", &total_energy);
    paraview.RegisterField("pressure", &pressure);

    auto save_step = [&](int step, double time) {
        update_pressure();
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
        ode_solver.Step(state, time, step_dt);
        ++step;

        if (step % parsed.output_interval_steps == 0 || time + 1.0e-12 >= parsed.t_final)
        {
            save_step(step, time);
        }
    }

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# compressible Euler fields written to " << collection_name << ".pvd\n";

    mfem::ConstantCoefficient one(1.0);
    mfem::LinearForm domain_integral(&scalar_fespace);
    domain_integral.AddDomainIntegrator(new mfem::DomainLFIntegrator(one));
    domain_integral.Assemble();

    mfem::Vector rhs(state.Size());
    euler_operator.Mult(state, rhs);

    SolveSummary summary;
    summary.energy = mfem::InnerProduct(total_energy, domain_integral);
    summary.iterations = step;
    summary.error_norm = rhs.Norml2();
    summary.dimension = dim;
    return summary;
}
} // namespace autosage
