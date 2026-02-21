// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "JouleHeating.hpp"

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
    const double value = config[field_name].get<double>();
    if (!(value > 0.0))
    {
        throw std::runtime_error(std::string("config.") + field_name + " must be > 0.");
    }
    return value;
}

#if defined(MFEM_USE_MPI)
class JouleSourceCoefficient final : public mfem::Coefficient
{
public:
    JouleSourceCoefficient(const mfem::ParGridFunction &potential, double conductivity, int dimension)
        : potential_(potential),
          conductivity_(conductivity),
          gradient_(dimension)
    {
    }

    mfem::real_t Eval(mfem::ElementTransformation &T, const mfem::IntegrationPoint &ip) override
    {
        T.SetIntPoint(&ip);
        potential_.GetGradient(T, gradient_);
        return conductivity_ * (gradient_ * gradient_);
    }

private:
    const mfem::ParGridFunction &potential_;
    double conductivity_;
    mfem::Vector gradient_;
};

class JouleHeatingOperator final : public mfem::TimeDependentOperator
{
public:
    JouleHeatingOperator(
        mfem::ParFiniteElementSpace &thermal_fespace,
        mfem::ParFiniteElementSpace &electric_fespace,
        const mfem::Array<int> &thermal_ess_tdof_list,
        const mfem::Array<int> &electric_ess_tdof_list,
        const mfem::Array<int> &thermal_ess_bdr,
        const mfem::Array<int> &electric_ess_bdr,
        mfem::PWConstCoefficient &thermal_fixed_coeff,
        mfem::PWConstCoefficient &electric_fixed_coeff,
        mfem::ParGridFunction &temperature,
        mfem::ParGridFunction &electric_potential,
        double heat_capacity,
        double thermal_conductivity,
        double electrical_conductivity
    )
        : mfem::TimeDependentOperator(thermal_fespace.GetTrueVSize(), 0.0),
          thermal_fespace_(thermal_fespace),
          electric_fespace_(electric_fespace),
          thermal_ess_tdof_list_(thermal_ess_tdof_list),
          electric_ess_tdof_list_(electric_ess_tdof_list),
          thermal_ess_bdr_(thermal_ess_bdr),
          electric_ess_bdr_(electric_ess_bdr),
          thermal_fixed_coeff_(thermal_fixed_coeff),
          electric_fixed_coeff_(electric_fixed_coeff),
          temperature_(temperature),
          electric_potential_(electric_potential),
          electrical_conductivity_(electrical_conductivity),
          joule_source_coefficient_(electric_potential_, electrical_conductivity, thermal_fespace.GetMesh()->Dimension()),
          implicit_matrix_(nullptr),
          current_dt_(-1.0),
          mass_solver_(thermal_fespace.GetComm()),
          implicit_solver_(thermal_fespace.GetComm()),
          thermal_rhs_(height),
          thermal_work_(height),
          thermal_rhs_true_(height)
    {
        const mfem::real_t rel_tol = 1.0e-10;

        mfem::ConstantCoefficient heat_capacity_coeff(heat_capacity);
        thermal_mass_form_ = std::make_unique<mfem::ParBilinearForm>(&thermal_fespace_);
        thermal_mass_form_->AddDomainIntegrator(new mfem::MassIntegrator(heat_capacity_coeff));
        thermal_mass_form_->Assemble(0);
        thermal_mass_form_->FormSystemMatrix(mfem::Array<int>(), thermal_mass_matrix_);

        thermal_mass_matrix_solver_ = std::make_unique<mfem::HypreParMatrix>(thermal_mass_matrix_);
        if (thermal_ess_tdof_list_.Size() > 0)
        {
            thermal_mass_matrix_solver_->EliminateBC(thermal_ess_tdof_list_, mfem::Operator::DIAG_ONE);
        }

        mass_solver_.iterative_mode = false;
        mass_solver_.SetRelTol(rel_tol);
        mass_solver_.SetAbsTol(0.0);
        mass_solver_.SetMaxIter(500);
        mass_solver_.SetPrintLevel(0);
        mass_prec_.SetType(mfem::HypreSmoother::Jacobi);
        mass_solver_.SetPreconditioner(mass_prec_);
        mass_solver_.SetOperator(*thermal_mass_matrix_solver_);

        mfem::ConstantCoefficient thermal_conductivity_coeff(thermal_conductivity);
        thermal_stiffness_form_ = std::make_unique<mfem::ParBilinearForm>(&thermal_fespace_);
        thermal_stiffness_form_->AddDomainIntegrator(new mfem::DiffusionIntegrator(thermal_conductivity_coeff));
        thermal_stiffness_form_->Assemble(0);
        thermal_stiffness_form_->FormSystemMatrix(mfem::Array<int>(), thermal_stiffness_matrix_);

        thermal_rhs_form_ = std::make_unique<mfem::ParLinearForm>(&thermal_fespace_);
        thermal_rhs_form_->AddDomainIntegrator(new mfem::DomainLFIntegrator(joule_source_coefficient_));

        mfem::ConstantCoefficient electrical_conductivity_coeff(electrical_conductivity_);
        electric_form_ = std::make_unique<mfem::ParBilinearForm>(&electric_fespace_);
        electric_form_->AddDomainIntegrator(new mfem::DiffusionIntegrator(electrical_conductivity_coeff));
        electric_form_->Assemble(0);

        electric_solver_.iterative_mode = false;
        electric_solver_.SetRelTol(1.0e-12);
        electric_solver_.SetAbsTol(0.0);
        electric_solver_.SetMaxIter(2000);
        electric_solver_.SetPrintLevel(0);

        implicit_solver_.iterative_mode = false;
        implicit_solver_.SetRelTol(rel_tol);
        implicit_solver_.SetAbsTol(0.0);
        implicit_solver_.SetMaxIter(500);
        implicit_solver_.SetPrintLevel(0);
        implicit_prec_.SetType(mfem::HypreSmoother::Jacobi);
        implicit_solver_.SetPreconditioner(implicit_prec_);

        UpdateElectricPotentialAndJouleSource();
    }

