// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "Elastodynamics.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace
{
constexpr double kTwoPi = 6.283185307179586476925286766559;

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

double require_number(const json &object, const char *field_name)
{
    if (!object.contains(field_name) || !object[field_name].is_number())
    {
        throw std::runtime_error(std::string("config.") + field_name + " is required and must be numeric.");
    }
    return object[field_name].get<double>();
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

std::vector<double> parse_vector_value(
    const json &object,
    const char *field_name,
    int dim)
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

    std::vector<double> parsed;
    parsed.reserve(array.size());
    for (const auto &entry : array)
    {
        if (!entry.is_number())
        {
            throw std::runtime_error(std::string(field_name) + " entries must be numeric.");
        }
        parsed.push_back(entry.get<double>());
    }
    if (static_cast<int>(parsed.size()) < dim)
    {
        parsed.resize(dim, 0.0);
    }
    if (static_cast<int>(parsed.size()) > dim)
    {
        parsed.resize(dim);
    }
    return parsed;
}

std::pair<double, double> lame_from_young_poisson(double youngs_modulus, double poisson_ratio)
{
    if (youngs_modulus <= 0.0)
    {
        throw std::runtime_error("config.youngs_modulus must be > 0.");
    }
    if (poisson_ratio <= -1.0 || poisson_ratio >= 0.5)
    {
        throw std::runtime_error("config.poisson_ratio must be in (-1, 0.5).");
    }
    const double lambda = (youngs_modulus * poisson_ratio) /
                          ((1.0 + poisson_ratio) * (1.0 - 2.0 * poisson_ratio));
    const double mu = youngs_modulus / (2.0 * (1.0 + poisson_ratio));
    return {lambda, mu};
}

#if defined(MFEM_USE_MPI)
class DynamicOperator final : public mfem::TimeDependentOperator
{
public:
    struct LoadBoundary
    {
        int attribute = 0;
        std::vector<double> value;
        double frequency = 1.0;
    };

    DynamicOperator(
        mfem::ParFiniteElementSpace &fespace,
        const mfem::Array<int> &ess_tdof_list,
        int max_boundary_attribute,
        const std::vector<LoadBoundary> &load_boundaries,
        double density,
        double lambda,
        double mu)
        : mfem::TimeDependentOperator(2 * fespace.GetTrueVSize(), 0.0),
          fespace_(fespace),
          ess_tdof_list_(ess_tdof_list),
          max_boundary_attribute_(max_boundary_attribute),
          load_boundaries_(load_boundaries),
          mass_solver_(fespace.GetComm()),
          implicit_solver_(fespace.GetComm()),
          z_(fespace.GetTrueVSize()),
          rhs_(fespace.GetTrueVSize()),
          load_true_(fespace.GetTrueVSize())
    {
        const mfem::real_t rel_tol = 1.0e-8;

        mfem::ConstantCoefficient density_coeff(density);
        mass_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace_);
        mass_form_->AddDomainIntegrator(new mfem::VectorMassIntegrator(density_coeff));
        mass_form_->Assemble(0);
        mass_form_->FormSystemMatrix(ess_tdof_list_, mass_matrix_);

        mfem::ConstantCoefficient lambda_coeff(lambda);
        mfem::ConstantCoefficient mu_coeff(mu);
        stiffness_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace_);
        stiffness_form_->AddDomainIntegrator(new mfem::ElasticityIntegrator(lambda_coeff, mu_coeff));
        stiffness_form_->Assemble(0);
        stiffness_form_->FormSystemMatrix(ess_tdof_list_, stiffness_matrix_);

        mass_solver_.iterative_mode = false;
        mass_solver_.SetRelTol(rel_tol);
        mass_solver_.SetAbsTol(0.0);
        mass_solver_.SetMaxIter(500);
        mass_solver_.SetPrintLevel(0);
        mass_prec_.SetType(mfem::HypreSmoother::Jacobi);
        mass_solver_.SetPreconditioner(mass_prec_);
        mass_solver_.SetOperator(mass_matrix_);

        implicit_solver_.iterative_mode = false;
        implicit_solver_.SetRelTol(rel_tol);
        implicit_solver_.SetAbsTol(0.0);
        implicit_solver_.SetMaxIter(500);
        implicit_solver_.SetPrintLevel(0);
    }

    ~DynamicOperator() override
    {
        delete implicit_matrix_;
    }

    void Mult(const mfem::Vector &vx, mfem::Vector &dvx_dt) const override
    {
        const int sc = height / 2;
        mfem::Vector v(vx.GetData() + 0, sc);
        mfem::Vector u(vx.GetData() + sc, sc);
        mfem::Vector dv_dt(dvx_dt.GetData() + 0, sc);
        mfem::Vector du_dt(dvx_dt.GetData() + sc, sc);

        AssembleLoadVector(this->t, load_true_);
        stiffness_matrix_.Mult(u, z_);

        rhs_ = load_true_;
        rhs_ -= z_;
        ZeroEssentialEntries(rhs_);

        mass_solver_.Mult(rhs_, dv_dt);
        total_mass_iterations_ += mass_solver_.GetNumIterations();
        ZeroEssentialEntries(dv_dt);

        du_dt = v;
        ZeroEssentialEntries(du_dt);
    }

    void ImplicitSolve(const mfem::real_t dt, const mfem::Vector &vx, mfem::Vector &kvx) override
    {
        const int sc = height / 2;
        mfem::Vector v(vx.GetData() + 0, sc);
        mfem::Vector u(vx.GetData() + sc, sc);
        mfem::Vector kv(kvx.GetData() + 0, sc);
        mfem::Vector ku(kvx.GetData() + sc, sc);

        EnsureImplicitSystem(dt);
        AssembleLoadVector(this->t + dt, load_true_);

        stiffness_matrix_.Mult(u, rhs_);
        rhs_.Neg();
        rhs_ += load_true_;

        stiffness_matrix_.Mult(v, z_);
        rhs_.Add(-dt, z_);
        ZeroEssentialEntries(rhs_);

        implicit_solver_.Mult(rhs_, kv);
        total_implicit_iterations_ += implicit_solver_.GetNumIterations();
        ZeroEssentialEntries(kv);

        ku = v;
        ku.Add(dt, kv);
        ZeroEssentialEntries(ku);
    }

    void ComputeAcceleration(const mfem::Vector &u, mfem::real_t time, mfem::Vector &acceleration) const
    {
        AssembleLoadVector(time, load_true_);
        stiffness_matrix_.Mult(u, z_);
        rhs_ = load_true_;
        rhs_ -= z_;
        ZeroEssentialEntries(rhs_);
        mass_solver_.Mult(rhs_, acceleration);
        total_mass_iterations_ += mass_solver_.GetNumIterations();
        ZeroEssentialEntries(acceleration);
    }

    void ComputeLoadVector(mfem::real_t time, mfem::Vector &load_true) const
    {
        AssembleLoadVector(time, load_true);
    }

    void ApplyEssentialBCs(mfem::Vector &state) const
    {
        const int sc = height / 2;
        mfem::Vector v(state.GetData() + 0, sc);
        mfem::Vector u(state.GetData() + sc, sc);
        ZeroEssentialEntries(v);
        ZeroEssentialEntries(u);
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
        implicit_matrix_ = mfem::Add(1.0, mass_matrix_, dt * dt, stiffness_matrix_);
        current_dt_ = dt;

        if (ess_tdof_list_.Size() > 0)
        {
            implicit_matrix_->EliminateBC(ess_tdof_list_, mfem::Operator::DIAG_ONE);
        }

        implicit_prec_ = std::make_unique<mfem::HypreBoomerAMG>(*implicit_matrix_);
        implicit_prec_->SetPrintLevel(0);
        implicit_prec_->SetElasticityOptions(&fespace_);

        implicit_solver_.SetPreconditioner(*implicit_prec_);
        implicit_solver_.SetOperator(*implicit_matrix_);
    }

    void AssembleLoadVector(mfem::real_t time, mfem::Vector &load_true) const
    {
        load_true.SetSize(fespace_.GetTrueVSize());
        load_true = 0.0;

        if (load_boundaries_.empty() || max_boundary_attribute_ <= 0)
        {
            return;
        }

        mfem::ParLinearForm load_form(&fespace_);
        std::vector<std::unique_ptr<mfem::VectorConstantCoefficient>> coeffs;
        std::vector<mfem::Array<int>> markers;
        coeffs.reserve(load_boundaries_.size());
        markers.reserve(load_boundaries_.size());

        const int dim = fespace_.GetParMesh()->Dimension();
        for (const LoadBoundary &load : load_boundaries_)
        {
            const double scale = std::sin(kTwoPi * load.frequency * static_cast<double>(time));
            mfem::Vector traction(dim);
            traction = 0.0;
            for (int i = 0; i < dim; ++i)
            {
                traction[i] = scale * load.value[static_cast<size_t>(i)];
            }

            coeffs.push_back(std::make_unique<mfem::VectorConstantCoefficient>(traction));
            markers.emplace_back(max_boundary_attribute_);
            markers.back() = 0;
            markers.back()[load.attribute - 1] = 1;
            load_form.AddBoundaryIntegrator(new mfem::VectorBoundaryLFIntegrator(*coeffs.back()), markers.back());
        }

        load_form.Assemble();
        load_form.ParallelAssemble(load_true);
        ZeroEssentialEntries(load_true);
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
    int max_boundary_attribute_;
    std::vector<LoadBoundary> load_boundaries_;

    std::unique_ptr<mfem::ParBilinearForm> mass_form_;
    std::unique_ptr<mfem::ParBilinearForm> stiffness_form_;

    mfem::HypreParMatrix mass_matrix_;
    mfem::HypreParMatrix stiffness_matrix_;
    mfem::HypreParMatrix *implicit_matrix_ = nullptr;
    mfem::real_t current_dt_ = -1.0;

    mutable mfem::CGSolver mass_solver_;
    mutable mfem::HypreSmoother mass_prec_;

    mfem::CGSolver implicit_solver_;
    std::unique_ptr<mfem::HypreBoomerAMG> implicit_prec_;

    mutable mfem::Vector z_;
    mutable mfem::Vector rhs_;
    mutable mfem::Vector load_true_;

    mutable int total_mass_iterations_ = 0;
    int total_implicit_iterations_ = 0;
};
#endif
} // namespace

