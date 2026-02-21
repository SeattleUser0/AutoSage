// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <string>
#include <vector>

namespace autosage
{
class ElastodynamicsSolver final : public PhysicsSolver
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
        std::vector<double> displacement;
        std::vector<double> velocity;
    };

    struct TimeVaryingLoadBoundary
    {
        int attribute = 0;
        std::vector<double> value;
        double frequency = 1.0;
    };

    struct ElastodynamicsConfig
    {
        double density = 7800.0;
        double youngs_modulus = 2.0e11;
        double poisson_ratio = 0.3;
        double dt = 0.001;
        double t_final = 0.1;
        int order = 1;
        int output_interval_steps = 1;
        InitialCondition initial_condition;
        std::vector<int> fixed_boundary_marker;
        std::vector<TimeVaryingLoadBoundary> loads;
    };

    ElastodynamicsConfig ParseConfig(
        const nlohmann::json &config,
        int dim,
        int max_boundary_attribute) const;
};
} // namespace autosage