    ~JouleHeatingOperator() override
    {
        delete implicit_matrix_;
    }

    void Mult(const mfem::Vector &u, mfem::Vector &du_dt) const override
    {
        thermal_stiffness_matrix_.Mult(u, thermal_work_);
        thermal_work_.Neg();
        thermal_rhs_ = thermal_rhs_true_;
        thermal_rhs_ += thermal_work_;
        zero_thermal_essential_entries(thermal_rhs_);
        mass_solver_.Mult(thermal_rhs_, du_dt);
    }

    void ImplicitSolve(const mfem::real_t dt, const mfem::Vector &u, mfem::Vector &k) override
    {
        UpdateElectricPotentialAndJouleSource();

        if (implicit_matrix_ == nullptr || std::abs(dt - current_dt_) > 1.0e-15)
        {
            delete implicit_matrix_;
            implicit_matrix_ = mfem::Add(1.0, thermal_mass_matrix_, dt, thermal_stiffness_matrix_);
            current_dt_ = dt;
            if (thermal_ess_tdof_list_.Size() > 0)
            {
                implicit_matrix_->EliminateBC(thermal_ess_tdof_list_, mfem::Operator::DIAG_ONE);
            }
            implicit_solver_.SetOperator(*implicit_matrix_);
        }

        thermal_stiffness_matrix_.Mult(u, thermal_work_);
        thermal_work_.Neg();
        thermal_rhs_ = thermal_rhs_true_;
        thermal_rhs_ += thermal_work_;
        zero_thermal_essential_entries(thermal_rhs_);

        implicit_solver_.Mult(thermal_rhs_, k);
        total_implicit_iterations_ += implicit_solver_.GetNumIterations();
    }

    int TotalImplicitIterations() const
    {
        return total_implicit_iterations_;
    }

    int TotalElectricIterations() const
    {
        return total_electric_iterations_;
    }

    const mfem::HypreParMatrix &ThermalMassMatrix() const
    {
        return thermal_mass_matrix_;
    }

    const mfem::HypreParMatrix &ThermalStiffnessMatrix() const
    {
        return thermal_stiffness_matrix_;
    }