namespace autosage
{
const char *ElastodynamicsSolver::Name() const
{
    return "Elastodynamics";
}

ElastodynamicsSolver::ElastodynamicsConfig ElastodynamicsSolver::ParseConfig(
    const json &config,
    int dim,
    int max_boundary_attribute) const
{
    ElastodynamicsConfig parsed;
    parsed.density = require_positive_number(config, "density");
    parsed.youngs_modulus = require_positive_number(config, "youngs_modulus");
    parsed.poisson_ratio = require_number(config, "poisson_ratio");
    parsed.dt = require_positive_number(config, "dt");
    parsed.t_final = require_positive_number(config, "t_final");
    parsed.order = int_or_default(config, "order", parsed.order);
    parsed.output_interval_steps = int_or_default(config, "output_interval_steps", parsed.output_interval_steps);

    if (parsed.poisson_ratio <= -1.0 || parsed.poisson_ratio >= 0.5)
    {
        throw std::runtime_error("config.poisson_ratio must be in (-1, 0.5).");
    }
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
    const json &initial_condition = config["initial_condition"];
    parsed.initial_condition.displacement = parse_vector_value(
        initial_condition,
        "displacement",
        dim
    );
    parsed.initial_condition.velocity = parse_vector_value(
        initial_condition,
        "velocity",
        dim
    );

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs is required and must be an array.");
    }
    if (max_boundary_attribute == 0 && !config["bcs"].empty())
    {
        throw std::runtime_error("Mesh has no boundary attributes but config.bcs was provided.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.fixed_boundary_marker.assign(boundary_slots, 0);

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
        if (type == "fixed")
        {
            parsed.fixed_boundary_marker[attribute - 1] = 1;
            has_fixed_boundary = true;
            continue;
        }
        if (type == "time_varying_load" || type == "time-varying-load" || type == "timevaryingload")
        {
            TimeVaryingLoadBoundary load;
            load.attribute = attribute;
            load.value = parse_vector_value(bc, "value", dim);
            if (!bc.contains("frequency") || !bc["frequency"].is_number())
            {
                throw std::runtime_error("config.bcs[].frequency is required for time_varying_load.");
            }
            load.frequency = bc["frequency"].get<double>();
            if (!(load.frequency > 0.0))
            {
                throw std::runtime_error("config.bcs[].frequency must be > 0 for time_varying_load.");
            }
            parsed.loads.push_back(std::move(load));
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be fixed or time_varying_load.");
    }

    if (!has_fixed_boundary)
    {
        throw std::runtime_error("config.bcs must include at least one fixed boundary.");
    }

    return parsed;
}

SolveSummary ElastodynamicsSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    if (dim <= 0)
    {
        throw std::runtime_error("Elastodynamics solver requires a positive mesh dimension.");
    }

    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const ElastodynamicsConfig parsed = ParseConfig(config, dim, max_boundary_attribute);
    const auto [lambda, mu] = lame_from_young_poisson(parsed.youngs_modulus, parsed.poisson_ratio);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(parsed.order, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec, dim);

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.fixed_boundary_marker[static_cast<size_t>(i)];
    }

    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    std::vector<DynamicOperator::LoadBoundary> load_boundaries;
    load_boundaries.reserve(parsed.loads.size());
    for (const TimeVaryingLoadBoundary &load : parsed.loads)
    {
        DynamicOperator::LoadBoundary mapped;
        mapped.attribute = load.attribute;
        mapped.value = load.value;
        mapped.frequency = load.frequency;
        load_boundaries.push_back(std::move(mapped));
    }

