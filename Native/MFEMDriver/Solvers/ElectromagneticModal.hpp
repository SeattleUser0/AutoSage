// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace autosage
{
class ElectromagneticModalSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct ElectromagneticModalConfig
    {
        double permittivity = 0.0;
        double permeability = 0.0;
        int num_modes = 0;
        std::vector<int> perfect_conductor_marker;
    };

    ElectromagneticModalConfig ParseConfig(
        const nlohmann::json &config,
        int max_boundary_attribute) const;
};
} // namespace autosage
