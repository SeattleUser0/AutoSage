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
class DarcyFlowSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct PressureBoundary
    {
        int attribute = 0;
        double value = 0.0;
    };

    struct DarcyConfig
    {
        double permeability = 0.0;
        double source_term = 0.0;
        std::vector<int> no_flow_marker;
        std::vector<PressureBoundary> fixed_pressure_boundaries;
    };

    DarcyConfig ParseConfig(const nlohmann::json &config, int max_boundary_attribute) const;
};
} // namespace autosage