    DynamicOperator dynamic_operator(
        fespace,
        ess_tdof_list,
        max_boundary_attribute,
        load_boundaries,
        parsed.density,
        lambda,
        mu
    );
    mfem::BackwardEulerSolver ode_solver;
    ode_solver.Init(dynamic_operator);

    mfem::ParGridFunction displacement(&fespace);
    mfem::ParGridFunction velocity(&fespace);
    mfem::Vector displacement_vector(dim);
    mfem::Vector velocity_vector(dim);
    for (int i = 0; i < dim; ++i)
    {
        displacement_vector[i] = parsed.initial_condition.displacement[static_cast<size_t>(i)];
        velocity_vector[i] = parsed.initial_condition.velocity[static_cast<size_t>(i)];
    }
    mfem::VectorConstantCoefficient displacement_coeff(displacement_vector);
    mfem::VectorConstantCoefficient velocity_coeff(velocity_vector);
    displacement.ProjectCoefficient(displacement_coeff);
    velocity.ProjectCoefficient(velocity_coeff);

    const int true_size = fespace.GetTrueVSize();
    mfem::Vector displacement_true(true_size);
    mfem::Vector velocity_true(true_size);
    displacement.GetTrueDofs(displacement_true);
    velocity.GetTrueDofs(velocity_true);
    if (ess_tdof_list.Size() > 0)
    {
        displacement_true.SetSubVector(ess_tdof_list, 0.0);
        velocity_true.SetSubVector(ess_tdof_list, 0.0);
    }

