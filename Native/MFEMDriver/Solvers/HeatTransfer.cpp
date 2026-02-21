// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "HeatTransfer.hpp"

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
std::string to_lower(std::string value)
{
    std::transform(
        value.begin(),
        value.end(),
        value.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

double require_positive_number(const json &value, const char *field_name)
{
    if (!value.contains(field_name) || !value[field_name].is_number())
    {
        throw std::runtime_error(std::string("config.") + field_name + " is required and must be numeric.");
    }
    const double parsed = value[field_name].get<double>();
    if (!(parsed > 0.0))
    {
        throw std::runtime_error(std::string("config.") + field_name + " must be > 0.");
    }
    return parsed;
}

double require_number(const json &value, const char *field_name)
{
    if (!value.contains(field_name) || !value[field_name].is_number())
    {
        throw std::runtime_error(std::string("config.") + field_name + " is required and must be numeric.");
    }
    return value[field_name].get<double>();
}

bool has_nonzero_entries(const mfem::Vector &values)
{
    for (int i = 0; i < values.Size(); ++i)
    {
        if (std::abs(values[i]) > 0.0)
        {
            return true;
        }
    }
    return false;
}

#if defined(MFEM_USE_MPI)
class ConductionOperator final : public mfem::TimeDependentOperator
{
public:
    ConductionOperator(
        mfem::ParFiniteElementSpace &fespace,
        const mfem::Array<int> &ess_tdof_list,
        double specific_heat,
        double conductivity,
        double source,
        const mfem::Vector &heat_flux_values)
        : mfem::TimeDependentOperator(fespace.GetTrueVSize(), 0.0),
          fespace_(fespace),
          ess_tdof_list_(ess_tdof_list),
          implicit_matrix_(nullptr),
          current_dt_(-1.0),
          mass_solver_(fespace.GetComm()),
          implicit_solver_(fespace.GetComm()),
          z_(height),
          rhs_(height),
          rhs_true_(height)
    {
        const mfem::real_t rel_tol = 1.0e-10;

        mfem::ConstantCoefficient cp_coeff(specific_heat);
        mass_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace_);
        mass_form_->AddDomainIntegrator(new mfem::MassIntegrator(cp_coeff));
        mass_form_->Assemble(0);
        mass_form_->FormSystemMatrix(mfem::Array<int>(), mass_matrix_);

        mass_matrix_solver_ = std::make_unique<mfem::HypreParMatrix>(mass_matrix_);
        if (ess_tdof_list_.Size() > 0)
        {
            mass_matrix_solver_->EliminateBC(ess_tdof_list_, mfem::Operator::DIAG_ONE);
        }

        mass_solver_.iterative_mode = false;
        mass_solver_.SetRelTol(rel_tol);
        mass_solver_.SetAbsTol(0.0);
        mass_solver_.SetMaxIter(500);
        mass_solver_.SetPrintLevel(0);
        mass_prec_.SetType(mfem::HypreSmoother::Jacobi);
        mass_solver_.SetPreconditioner(mass_prec_);
        mass_solver_.SetOperator(*mass_matrix_solver_);

        mfem::ConstantCoefficient conductivity_coeff(conductivity);
        stiffness_form_ = std::make_unique<mfem::ParBilinearForm>(&fespace_);
        stiffness_form_->AddDomainIntegrator(new mfem::DiffusionIntegrator(conductivity_coeff));
        stiffness_form_->Assemble(0);
        stiffness_form_->FormSystemMatrix(mfem::Array<int>(), stiffness_matrix_);

        rhs_form_ = std::make_unique<mfem::ParLinearForm>(&fespace_);
        std::unique_ptr<mfem::ConstantCoefficient> source_coeff;
        if (std::abs(source) > 0.0)
        {
            source_coeff = std::make_unique<mfem::ConstantCoefficient>(source);
            rhs_form_->AddDomainIntegrator(new mfem::DomainLFIntegrator(*source_coeff));
        }
        std::unique_ptr<mfem::PWConstCoefficient> flux_coeff;
        if (heat_flux_values.Size() > 0 && has_nonzero_entries(heat_flux_values))
        {
            mfem::Vector flux_values_copy(heat_flux_values);
            flux_coeff = std::make_unique<mfem::PWConstCoefficient>(flux_values_copy);
            rhs_form_->AddBoundaryIntegrator(new mfem::BoundaryLFIntegrator(*flux_coeff));
        }
        rhs_form_->Assemble();
        rhs_form_->ParallelAssemble(rhs_true_);

        implicit_solver_.iterative_mode = false;
        implicit_solver_.SetRelTol(rel_tol);
        implicit_solver_.SetAbsTol(0.0);
        implicit_solver_.SetMaxIter(500);
        implicit_solver_.SetPrintLevel(0);
        implicit_prec_.SetType(mfem::HypreSmoother::Jacobi);
        implicit_solver_.SetPreconditioner(implicit_prec_);
    }

    ~ConductionOperator() override
    {
        delete implicit_matrix_;
    }

    void Mult(const mfem::Vector &u, mfem::Vector &du_dt) const override
    {
        // cp*M*du_dt = rhs - K*u
        stiffness_matrix_.Mult(u, z_);
        z_.Neg();
        rhs_ = rhs_true_;
        rhs_ += z_;
        zero_essential_entries(rhs_);
        mass_solver_.Mult(rhs_, du_dt);
    }

    void ImplicitSolve(const mfem::real_t dt, const mfem::Vector &u, mfem::Vector &k) override
    {
        // Backward Euler in ex16 form: solve (M + dt*K) k = rhs - K*u
        if (implicit_matrix_ == nullptr || std::abs(dt - current_dt_) > 1.0e-15)
        {
            delete implicit_matrix_;
            implicit_matrix_ = mfem::Add(1.0, mass_matrix_, dt, stiffness_matrix_);
            current_dt_ = dt;
            if (ess_tdof_list_.Size() > 0)
            {
                implicit_matrix_->EliminateBC(ess_tdof_list_, mfem::Operator::DIAG_ONE);
            }
            implicit_solver_.SetOperator(*implicit_matrix_);
        }

        stiffness_matrix_.Mult(u, z_);
        z_.Neg();
        rhs_ = rhs_true_;
        rhs_ += z_;
        zero_essential_entries(rhs_);

        implicit_solver_.Mult(rhs_, k);
        last_implicit_iterations_ = implicit_solver_.GetNumIterations();
        total_implicit_iterations_ += last_implicit_iterations_;
    }

    int TotalImplicitIterations() const
    {
        return total_implicit_iterations_;
    }

    const mfem::HypreParMatrix &MassMatrix() const
    {
        return mass_matrix_;
    }

    const mfem::HypreParMatrix &StiffnessMatrix() const
    {
        return stiffness_matrix_;
    }

    const mfem::Vector &RHSVector() const
    {
        return rhs_true_;
    }

private:
    void zero_essential_entries(mfem::Vector &vector) const
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
    std::unique_ptr<mfem::ParBilinearForm> stiffness_form_;
    std::unique_ptr<mfem::ParLinearForm> rhs_form_;

    mfem::HypreParMatrix mass_matrix_;
    mfem::HypreParMatrix stiffness_matrix_;
    std::unique_ptr<mfem::HypreParMatrix> mass_matrix_solver_;
    mfem::HypreParMatrix *implicit_matrix_;
    mfem::real_t current_dt_;

    mutable mfem::CGSolver mass_solver_;
    mutable mfem::HypreSmoother mass_prec_;
    mfem::CGSolver implicit_solver_;
    mfem::HypreSmoother implicit_prec_;

    mutable mfem::Vector z_;
    mutable mfem::Vector rhs_;
    mfem::Vector rhs_true_;
    int total_implicit_iterations_ = 0;
    int last_implicit_iterations_ = 0;
};
#endif
} // namespace

