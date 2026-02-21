// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "IncompressibleElasticity.hpp"

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

std::vector<double> parse_vector_value(
    const json &value,
    const std::string &field_name,
    int dimension,
    bool required)
{
    if (value.is_null())
    {
        if (required)
        {
            throw std::runtime_error(field_name + " is required.");
        }
        return std::vector<double>(dimension, 0.0);
    }
    if (!value.is_array())
    {
        throw std::runtime_error(field_name + " must be an array.");
    }
    std::vector<double> parsed;
    for (const auto &component : value)
    {
        if (!component.is_number())
        {
            throw std::runtime_error(field_name + " entries must be numeric.");
        }
        parsed.push_back(component.get<double>());
    }
    if (static_cast<int>(parsed.size()) < dimension)
    {
        throw std::runtime_error(field_name + " must provide at least mesh-dimension components.");
    }
    parsed.resize(dimension);
    return parsed;
}

void reference_configuration(const mfem::Vector &x, mfem::Vector &y)
{
    y = x;
}

#if defined(MFEM_USE_MPI)
class IncompressibleElasticityPreconditioner final : public mfem::Solver
{
public:
    IncompressibleElasticityPreconditioner(
        mfem::Array<mfem::ParFiniteElementSpace *> &spaces,
        mfem::HypreParMatrix &pressure_mass,
        const mfem::Array<int> &block_true_offsets,
        double pressure_scale)
        : mfem::Solver(block_true_offsets[block_true_offsets.Size() - 1]),
          spaces_(spaces),
          block_true_offsets_(block_true_offsets),
          pressure_mass_(pressure_mass),
          pressure_scale_(pressure_scale)
    {
        block_diagonal_ = std::make_unique<mfem::BlockDiagonalPreconditioner>(block_true_offsets_);

        mfem::Vector pressure_diag(pressure_mass_.GetNumRows());
        pressure_mass_.GetDiag(pressure_diag);
        if (std::abs(pressure_scale_) > 0.0)
        {
            pressure_diag /= pressure_scale_;
        }
        pressure_jacobi_ = std::make_unique<mfem::OperatorJacobiSmoother>(pressure_diag, mfem::Array<int>());
        pressure_jacobi_->iterative_mode = false;
        block_diagonal_->SetDiagonalBlock(1, pressure_jacobi_.get());
    }

    void SetOperator(const mfem::Operator &op) override
    {
        jacobian_ = dynamic_cast<const mfem::BlockOperator *>(&op);
        if (jacobian_ == nullptr)
        {
            throw std::runtime_error("Incompressible elasticity Jacobian is not a BlockOperator.");
        }

        const auto *displacement_block_const = dynamic_cast<const mfem::HypreParMatrix *>(&jacobian_->GetBlock(0, 0));
        if (displacement_block_const == nullptr)
        {
            throw std::runtime_error("Incompressible elasticity displacement Jacobian block is not HypreParMatrix.");
        }
        auto *displacement_block = const_cast<mfem::HypreParMatrix *>(displacement_block_const);

        displacement_amg_ = std::make_unique<mfem::HypreBoomerAMG>(*displacement_block);
        displacement_amg_->SetPrintLevel(0);
        if (!spaces_[0]->GetParMesh()->Nonconforming())
        {
#if !defined(HYPRE_USING_GPU)
            displacement_amg_->SetElasticityOptions(spaces_[0]);
#endif
        }
        block_diagonal_->SetDiagonalBlock(0, displacement_amg_.get());
        block_diagonal_->SetDiagonalBlock(1, pressure_jacobi_.get());
    }

    void Mult(const mfem::Vector &x, mfem::Vector &y) const override
    {
        if (jacobian_ == nullptr || block_diagonal_ == nullptr)
        {
            throw std::runtime_error("Incompressible elasticity preconditioner operator is not initialized.");
        }
        block_diagonal_->Mult(x, y);
    }

private:
    mfem::Array<mfem::ParFiniteElementSpace *> spaces_;
    mfem::Array<int> block_true_offsets_;
    mfem::HypreParMatrix &pressure_mass_;
    double pressure_scale_;

    const mfem::BlockOperator *jacobian_ = nullptr;

    mutable std::unique_ptr<mfem::BlockDiagonalPreconditioner> block_diagonal_;
    mutable std::unique_ptr<mfem::HypreBoomerAMG> displacement_amg_;
    mutable std::unique_ptr<mfem::OperatorJacobiSmoother> pressure_jacobi_;
};

