// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "AcousticWave.hpp"

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

double require_positive_number(const json &config, const char *field_name)
{
    if (!config.contains(field_name) || !config[field_name].is_number())
    {
        throw std::runtime_error(std::string("config.") + field_name + " is required and must be numeric.");
    }
    const double parsed = config[field_name].get<double>();
    if (!(parsed > 0.0))
    {
        throw std::runtime_error(std::string("config.") + field_name + " must be > 0.");
    }
    return parsed;
}

#if defined(MFEM_USE_MPI)
class GaussianPulseCoefficient final : public mfem::Coefficient
{
public:
    GaussianPulseCoefficient(double amplitude, const std::vector<double> &center, int dim)
        : amplitude_(amplitude),
          center_(dim)
    {
        center_ = 0.0;
        const int count = std::min(dim, static_cast<int>(center.size()));
        for (int i = 0; i < count; ++i)
        {
            center_[i] = center[static_cast<size_t>(i)];
        }
    }

    mfem::real_t Eval(mfem::ElementTransformation &transformation, const mfem::IntegrationPoint &ip) override
    {
        mfem::Vector position;
        transformation.Transform(ip, position);

        double radius_sq = 0.0;
        for (int i = 0; i < position.Size(); ++i)
        {
            const double delta = position[i] - center_[i];
            radius_sq += delta * delta;
        }
        return amplitude_ * std::exp(-30.0 * radius_sq);
    }

private:
    double amplitude_;
    mfem::Vector center_;
};

class AcousticWaveOperator final : public mfem::SecondOrderTimeDependentOperator
{
public:
    AcousticWaveOperator(
        mfem::ParFiniteElementSpace &fespace,
        const mfem::Array<int> &ess_tdof_list,
        double wave_speed)
        : mfem::SecondOrderTimeDependentOperator(fespace.GetTrueVSize(), 0.0),
          ess_tdof_list_(ess_tdof_list),
          implicit_matrix_(nullptr),
          current_fac0_(-1.0),
          mass_solver_(fespace.GetComm()),
          implicit_solver_(fespace.GetComm()),
          z_(height)
    {
        const mfem::real_t rel_tol = 1.0e-8;

        mass_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace);
        mass_form_->AddDomainIntegrator(new mfem::MassIntegrator());
        mass_form_->Assemble(0);
        mass_form_->FormSystemMatrix(ess_tdof_list_, mass_matrix_);

        mfem::ConstantCoefficient speed_sq_coeff(wave_speed * wave_speed);
        stiffness_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace);
        stiffness_form_->AddDomainIntegrator(new mfem::DiffusionIntegrator(speed_sq_coeff));
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
        implicit_prec_.SetType(mfem::HypreSmoother::Jacobi);
        implicit_solver_.SetPreconditioner(implicit_prec_);
    }

    ~AcousticWaveOperator() override
    {
        delete implicit_matrix_;
    }

    using mfem::SecondOrderTimeDependentOperator::Mult;
    void Mult(
        const mfem::Vector &u,
        const mfem::Vector &du_dt,
        mfem::Vector &d2u_dt2) const override
    {
        (void)du_dt;
        stiffness_matrix_.Mult(u, z_);
        z_.Neg();
        ZeroEssentialEntries(z_);
        mass_solver_.Mult(z_, d2u_dt2);
        ZeroEssentialEntries(d2u_dt2);
    }

    using mfem::SecondOrderTimeDependentOperator::ImplicitSolve;
    void ImplicitSolve(
        const mfem::real_t fac0,
        const mfem::real_t fac1,
        const mfem::Vector &u,
        const mfem::Vector &du_dt,
        mfem::Vector &d2u_dt2) override
    {
        (void)fac1;
        (void)du_dt;

        if (implicit_matrix_ == nullptr || std::abs(fac0 - current_fac0_) > 1.0e-15)
        {
            delete implicit_matrix_;
            implicit_matrix_ = mfem::Add(1.0, mass_matrix_, fac0, stiffness_matrix_);
            current_fac0_ = fac0;
            if (ess_tdof_list_.Size() > 0)
            {
                implicit_matrix_->EliminateBC(ess_tdof_list_, mfem::Operator::DIAG_ONE);
            }
            implicit_solver_.SetOperator(*implicit_matrix_);
        }

        stiffness_matrix_.Mult(u, z_);
        z_.Neg();
        ZeroEssentialEntries(z_);
        implicit_solver_.Mult(z_, d2u_dt2);
        ZeroEssentialEntries(d2u_dt2);
        total_implicit_iterations_ += implicit_solver_.GetNumIterations();
    }

    const mfem::HypreParMatrix &MassMatrix() const
    {
        return mass_matrix_;
    }

    const mfem::HypreParMatrix &StiffnessMatrix() const
    {
        return stiffness_matrix_;
    }

    int TotalImplicitIterations() const
    {
        return total_implicit_iterations_;
    }

private:
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

    mfem::Array<int> ess_tdof_list_;

    std::unique_ptr<mfem::ParBilinearForm> mass_form_;
    std::unique_ptr<mfem::ParBilinearForm> stiffness_form_;

    mfem::HypreParMatrix mass_matrix_;
    mfem::HypreParMatrix stiffness_matrix_;
    mfem::HypreParMatrix *implicit_matrix_;
    mfem::real_t current_fac0_;

    mutable mfem::CGSolver mass_solver_;
    mutable mfem::HypreSmoother mass_prec_;
    mfem::CGSolver implicit_solver_;
    mfem::HypreSmoother implicit_prec_;

    mutable mfem::Vector z_;
    int total_implicit_iterations_ = 0;
};
#endif
} // namespace