namespace autosage
{
const char *HeatTransferSolver::Name() const
{
    return "HeatTransfer";
}

HeatTransferSolver::HeatConfig HeatTransferSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    HeatConfig parsed;
    parsed.conductivity = require_positive_number(config, "conductivity");
    parsed.specific_heat = require_positive_number(config, "specific_heat");
    parsed.initial_temperature = require_number(config, "initial_temperature");
    parsed.dt = require_positive_number(config, "dt");
    parsed.t_final = require_positive_number(config, "t_final");

    if (config.contains("source"))
    {
        if (!config["source"].is_number())
        {
            throw std::runtime_error("config.source must be numeric when provided.");
        }
        parsed.source = config["source"].get<double>();
    }

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
    parsed.fixed_temperature_marker.assign(boundary_slots, 0);
    parsed.fixed_temperature_values.assign(boundary_slots, parsed.initial_temperature);
    parsed.heat_flux_values.assign(boundary_slots, 0.0);

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
        if (!bc.contains("value") || !bc["value"].is_number())
        {
            throw std::runtime_error("config.bcs[].value is required and must be numeric.");
        }
        const double value = bc["value"].get<double>();

        if (type == "fixed_temp")
        {
            parsed.fixed_temperature_marker[attribute - 1] = 1;
            parsed.fixed_temperature_values[attribute - 1] = value;
            continue;
        }
        if (type == "heat_flux")
        {
            parsed.heat_flux_values[attribute - 1] += value;
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be fixed_temp or heat_flux.");
    }