    const mfem::Vector &ThermalRHSVector() const
    {
        return thermal_rhs_true_;
    }

private:
    void UpdateElectricPotentialAndJouleSource()
    {
        if (electric_ess_bdr_.Size() > 0)
        {
            electric_potential_.ProjectBdrCoefficient(electric_fixed_coeff_, electric_ess_bdr_);
        }

        mfem::ParLinearForm electric_rhs(&electric_fespace_);
        electric_rhs.Assemble();

        mfem::OperatorPtr electric_A;
        mfem::Vector electric_X;
        mfem::Vector electric_B;
        const int copy_interior = 1;
        electric_form_->FormLinearSystem(
            electric_ess_tdof_list_,
            electric_potential_,
            electric_rhs,
            electric_A,
            electric_X,
            electric_B,
            copy_interior
        );

        auto &electric_A_hypre = dynamic_cast<mfem::HypreParMatrix &>(*electric_A.Ptr());
        mfem::HypreParVector electric_B_hypre(
            electric_A_hypre.GetComm(),
            electric_A_hypre.GetGlobalNumRows(),
            electric_B,
            0,
            electric_A_hypre.GetRowStarts()
        );
        mfem::HypreParVector electric_X_hypre(
            electric_A_hypre.GetComm(),
            electric_A_hypre.GetGlobalNumRows(),
            electric_X,
            0,
            electric_A_hypre.GetRowStarts()
        );
        electric_X_hypre = 0.0;

        mfem::HypreBoomerAMG electric_amg(electric_A_hypre);
        electric_amg.SetPrintLevel(0);
        electric_solver_.SetPreconditioner(electric_amg);
        electric_solver_.SetOperator(electric_A_hypre);
        electric_solver_.Mult(electric_B_hypre, electric_X_hypre);

        total_electric_iterations_ += electric_solver_.GetNumIterations();

        electric_form_->RecoverFEMSolution(electric_X, electric_rhs, electric_potential_);

        thermal_rhs_form_->Assemble();
        thermal_rhs_form_->ParallelAssemble(thermal_rhs_true_);
        zero_thermal_essential_entries(thermal_rhs_true_);
    }

    void zero_thermal_essential_entries(mfem::Vector &vector) const
    {
        for (int i = 0; i < thermal_ess_tdof_list_.Size(); ++i)
        {
            const int tdof = thermal_ess_tdof_list_[i];
            if (tdof >= 0 && tdof < vector.Size())
            {
                vector[tdof] = 0.0;
            }
        }
    }

    mfem::ParFiniteElementSpace &thermal_fespace_;
    mfem::ParFiniteElementSpace &electric_fespace_;
    mfem::Array<int> thermal_ess_tdof_list_;
    mfem::Array<int> electric_ess_tdof_list_;
    mfem::Array<int> thermal_ess_bdr_;
    mfem::Array<int> electric_ess_bdr_;
    mfem::PWConstCoefficient &thermal_fixed_coeff_;
    mfem::PWConstCoefficient &electric_fixed_coeff_;
    mfem::ParGridFunction &temperature_;
    mfem::ParGridFunction &electric_potential_;
    double electrical_conductivity_;

    JouleSourceCoefficient joule_source_coefficient_;

    std::unique_ptr<mfem::ParBilinearForm> thermal_mass_form_;
    std::unique_ptr<mfem::ParBilinearForm> thermal_stiffness_form_;
    std::unique_ptr<mfem::ParLinearForm> thermal_rhs_form_;
    std::unique_ptr<mfem::ParBilinearForm> electric_form_;

    mfem::HypreParMatrix thermal_mass_matrix_;
    mfem::HypreParMatrix thermal_stiffness_matrix_;
    std::unique_ptr<mfem::HypreParMatrix> thermal_mass_matrix_solver_;
    mfem::HypreParMatrix *implicit_matrix_;
    mfem::real_t current_dt_;

    mutable mfem::CGSolver mass_solver_;
    mutable mfem::HypreSmoother mass_prec_;
    mfem::CGSolver electric_solver_;
    mfem::CGSolver implicit_solver_;
    mfem::HypreSmoother implicit_prec_;

    mutable mfem::Vector thermal_rhs_;
    mutable mfem::Vector thermal_work_;
    mfem::Vector thermal_rhs_true_;

