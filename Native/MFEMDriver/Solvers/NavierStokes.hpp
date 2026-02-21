// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include <mfem.hpp>
#include <nlohmann/json.hpp>

#include <optional>
#include <string>
#include <vector>

namespace autosage
{
struct SolveSummary
{
    double energy = 0.0;
    int iterations = 0;
    double error_norm = 0.0;
    int dimension = 0;
};

struct SolverExecutionContext
{
    std::string working_directory;
    std::string vtk_path;
};

class PhysicsSolver
{
public:
    virtual ~PhysicsSolver() = default;

    virtual const char *Name() const = 0;
    virtual SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) = 0;
};

class NavierStokesSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct BoundaryCondition
    {
        int attr = 0;
        std::string type;
        std::vector<double> velocity;
        std::optional<double> pressure;
    };

    struct NavierConfig
    {
        double viscosity = 1.0e-3;
        double density = 1.0;
        double t_final = 0.1;
        double dt = 0.01;
        int output_interval_steps = 1;
        std::vector<double> body_force;
        std::vector<BoundaryCondition> bcs;
    };

    NavierConfig ParseConfig(const nlohmann::json &config, int dim, int max_boundary_attribute) const;
};
} // namespace autosage
