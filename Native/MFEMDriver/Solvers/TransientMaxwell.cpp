// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "TransientMaxwell.hpp"

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

std::vector<double> parse_vector_field(const json &object, const char *field_name, int dim)
{
    if (!object.contains(field_name) || !object[field_name].is_array())
    {
        throw std::runtime_error(std::string(field_name) + " is required and must be an array.");
    }
    const json &array = object[field_name];
    if (array.empty())
    {
        throw std::runtime_error(std::string(field_name) + " must not be empty.");
    }

    std::vector<double> values;
    values.reserve(array.size());
    for (const auto &entry : array)
    {
        if (!entry.is_number())
        {
            throw std::runtime_error(std::string(field_name) + " entries must be numeric.");
        }
        values.push_back(entry.get<double>());
    }
    if (static_cast<int>(values.size()) < dim)
    {
        values.resize(dim, 0.0);
    }
    if (static_cast<int>(values.size()) > dim)
    {
        values.resize(dim);
    }
    return values;
}

double l2_norm(const std::vector<double> &values)
{
    double sum = 0.0;
    for (double value : values)
    {
        sum += value * value;
    }
    return std::sqrt(sum);
}

#if defined(MFEM_USE_MPI)
class DipolePulseCoefficient final : public mfem::VectorCoefficient
{
public:
    DipolePulseCoefficient(const std::vector<double> &center, const std::vector<double> &polarization)
        : mfem::VectorCoefficient(static_cast<int>(polarization.size())),
          center_(center),
          polarization_(polarization)
    {
    }

    void Eval(
        mfem::Vector &value,
        mfem::ElementTransformation &transformation,
        const mfem::IntegrationPoint &ip) override
    {
        mfem::Vector point;
        transformation.Transform(ip, point);

        double radius_sq = 0.0;
        const int count = std::min(point.Size(), static_cast<int>(center_.size()));
        for (int i = 0; i < count; ++i)
        {
            const double delta = point[i] - center_[static_cast<size_t>(i)];
            radius_sq += delta * delta;
        }
        const double envelope = std::exp(-40.0 * radius_sq);

        value.SetSize(vdim);
        value = 0.0;
        for (int i = 0; i < vdim; ++i)
        {
            value[i] = envelope * polarization_[static_cast<size_t>(i)];
        }
    }

private:
    std::vector<double> center_;
    std::vector<double> polarization_;
};

class MaxwellOperator final : public mfem::TimeDependentOperator
{
public:
    MaxwellOperator(
        mfem::ParFiniteElementSpace &fespace,
        const mfem::Array<int> &ess_tdof_list,
        double permittivity,
        double conductivity,
        double permeability)
        : mfem::TimeDependentOperator(2 * fespace.GetTrueVSize(), 0.0),
          fespace_(fespace),
          ess_tdof_list_(ess_tdof_list),
          mass_solver_(fespace.GetComm()),
          implicit_solver_(fespace.GetComm()),
          z_(fespace.GetTrueVSize()),
          rhs_(fespace.GetTrueVSize())
    {
        const mfem::real_t rel_tol = 1.0e-8;

        mfem::ConstantCoefficient epsilon_coeff(permittivity);
        mass_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace_);
        mass_form_->AddDomainIntegrator(new mfem::VectorFEMassIntegrator(epsilon_coeff));
        mass_form_->Assemble(0);
        mass_form_->FormSystemMatrix(ess_tdof_list_, mass_matrix_);