    int total_implicit_iterations_ = 0;
    int total_electric_iterations_ = 0;
};
#endif
} // namespace

namespace autosage
{
const char *JouleHeatingSolver::Name() const
{
    return "JouleHeating";
}

JouleHeatingSolver::ParsedConfig JouleHeatingSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    ParsedConfig parsed;
    parsed.electrical_conductivity = require_positive_number(config, "electrical_conductivity");
    parsed.thermal_conductivity = require_positive_number(config, "thermal_conductivity");
    parsed.heat_capacity = require_positive_number(config, "heat_capacity");
    parsed.dt = require_positive_number(config, "dt");
    parsed.t_final = require_positive_number(config, "t_final");

    if (config.contains("output_interval_steps"))
    {
        if (!config["output_interval_steps"].is_number_integer())
        {
            throw std::runtime_error("config.output_interval_steps must be an integer when provided.");
        }
        parsed.output_interval_steps = config["output_interval_steps"].get<int>();
        if (parsed.output_interval_steps <= 0)
        {
            throw std::runtime_error("config.output_interval_steps must be > 0.");
        }
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.electric_marker.assign(boundary_slots, 0);
    parsed.electric_values.assign(boundary_slots, 0.0);
    parsed.thermal_marker.assign(boundary_slots, 0);
    parsed.thermal_values.assign(boundary_slots, 293.15);

    if (boundary_slots == 0 && !config["bcs"].empty())
    {
        throw std::runtime_error("Mesh has no boundary attributes but config.bcs was provided.");
    }

    bool has_electric_dirichlet = false;
    bool has_thermal_dirichlet = false;

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
        const double value = bc["value"].get<double>();

        if (type == "voltage" || type == "ground")
        {
            parsed.electric_marker[attribute - 1] = 1;
            parsed.electric_values[attribute - 1] = value;
            has_electric_dirichlet = true;
            continue;
        }
        if (type == "fixed_temp")
        {
            parsed.thermal_marker[attribute - 1] = 1;
            parsed.thermal_values[attribute - 1] = value;
            has_thermal_dirichlet = true;
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be voltage, ground, or fixed_temp.");
    }

    if (!has_electric_dirichlet)
    {
        throw std::runtime_error("config.bcs must include at least one voltage or ground boundary condition.");
    }
    if (!has_thermal_dirichlet)
    {
        throw std::runtime_error("config.bcs must include at least one fixed_temp boundary condition.");
    }

    return parsed;
}

SolveSummary JouleHeatingSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const ParsedConfig parsed = ParseConfig(config, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);

    mfem::H1_FECollection thermal_fec(1, dim);
    mfem::ParFiniteElementSpace thermal_fespace(&pmesh, &thermal_fec);
    mfem::ParGridFunction temperature(&thermal_fespace);
    temperature = 293.15;

    mfem::H1_FECollection electric_fec(1, dim);
    mfem::ParFiniteElementSpace electric_fespace(&pmesh, &electric_fec);
    mfem::ParGridFunction electric_potential(&electric_fespace);
    electric_potential = 0.0;

