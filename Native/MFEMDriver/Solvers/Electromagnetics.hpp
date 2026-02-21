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
class ElectromagneticsSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct ElectromagneticsConfig
    {
        double permeability = 0.0;
        double kappa = 0.0;
        std::vector<double> current_density;
        std::vector<int> perfect_conductor_marker;
    };

    ElectromagneticsConfig ParseConfig(
        const nlohmann::json &config,
        int space_dimension,
        int max_boundary_attribute) const;
};
} // namespace autosage