class IncompressibleElasticityOperator final : public mfem::Operator
{
public:
    IncompressibleElasticityOperator(
        mfem::Array<mfem::ParFiniteElementSpace *> &spaces,
        mfem::Array<mfem::Array<int> *> &essential_markers,
        const mfem::Array<int> &block_true_offsets,
        mfem::Coefficient &shear_modulus,
        mfem::Vector displacement_rhs,
        mfem::Vector pressure_rhs,
        double bulk_modulus)
        : mfem::Operator(block_true_offsets[block_true_offsets.Size() - 1]),
          block_true_offsets_(block_true_offsets),
          rhs_true_(height),
          newton_solver_(spaces[0]->GetComm()),
          linear_solver_(spaces[0]->GetComm())
    {
        spaces.Copy(spaces_);

        h_form_ = std::make_unique<mfem::ParBlockNonlinearForm>(spaces_);
        h_form_->AddDomainIntegrator(new mfem::IncompressibleNeoHookeanIntegrator(shear_modulus));

        mfem::Array<mfem::Vector *> rhs_blocks(2);
        rhs_blocks[0] = &displacement_rhs;
        rhs_blocks[1] = &pressure_rhs;

        displacement_ess_tdof_.SetSize(0);
        pressure_ess_tdof_.SetSize(0);
        if (essential_markers[0] != nullptr && essential_markers[0]->Size() > 0)
        {
            spaces_[0]->GetEssentialTrueDofs(*essential_markers[0], displacement_ess_tdof_);
        }
        if (spaces_[1]->TrueVSize() > 0)
        {
            // Fix one pressure dof to remove the constant-pressure null space.
            pressure_ess_tdof_.SetSize(1);
            pressure_ess_tdof_[0] = 0;
            pressure_gauge_fix_applied_ = true;
        }

        mfem::Array<mfem::Array<int> *> essential_tdof_lists(2);
        essential_tdof_lists[0] = &displacement_ess_tdof_;
        essential_tdof_lists[1] = &pressure_ess_tdof_;
        h_form_->SetEssentialTrueDofs(essential_tdof_lists, rhs_blocks);

        mfem::BlockVector rhs_block(block_true_offsets_);
        rhs_block = 0.0;
        rhs_block.GetBlock(0) = displacement_rhs;
        rhs_block.GetBlock(1) = pressure_rhs;
        rhs_true_ = rhs_block;

        mfem::ParBilinearForm pressure_mass_form(spaces_[1]);
        mfem::ConstantCoefficient one_coeff(1.0);
        pressure_mass_form.AddDomainIntegrator(new mfem::MassIntegrator(one_coeff));
        pressure_mass_form.Assemble();
        pressure_mass_form.Finalize();
        pressure_mass_.reset(pressure_mass_form.ParallelAssemble());
        if (pressure_mass_ == nullptr)
        {
            throw std::runtime_error("Failed to assemble pressure mass matrix for incompressible elasticity preconditioner.");
        }

        // Keep the pressure block scaling neutral; aggressive scaling can
        // destabilize MINRES for high-contrast material parameters.
        const double pressure_scale = 1.0;
        preconditioner_ = std::make_unique<IncompressibleElasticityPreconditioner>(
            spaces_,
            *pressure_mass_,
            block_true_offsets_,
            pressure_scale
        );

        linear_solver_.iterative_mode = false;
        linear_solver_.SetRelTol(1.0e-10);
        linear_solver_.SetAbsTol(0.0);
        linear_solver_.SetMaxIter(400);
        linear_solver_.SetPrintLevel(0);
        linear_solver_.SetPreconditioner(*preconditioner_);

        newton_solver_.iterative_mode = true;
        newton_solver_.SetSolver(linear_solver_);
        newton_solver_.SetOperator(*this);
        newton_solver_.SetRelTol(1.0e-8);
        newton_solver_.SetAbsTol(1.0e-10);
        newton_solver_.SetMaxIter(60);
        newton_solver_.SetPrintLevel(0);
    }

    void Solve(mfem::Vector &state) const
    {
        mfem::Vector zero;
        newton_solver_.Mult(zero, state);
        if (!newton_solver_.GetConverged())
        {
            throw std::runtime_error("IncompressibleElasticity Newton solver did not converge.");
        }
    }

    void Mult(const mfem::Vector &x, mfem::Vector &y) const override
    {
        h_form_->Mult(x, y);
        y -= rhs_true_;
    }

    mfem::Operator &GetGradient(const mfem::Vector &x) const override
    {
        return h_form_->GetGradient(x);
    }

    int NewtonIterations() const
    {
        return newton_solver_.GetNumIterations();
    }

    int LinearIterations() const
    {
        return linear_solver_.GetNumIterations();
    }