    mfem::Array<int> thermal_ess_bdr(max_boundary_attribute);
    mfem::Array<int> electric_ess_bdr(max_boundary_attribute);
    thermal_ess_bdr = 0;
    electric_ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        thermal_ess_bdr[i] = parsed.thermal_marker[i];
        electric_ess_bdr[i] = parsed.electric_marker[i];
    }

    mfem::Vector thermal_values(max_boundary_attribute);
    mfem::Vector electric_values(max_boundary_attribute);
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        thermal_values[i] = parsed.thermal_values[i];
        electric_values[i] = parsed.electric_values[i];
    }
    mfem::PWConstCoefficient thermal_fixed_coeff(thermal_values);
    mfem::PWConstCoefficient electric_fixed_coeff(electric_values);

    if (max_boundary_attribute > 0)
    {
        temperature.ProjectBdrCoefficient(thermal_fixed_coeff, thermal_ess_bdr);
        electric_potential.ProjectBdrCoefficient(electric_fixed_coeff, electric_ess_bdr);
    }

    mfem::Array<int> thermal_ess_tdof_list;
    mfem::Array<int> electric_ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        thermal_fespace.GetEssentialTrueDofs(thermal_ess_bdr, thermal_ess_tdof_list);
        electric_fespace.GetEssentialTrueDofs(electric_ess_bdr, electric_ess_tdof_list);
    }

    mfem::Vector temperature_true(thermal_fespace.GetTrueVSize());
    temperature.GetTrueDofs(temperature_true);

    JouleHeatingOperator coupled_operator(
        thermal_fespace,
        electric_fespace,
        thermal_ess_tdof_list,
        electric_ess_tdof_list,
        thermal_ess_bdr,
        electric_ess_bdr,
        thermal_fixed_coeff,
        electric_fixed_coeff,
        temperature,
        electric_potential,
        parsed.heat_capacity,
        parsed.thermal_conductivity,
        parsed.electrical_conductivity
    );

    mfem::BackwardEulerSolver ode_solver;
    ode_solver.Init(coupled_operator);

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
    paraview.RegisterField("temperature", &temperature);
    paraview.RegisterField("electric_potential", &electric_potential);

    auto save_step = [&](int step, double time) {
        paraview.SetCycle(step);
        paraview.SetTime(time);
        paraview.Save();
    };

    double time = 0.0;
    int step = 0;
    temperature.SetFromTrueDofs(temperature_true);
    save_step(step, time);

    while (time + 1.0e-12 < parsed.t_final)
    {
        mfem::real_t step_dt = std::min(parsed.dt, parsed.t_final - time);
        ode_solver.Step(temperature_true, time, step_dt);

        temperature.SetFromTrueDofs(temperature_true);
        if (max_boundary_attribute > 0)
        {
            temperature.ProjectBdrCoefficient(thermal_fixed_coeff, thermal_ess_bdr);
            temperature.GetTrueDofs(temperature_true);
        }

        ++step;
        if (step % parsed.output_interval_steps == 0 || time + 1.0e-12 >= parsed.t_final)
        {
            save_step(step, time);
        }
    }

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# Joule heating fields written to " << collection_name << ".pvd\n";

    mfem::Vector mass_times_temperature(temperature_true.Size());
    coupled_operator.ThermalMassMatrix().Mult(temperature_true, mass_times_temperature);

    mfem::Vector residual(coupled_operator.ThermalRHSVector());
    mfem::Vector stiffness_times_temperature(residual.Size());
    coupled_operator.ThermalStiffnessMatrix().Mult(temperature_true, stiffness_times_temperature);
    residual -= stiffness_times_temperature;
    for (int i = 0; i < thermal_ess_tdof_list.Size(); ++i)
    {
        const int tdof = thermal_ess_tdof_list[i];
        if (tdof >= 0 && tdof < residual.Size())
        {
            residual[tdof] = 0.0;
        }
    }

    const fs::path metadata_path = fs::path(context.working_directory) / "joule_heating.json";
    json metadata = {
        {"solver_class", "JouleHeating"},
        {"solver_backend", "backward_euler_staggered"},
        {"electrical_conductivity", parsed.electrical_conductivity},
        {"thermal_conductivity", parsed.thermal_conductivity},
        {"heat_capacity", parsed.heat_capacity},
        {"dt", parsed.dt},
        {"t_final", parsed.t_final},
        {"time_steps", step},
        {"thermal_iterations", coupled_operator.TotalImplicitIterations()},
        {"electric_iterations", coupled_operator.TotalElectricIterations()}
    };
    std::ofstream metadata_out(metadata_path);
    if (!metadata_out)
    {
        throw std::runtime_error("Unable to write joule_heating.json.");
    }
    metadata_out << metadata.dump(2);

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(thermal_fespace.GetComm(), temperature_true, mass_times_temperature);
    summary.iterations = coupled_operator.TotalImplicitIterations() + coupled_operator.TotalElectricIterations();
    summary.error_norm = std::sqrt(mfem::InnerProduct(thermal_fespace.GetComm(), residual, residual));
    summary.dimension = dim;
    if (!std::isfinite(summary.error_norm))
    {
        throw std::runtime_error("JouleHeating residual norm is non-finite.");
    }
    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("JouleHeating solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