    return parsed;
}

SolveSummary HeatTransferSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const HeatConfig parsed = ParseConfig(config, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.fixed_temperature_marker[i];
    }

    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    mfem::ParGridFunction temperature(&fespace);
    temperature = parsed.initial_temperature;

    mfem::Vector fixed_temperature_values(max_boundary_attribute);
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        fixed_temperature_values[i] = parsed.fixed_temperature_values[i];
    }
    mfem::PWConstCoefficient fixed_temperature_coeff(fixed_temperature_values);
    if (max_boundary_attribute > 0)
    {
        temperature.ProjectBdrCoefficient(fixed_temperature_coeff, ess_bdr);
    }

    mfem::Vector temperature_true(fespace.GetTrueVSize());
    temperature.GetTrueDofs(temperature_true);

    mfem::Vector heat_flux_values(max_boundary_attribute);
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        heat_flux_values[i] = parsed.heat_flux_values[i];
    }

    ConductionOperator conduction(
        fespace,
        ess_tdof_list,
        parsed.specific_heat,
        parsed.conductivity,
        parsed.source,
        heat_flux_values
    );

    mfem::BackwardEulerSolver ode_solver;
    ode_solver.Init(conduction);

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
            temperature.ProjectBdrCoefficient(fixed_temperature_coeff, ess_bdr);
            temperature.GetTrueDofs(temperature_true);
        }

        ++step;
        if (step % parsed.output_interval_steps == 0 || time + 1.0e-12 >= parsed.t_final)
        {
            save_step(step, time);
        }
    }

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# temperature field written to " << collection_name << ".pvd\n";

    mfem::Vector mass_times_temperature(temperature_true.Size());
    conduction.MassMatrix().Mult(temperature_true, mass_times_temperature);

    mfem::Vector residual(conduction.RHSVector());
    mfem::Vector stiffness_times_temperature(residual.Size());
    conduction.StiffnessMatrix().Mult(temperature_true, stiffness_times_temperature);
    residual -= stiffness_times_temperature;
    for (int i = 0; i < ess_tdof_list.Size(); ++i)
    {
        const int tdof = ess_tdof_list[i];
        if (tdof >= 0 && tdof < residual.Size())
        {
            residual[tdof] = 0.0;
        }
    }

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), temperature_true, mass_times_temperature);
    summary.iterations = conduction.TotalImplicitIterations();
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("HeatTransfer solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