    bool PressureGaugeFixApplied() const
    {
        return pressure_gauge_fix_applied_;
    }

    double Energy(const mfem::Vector &x) const
    {
        return h_form_->GetEnergy(x);
    }

private:
    mfem::Array<mfem::ParFiniteElementSpace *> spaces_;
    mfem::Array<int> block_true_offsets_;
    mutable mfem::Vector rhs_true_;

    std::unique_ptr<mfem::ParBlockNonlinearForm> h_form_;
    std::unique_ptr<mfem::HypreParMatrix> pressure_mass_;

    mutable mfem::NewtonSolver newton_solver_;
    mutable mfem::MINRESSolver linear_solver_;
    std::unique_ptr<IncompressibleElasticityPreconditioner> preconditioner_;
    mfem::Array<int> displacement_ess_tdof_;
    mfem::Array<int> pressure_ess_tdof_;
    bool pressure_gauge_fix_applied_ = false;
};
#endif
} // namespace

namespace autosage
{
const char *IncompressibleElasticitySolver::Name() const
{
    return "IncompressibleElasticity";
}

IncompressibleElasticitySolver::IncompressibleElasticityConfig IncompressibleElasticitySolver::ParseConfig(
    const json &config,
    int dimension,
    int max_boundary_attribute) const
{
    if (!config.contains("shear_modulus") || !config["shear_modulus"].is_number())
    {
        throw std::runtime_error("config.shear_modulus is required and must be numeric.");
    }
    if (!config.contains("bulk_modulus") || !config["bulk_modulus"].is_number())
    {
        throw std::runtime_error("config.bulk_modulus is required and must be numeric.");
    }

    IncompressibleElasticityConfig parsed;
    parsed.shear_modulus = config["shear_modulus"].get<double>();
    parsed.bulk_modulus = config["bulk_modulus"].get<double>();
    if (!(parsed.shear_modulus > 0.0))
    {
        throw std::runtime_error("config.shear_modulus must be > 0.");
    }
    if (!(parsed.bulk_modulus > 0.0))
    {
        throw std::runtime_error("config.bulk_modulus must be > 0.");
    }

    if (config.contains("order"))
    {
        if (!config["order"].is_number_integer())
        {
            throw std::runtime_error("config.order must be an integer when provided.");
        }
        parsed.order = config["order"].get<int>();
        if (parsed.order < 1)
        {
            throw std::runtime_error("config.order must be >= 1.");
        }
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.essential_boundary_marker.assign(boundary_slots, 0);

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }
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
        if (type == "fixed")
        {
            parsed.essential_boundary_marker[attribute - 1] = 1;
            continue;
        }
        if (type == "traction")
        {
            TractionBoundary traction;
            traction.attribute = attribute;
            traction.value = parse_vector_value(
                bc.contains("value") ? bc["value"] : json(nullptr),
                "config.bcs[].value",
                dimension,
                true
            );
            parsed.tractions.push_back(std::move(traction));
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be fixed or traction.");
    }

    if (boundary_slots > 0)
    {
        const bool has_fixed = std::any_of(
            parsed.essential_boundary_marker.begin(),
            parsed.essential_boundary_marker.end(),
            [](int marker) { return marker != 0; }
        );
        if (!has_fixed)
        {
            throw std::runtime_error("config.bcs must include at least one fixed boundary condition.");
        }
    }

    return parsed;
}

SolveSummary IncompressibleElasticitySolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dimension = mesh.Dimension();
    if (dimension <= 0 || dimension > 3)
    {
        throw std::runtime_error("IncompressibleElasticity supports mesh dimensions 1, 2, or 3.");
    }

    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const IncompressibleElasticityConfig parsed = ParseConfig(config, dimension, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);

    const int pressure_order = std::max(0, parsed.order - 1);
    mfem::H1_FECollection displacement_fec(parsed.order, dimension);
    mfem::L2_FECollection pressure_fec(pressure_order, dimension);

    mfem::ParFiniteElementSpace displacement_space(
        &pmesh,
        &displacement_fec,
        dimension,
        mfem::Ordering::byVDIM
    );
    mfem::ParFiniteElementSpace pressure_space(&pmesh, &pressure_fec);

    mfem::Array<mfem::ParFiniteElementSpace *> spaces(2);
    spaces[0] = &displacement_space;
    spaces[1] = &pressure_space;

    mfem::Array<int> block_true_offsets(3);
    block_true_offsets[0] = 0;
    block_true_offsets[1] = displacement_space.TrueVSize();
    block_true_offsets[2] = pressure_space.TrueVSize();
    block_true_offsets.PartialSum();