        mfem::ConstantCoefficient sigma_coeff(conductivity);
        damping_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace_);
        damping_form_->AddDomainIntegrator(new mfem::VectorFEMassIntegrator(sigma_coeff));
        damping_form_->Assemble(0);
        damping_form_->FormSystemMatrix(ess_tdof_list_, damping_matrix_);

        mfem::ConstantCoefficient mu_inverse_coeff(1.0 / permeability);
        stiffness_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace_);
        stiffness_form_->AddDomainIntegrator(new mfem::CurlCurlIntegrator(mu_inverse_coeff));
        stiffness_form_->Assemble(0);
        stiffness_form_->FormSystemMatrix(ess_tdof_list_, stiffness_matrix_);

        mass_prec_.SetType(mfem::HypreSmoother::Jacobi);
        mass_solver_.iterative_mode = false;
        mass_solver_.SetRelTol(rel_tol);
        mass_solver_.SetAbsTol(0.0);
        mass_solver_.SetMaxIter(500);
        mass_solver_.SetPrintLevel(0);
        mass_solver_.SetPreconditioner(mass_prec_);
        mass_solver_.SetOperator(mass_matrix_);

        implicit_solver_.iterative_mode = false;
        implicit_solver_.SetTol(rel_tol);
        implicit_solver_.SetAbsTol(0.0);
        implicit_solver_.SetMaxIter(1'000);
        implicit_solver_.SetPrintLevel(0);
        implicit_solver_.SetLogging(0);
    }

    ~MaxwellOperator() override
    {
        delete implicit_matrix_;
    }

    void Mult(const mfem::Vector &state, mfem::Vector &derivative) const override
    {
        const int sc = height / 2;
        mfem::Vector v(state.GetData() + 0, sc);
        mfem::Vector e(state.GetData() + sc, sc);
        mfem::Vector dv_dt(derivative.GetData() + 0, sc);
        mfem::Vector de_dt(derivative.GetData() + sc, sc);

        damping_matrix_.Mult(v, rhs_);
        stiffness_matrix_.Mult(e, z_);
        rhs_ += z_;
        rhs_.Neg();
        ZeroEssentialEntries(rhs_);

        mass_solver_.Mult(rhs_, dv_dt);
        total_mass_iterations_ += mass_solver_.GetNumIterations();
        ZeroEssentialEntries(dv_dt);

        de_dt = v;
        ZeroEssentialEntries(de_dt);
    }

    void ImplicitSolve(const mfem::real_t dt, const mfem::Vector &state, mfem::Vector &kstate) override
    {
        const int sc = height / 2;
        mfem::Vector v(state.GetData() + 0, sc);
        mfem::Vector e(state.GetData() + sc, sc);
        mfem::Vector kv(kstate.GetData() + 0, sc);
        mfem::Vector ke(kstate.GetData() + sc, sc);

        EnsureImplicitSystem(dt);

        damping_matrix_.Mult(v, rhs_);
        stiffness_matrix_.Mult(e, z_);
        rhs_ += z_;
        stiffness_matrix_.Mult(v, z_);
        rhs_.Add(dt, z_);
        rhs_.Neg();
        ZeroEssentialEntries(rhs_);

        mfem::HypreParVector rhs_hypre(
            implicit_matrix_->GetComm(),
            implicit_matrix_->GetGlobalNumRows(),
            rhs_,
            0,
            implicit_matrix_->GetRowStarts()
        );
        mfem::HypreParVector kv_hypre(
            implicit_matrix_->GetComm(),
            implicit_matrix_->GetGlobalNumRows(),
            kv,
            0,
            implicit_matrix_->GetRowStarts()
        );
        kv_hypre = 0.0;
        implicit_solver_.Mult(rhs_hypre, kv_hypre);
        int num_iterations = 0;
        implicit_solver_.GetNumIterations(num_iterations);
        total_implicit_iterations_ += num_iterations;
        ZeroEssentialEntries(kv);

        ke = v;
        ke.Add(dt, kv);
        ZeroEssentialEntries(ke);
    }

    void ComputeResidualNorm(const mfem::Vector &state, mfem::real_t &norm_out) const
    {
        const int sc = height / 2;
        mfem::Vector v(state.GetData() + 0, sc);
        mfem::Vector e(state.GetData() + sc, sc);

        mfem::Vector dv_dt(sc);
        mfem::Vector derivative(height);
        Mult(state, derivative);
        dv_dt = mfem::Vector(derivative.GetData() + 0, sc);

        mass_matrix_.Mult(dv_dt, rhs_);
        damping_matrix_.AddMult(v, rhs_);
        stiffness_matrix_.AddMult(e, rhs_);
        ZeroEssentialEntries(rhs_);
        norm_out = std::sqrt(mfem::InnerProduct(fespace_.GetComm(), rhs_, rhs_));
    }

    void ApplyEssentialBCs(mfem::Vector &state) const
    {
        const int sc = height / 2;
        mfem::Vector v(state.GetData() + 0, sc);
        mfem::Vector e(state.GetData() + sc, sc);
        ZeroEssentialEntries(v);
        ZeroEssentialEntries(e);
    }

    const mfem::HypreParMatrix &MassMatrix() const
    {
        return mass_matrix_;
    }

    const mfem::HypreParMatrix &StiffnessMatrix() const
    {
        return stiffness_matrix_;
    }

    int TotalMassIterations() const
    {
        return total_mass_iterations_;
    }

    int TotalImplicitIterations() const
    {
        return total_implicit_iterations_;
    }