namespace autosage
{
const char *AcousticWaveSolver::Name() const
{
    return "AcousticWave";
}

AcousticWaveSolver::AcousticWaveConfig AcousticWaveSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute,
    int dim) const
{
    AcousticWaveConfig parsed;
    parsed.wave_speed = require_positive_number(config, "wave_speed");
    parsed.dt = require_positive_number(config, "dt");
    parsed.t_final = require_positive_number(config, "t_final");

    if (!config.contains("initial_condition") || !config["initial_condition"].is_object())
    {
        throw std::runtime_error("config.initial_condition is required and must be an object.");
    }
    const json &initial_condition = config["initial_condition"];
    const std::string initial_type = to_lower(initial_condition.value("type", ""));
    if (initial_type != "gaussian_pulse" &&
        initial_type != "gaussian-pulse" &&
        initial_type != "gaussianpulse")
    {
        throw std::runtime_error("config.initial_condition.type must be gaussian_pulse.");
    }
    if (!initial_condition.contains("amplitude") || !initial_condition["amplitude"].is_number())
    {
        throw std::runtime_error("config.initial_condition.amplitude is required and must be numeric.");
    }
    parsed.initial_amplitude = initial_condition["amplitude"].get<double>();

    if (!initial_condition.contains("center") || !initial_condition["center"].is_array())
    {
        throw std::runtime_error("config.initial_condition.center is required and must be an array.");
    }
    if (initial_condition["center"].empty())
    {
        throw std::runtime_error("config.initial_condition.center must not be empty.");
    }
    if (static_cast<int>(initial_condition["center"].size()) > 3)
    {
        throw std::runtime_error("config.initial_condition.center must contain at most 3 values.");
    }
    parsed.initial_center.reserve(initial_condition["center"].size());
    for (const auto &value : initial_condition["center"])
    {
        if (!value.is_number())
        {
            throw std::runtime_error("config.initial_condition.center entries must be numeric.");
        }
        parsed.initial_center.push_back(value.get<double>());
    }
    if (static_cast<int>(parsed.initial_center.size()) < dim)
    {
        parsed.initial_center.resize(dim, 0.0);
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.rigid_wall_marker.assign(boundary_slots, 0);
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
        if (type == "rigid_wall" || type == "rigid-wall" || type == "rigidwall")
        {
            parsed.rigid_wall_marker[attribute - 1] = 1;
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be rigid_wall.");
    }

    return parsed;
}

SolveSummary AcousticWaveSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const AcousticWaveConfig parsed = ParseConfig(config, max_boundary_attribute, dim);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.rigid_wall_marker[i];
    }

    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    GaussianPulseCoefficient initial_condition(parsed.initial_amplitude, parsed.initial_center, dim);

    mfem::ParGridFunction potential(&fespace);
    potential.ProjectCoefficient(initial_condition);
    mfem::ParGridFunction rate(&fespace);
    rate = 0.0;

    mfem::Vector potential_true(fespace.GetTrueVSize());
    mfem::Vector rate_true(fespace.GetTrueVSize());
    potential.GetTrueDofs(potential_true);
    rate.GetTrueDofs(rate_true);
    if (ess_tdof_list.Size() > 0)
    {
        potential_true.SetSubVector(ess_tdof_list, 0.0);
        rate_true.SetSubVector(ess_tdof_list, 0.0);
    }

    AcousticWaveOperator wave_operator(fespace, ess_tdof_list, parsed.wave_speed);
    mfem::NewmarkSolver ode_solver;
    ode_solver.Init(wave_operator);

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
    paraview.RegisterField("acoustic_potential", &potential);
    paraview.RegisterField("acoustic_rate", &rate);

    auto save_step = [&](int step, double time) {
        potential.SetFromTrueDofs(potential_true);
        rate.SetFromTrueDofs(rate_true);
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
        ode_solver.Step(potential_true, rate_true, time, step_dt);
        if (ess_tdof_list.Size() > 0)
        {
            potential_true.SetSubVector(ess_tdof_list, 0.0);
            rate_true.SetSubVector(ess_tdof_list, 0.0);
        }
        ++step;
        save_step(step, time);
    }

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# acoustic fields written to " << collection_name << ".pvd\n";

    mfem::Vector mass_rate(rate_true.Size());
    wave_operator.MassMatrix().Mult(rate_true, mass_rate);
    mfem::Vector stiffness_potential(potential_true.Size());
    wave_operator.StiffnessMatrix().Mult(potential_true, stiffness_potential);

    mfem::Vector acceleration(potential_true.Size());
    wave_operator.Mult(potential_true, rate_true, acceleration);
    mfem::Vector residual(acceleration.Size());
    wave_operator.MassMatrix().Mult(acceleration, residual);
    residual += stiffness_potential;
    for (int i = 0; i < ess_tdof_list.Size(); ++i)
    {
        const int tdof = ess_tdof_list[i];
        if (tdof >= 0 && tdof < residual.Size())
        {
            residual[tdof] = 0.0;
        }
    }

    const double kinetic_energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), rate_true, mass_rate);
    const double potential_energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), potential_true, stiffness_potential);

    SolveSummary summary;
    summary.energy = kinetic_energy + potential_energy;
    summary.iterations = wave_operator.TotalImplicitIterations();
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("AcousticWave solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
