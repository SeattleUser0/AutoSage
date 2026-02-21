// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace autosage
{
class AdvectionSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct InitialCondition
    {
        std::vector<double> center;
        double radius = 0.5;
        double value = 1.0;
    };

    struct InflowBoundary
    {
        int attribute = 0;
        double value = 0.0;
    };

    struct AdvectionConfig
    {
        std::vector<double> velocity_field;
        double dt = 0.01;
        double t_final = 5.0;
        int order = 1;
        int output_interval_steps = 10;
        InitialCondition initial_condition;
        std::vector<InflowBoundary> inflow_boundaries;
    };

    AdvectionConfig ParseConfig(
        const nlohmann::json &config,
        int dim,
        int max_boundary_attribute) const;
};
} // namespace autosage