    mfem::Array<int> displacement_ess_bdr(max_boundary_attribute);
    mfem::Array<int> pressure_ess_bdr(max_boundary_attribute);
    displacement_ess_bdr = 0;
    pressure_ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        displacement_ess_bdr[i] = parsed.essential_boundary_marker[i];
    }

    mfem::Array<mfem::Array<int> *> essential_markers(2);
    essential_markers[0] = &displacement_ess_bdr;
    essential_markers[1] = &pressure_ess_bdr;

    mfem::ParGridFunction configuration(&displacement_space);
    mfem::ParGridFunction reference_configuration_gf(&displacement_space);
    mfem::ParGridFunction displacement(&displacement_space);
    mfem::ParGridFunction pressure(&pressure_space);
    mfem::VectorFunctionCoefficient reference_coeff(dimension, reference_configuration);
    configuration.ProjectCoefficient(reference_coeff);
    reference_configuration_gf.ProjectCoefficient(reference_coeff);
    pressure = 0.0;

    mfem::ParLinearForm displacement_rhs_form(&displacement_space);
    std::vector<std::unique_ptr<mfem::VectorConstantCoefficient>> traction_coeffs;
    std::vector<mfem::Array<int>> traction_markers;
    for (const TractionBoundary &traction : parsed.tractions)
    {
        mfem::Vector traction_vector(dimension);
        for (int i = 0; i < dimension; ++i)
        {
            traction_vector[i] = traction.value[i];
        }
        traction_coeffs.push_back(std::make_unique<mfem::VectorConstantCoefficient>(traction_vector));
        traction_markers.emplace_back(max_boundary_attribute);
        traction_markers.back() = 0;
        traction_markers.back()[traction.attribute - 1] = 1;
        displacement_rhs_form.AddBoundaryIntegrator(
            new mfem::VectorBoundaryLFIntegrator(*traction_coeffs.back()),
            traction_markers.back()
        );
    }
    displacement_rhs_form.Assemble();

    mfem::Vector displacement_rhs_true(displacement_space.TrueVSize());
    displacement_rhs_form.ParallelAssemble(displacement_rhs_true);
    mfem::Vector pressure_rhs_true(pressure_space.TrueVSize());
    pressure_rhs_true = 0.0;

    mfem::BlockVector state(block_true_offsets);
    configuration.GetTrueDofs(state.GetBlock(0));
    pressure.GetTrueDofs(state.GetBlock(1));

    mfem::ConstantCoefficient shear_modulus_coeff(parsed.shear_modulus);
    IncompressibleElasticityOperator oper(
        spaces,
        essential_markers,
        block_true_offsets,
        shear_modulus_coeff,
        displacement_rhs_true,
        pressure_rhs_true,
        parsed.bulk_modulus
    );

    oper.Solve(state);

    configuration.Distribute(&(state.GetBlock(0)));
    pressure.Distribute(&(state.GetBlock(1)));
    subtract(configuration, reference_configuration_gf, displacement);

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
    paraview.RegisterField("pressure", &pressure);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# incompressible elasticity displacement/pressure written to " << collection_name << ".pvd\n";

    mfem::Vector residual(state.Size());
    oper.Mult(state, residual);

    SolveSummary summary;
    summary.energy = oper.Energy(state);
    summary.iterations = oper.NewtonIterations();
    summary.error_norm = std::sqrt(mfem::InnerProduct(displacement_space.GetComm(), residual, residual));
    summary.dimension = dimension;
    if (!std::isfinite(summary.error_norm))
    {
        throw std::runtime_error("IncompressibleElasticity residual norm is non-finite.");
    }

    const fs::path metadata_path = fs::path(context.working_directory) / "incompressible_elasticity.json";
    const json metadata = {
        {"solver_class", "IncompressibleElasticity"},
        {"solver_backend", "newton_minres_blockdiag"},
        {"dimension", dimension},
        {"order", parsed.order},
        {"pressure_order", pressure_order},
        {"shear_modulus", parsed.shear_modulus},
        {"bulk_modulus", parsed.bulk_modulus},
        {"traction_boundaries", static_cast<int>(parsed.tractions.size())},
        {"pressure_gauge_fix_applied", oper.PressureGaugeFixApplied()},
        {"newton_iterations", oper.NewtonIterations()},
        {"linear_iterations", oper.LinearIterations()},
        {"residual_norm", summary.error_norm}
    };
    std::ofstream metadata_out(metadata_path);
    if (!metadata_out)
    {
        throw std::runtime_error("Unable to write incompressible_elasticity.json.");
    }
    metadata_out << metadata.dump(2);

    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("IncompressibleElasticity solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