    mfem::Vector state(2 * true_size);
    {
        mfem::Vector state_v(state.GetData() + 0, true_size);
        mfem::Vector state_u(state.GetData() + true_size, true_size);
        state_v = velocity_true;
        state_u = displacement_true;
    }
    dynamic_operator.ApplyEssentialBCs(state);

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
    paraview.RegisterField("displacement", &displacement);
    paraview.RegisterField("velocity", &velocity);

    auto save_step = [&](int step, double time) {
        mfem::Vector state_v(state.GetData() + 0, true_size);
        mfem::Vector state_u(state.GetData() + true_size, true_size);
        velocity.SetFromTrueDofs(state_v);
        displacement.SetFromTrueDofs(state_u);
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
        dynamic_operator.ApplyEssentialBCs(state);
        ++step;
        if (step % parsed.output_interval_steps == 0 || time + 1.0e-12 >= parsed.t_final)
        {
            save_step(step, time);
        }
    }

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# elastodynamics fields written to " << collection_name << ".pvd\n";

    mfem::Vector final_v(state.GetData() + 0, true_size);
    mfem::Vector final_u(state.GetData() + true_size, true_size);

    mfem::Vector mass_v(true_size);
    dynamic_operator.MassMatrix().Mult(final_v, mass_v);

    mfem::Vector stiffness_u(true_size);
    dynamic_operator.StiffnessMatrix().Mult(final_u, stiffness_u);

    mfem::Vector acceleration(true_size);
    dynamic_operator.ComputeAcceleration(final_u, time, acceleration);

    mfem::Vector load_vector(true_size);
    dynamic_operator.ComputeLoadVector(time, load_vector);

    mfem::Vector residual(true_size);
    dynamic_operator.MassMatrix().Mult(acceleration, residual);
    residual += stiffness_u;
    residual -= load_vector;
    if (ess_tdof_list.Size() > 0)
    {
        residual.SetSubVector(ess_tdof_list, 0.0);
    }

    const double kinetic_energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), final_v, mass_v);
    const double potential_energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), final_u, stiffness_u);

    SolveSummary summary;
    summary.energy = kinetic_energy + potential_energy;
    summary.iterations = dynamic_operator.TotalMassIterations() + dynamic_operator.TotalImplicitIterations();
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("Elastodynamics solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