private:
    void EnsureImplicitSystem(mfem::real_t dt)
    {
        if (implicit_matrix_ != nullptr && std::abs(dt - current_dt_) <= 1.0e-15)
        {
            return;
        }

        delete implicit_matrix_;
        auto *temp = mfem::Add(1.0, mass_matrix_, dt, damping_matrix_);
        implicit_matrix_ = mfem::Add(1.0, *temp, dt * dt, stiffness_matrix_);
        delete temp;
        current_dt_ = dt;

        if (ess_tdof_list_.Size() > 0)
        {
            implicit_matrix_->EliminateBC(ess_tdof_list_, mfem::Operator::DIAG_ONE);
        }

        implicit_prec_ = std::make_unique<mfem::HypreAMS>(*implicit_matrix_, &fespace_);
        implicit_prec_->SetPrintLevel(0);

        implicit_solver_.SetPreconditioner(*implicit_prec_);
        implicit_solver_.SetOperator(*implicit_matrix_);
    }

    void ZeroEssentialEntries(mfem::Vector &vector) const
    {
        for (int i = 0; i < ess_tdof_list_.Size(); ++i)
        {
            const int tdof = ess_tdof_list_[i];
            if (tdof >= 0 && tdof < vector.Size())
            {
                vector[tdof] = 0.0;
            }
        }
    }

    mfem::ParFiniteElementSpace &fespace_;
    mfem::Array<int> ess_tdof_list_;

    std::unique_ptr<mfem::ParBilinearForm> mass_form_;
    std::unique_ptr<mfem::ParBilinearForm> damping_form_;
    std::unique_ptr<mfem::ParBilinearForm> stiffness_form_;

    mfem::HypreParMatrix mass_matrix_;
    mfem::HypreParMatrix damping_matrix_;
    mfem::HypreParMatrix stiffness_matrix_;
    mfem::HypreParMatrix *implicit_matrix_ = nullptr;
    mfem::real_t current_dt_ = -1.0;

    mutable mfem::CGSolver mass_solver_;
    mutable mfem::HypreSmoother mass_prec_;

    mfem::HyprePCG implicit_solver_;
    std::unique_ptr<mfem::HypreAMS> implicit_prec_;

    mutable mfem::Vector z_;
    mutable mfem::Vector rhs_;

    mutable int total_mass_iterations_ = 0;
    int total_implicit_iterations_ = 0;
};
#endif
} // namespace

namespace autosage
{
const char *TransientMaxwellSolver::Name() const
{
    return "TransientMaxwell";
}

TransientMaxwellSolver::TransientMaxwellConfig TransientMaxwellSolver::ParseConfig(
    const json &config,
    int space_dimension,
    int max_boundary_attribute) const
{
    TransientMaxwellConfig parsed;
    parsed.permittivity = require_positive_number(config, "permittivity");
    parsed.permeability = require_positive_number(config, "permeability");
    if (!config.contains("conductivity") || !config["conductivity"].is_number())
    {
        throw std::runtime_error("config.conductivity is required and must be numeric.");
    }
    parsed.conductivity = config["conductivity"].get<double>();
    if (parsed.conductivity < 0.0)
    {
        throw std::runtime_error("config.conductivity must be >= 0.");
    }
    parsed.dt = require_positive_number(config, "dt");
    parsed.t_final = require_positive_number(config, "t_final");
    parsed.order = int_or_default(config, "order", parsed.order);
    parsed.output_interval_steps = int_or_default(config, "output_interval_steps", parsed.output_interval_steps);
    if (parsed.order < 1)
    {
        throw std::runtime_error("config.order must be >= 1.");
    }
    if (parsed.output_interval_steps <= 0)
    {
        throw std::runtime_error("config.output_interval_steps must be > 0.");
    }

    if (!config.contains("initial_condition") || !config["initial_condition"].is_object())
    {
        throw std::runtime_error("config.initial_condition is required and must be an object.");
    }
    const json &initial = config["initial_condition"];
    const std::string type = to_lower(initial.value("type", ""));
    if (type != "dipole_pulse" && type != "dipole-pulse" && type != "dipolepulse")
    {
        throw std::runtime_error("config.initial_condition.type must be dipole_pulse.");
    }
    parsed.initial_condition.center = parse_vector_field(initial, "center", space_dimension);
    parsed.initial_condition.polarization = parse_vector_field(initial, "polarization", space_dimension);
    if (!(l2_norm(parsed.initial_condition.polarization) > 0.0))
    {
        throw std::runtime_error("config.initial_condition.polarization must have non-zero magnitude.");
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs is required and must be an array.");
    }
    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.perfect_conductor_marker.assign(boundary_slots, 0);
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
        const std::string bc_type = to_lower(bc.value("type", ""));
        if (bc_type == "perfect_conductor" || bc_type == "perfect-conductor" || bc_type == "perfectconductor")
        {
            parsed.perfect_conductor_marker[attribute - 1] = 1;
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be perfect_conductor.");
    }

    if (boundary_slots > 0)
    {
        const bool has_perfect_conductor = std::any_of(
            parsed.perfect_conductor_marker.begin(),
            parsed.perfect_conductor_marker.end(),
            [](int marker) { return marker != 0; }
        );
        if (!has_perfect_conductor)
        {
            throw std::runtime_error("config.bcs must include at least one perfect_conductor boundary condition.");
        }
    }

    return parsed;
}

SolveSummary TransientMaxwellSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    const int space_dimension = pmesh.SpaceDimension();
    const TransientMaxwellConfig parsed = ParseConfig(config, space_dimension, max_boundary_attribute);

