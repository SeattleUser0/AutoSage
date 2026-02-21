// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace autosage
{
class CompressibleEulerSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct PrimitiveState
    {
        double density = 1.0;
        double velocity_x = 0.0;
        double pressure = 1.0;
    };

    struct CompressibleEulerConfig
    {
        double specific_heat_ratio = 1.4;
        double dt = 1.0e-4;
        double t_final = 2.0;
        int order = 1;
        int output_interval_steps = 10;
        PrimitiveState left_state;
        PrimitiveState right_state{0.125, 0.0, 0.1};
        std::vector<int> slip_wall_marker;
    };

    CompressibleEulerConfig ParseConfig(
        const nlohmann::json &config,
        int max_boundary_attribute) const;
};
} // namespace autosage
