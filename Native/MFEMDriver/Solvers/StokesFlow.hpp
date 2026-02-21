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
class StokesFlowSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct InflowBoundary
    {
        int attribute = 0;
        std::vector<double> velocity;
    };

    struct StokesConfig
    {
        double dynamic_viscosity = 0.0;
        std::vector<double> body_force;
        std::vector<int> essential_marker;
        std::vector<InflowBoundary> inflow_boundaries;
    };

    StokesConfig ParseConfig(
        const nlohmann::json &config,
        int dimension,
        int max_boundary_attribute) const;
};
} // namespace autosage