    mfem::ND_FECollection fec(parsed.order, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.perfect_conductor_marker[static_cast<size_t>(i)];
    }
    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    mfem::ParGridFunction electric_field(&fespace);
    DipolePulseCoefficient initial_coeff(parsed.initial_condition.center, parsed.initial_condition.polarization);
    electric_field.ProjectCoefficient(initial_coeff);

    mfem::ParGridFunction electric_rate(&fespace);
    electric_rate = 0.0;

    const int true_size = fespace.GetTrueVSize();
    mfem::Vector electric_true(true_size);
    mfem::Vector rate_true(true_size);
    electric_field.GetTrueDofs(electric_true);
    electric_rate.GetTrueDofs(rate_true);
    if (ess_tdof_list.Size() > 0)
    {
        electric_true.SetSubVector(ess_tdof_list, 0.0);
        rate_true.SetSubVector(ess_tdof_list, 0.0);
    }

    mfem::Vector state(2 * true_size);
    {
        mfem::Vector state_v(state.GetData() + 0, true_size);
        mfem::Vector state_e(state.GetData() + true_size, true_size);
        state_v = rate_true;
        state_e = electric_true;
    }

    MaxwellOperator operator_impl(
        fespace,
        ess_tdof_list,
        parsed.permittivity,
        parsed.conductivity,
        parsed.permeability
    );
    operator_impl.ApplyEssentialBCs(state);

    mfem::SDIRK34Solver ode_solver;
    ode_solver.Init(operator_impl);

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
    paraview.RegisterField("electric_field", &electric_field);
    paraview.RegisterField("electric_rate", &electric_rate);

    auto save_step = [&](int step, double time) {
        mfem::Vector state_v(state.GetData() + 0, true_size);
        mfem::Vector state_e(state.GetData() + true_size, true_size);
        electric_rate.SetFromTrueDofs(state_v);
        electric_field.SetFromTrueDofs(state_e);
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
        operator_impl.ApplyEssentialBCs(state);
        ++step;
        if (step % parsed.output_interval_steps == 0 || time + 1.0e-12 >= parsed.t_final)
        {
            save_step(step, time);
        }
    }

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# transient electromagnetic fields written to " << collection_name << ".pvd\n";

    mfem::Vector final_rate(state.GetData() + 0, true_size);
    mfem::Vector final_field(state.GetData() + true_size, true_size);

    mfem::Vector mass_rate(true_size);
    operator_impl.MassMatrix().Mult(final_rate, mass_rate);
    mfem::Vector stiffness_field(true_size);
    operator_impl.StiffnessMatrix().Mult(final_field, stiffness_field);

    mfem::real_t residual_norm = 0.0;
    operator_impl.ComputeResidualNorm(state, residual_norm);

    const double kinetic_energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), final_rate, mass_rate);
    const double potential_energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), final_field, stiffness_field);

    SolveSummary summary;
    summary.energy = kinetic_energy + potential_energy;
    summary.iterations = operator_impl.TotalMassIterations() + operator_impl.TotalImplicitIterations();
    summary.error_norm = residual_norm;
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("TransientMaxwell solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
