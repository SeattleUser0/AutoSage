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
class MagnetostaticsSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct MagnetostaticsConfig
    {
        double permeability = 0.0;
        std::vector<double> current_density;
        std::vector<int> magnetic_insulation_marker;
    };

    MagnetostaticsConfig ParseConfig(
        const nlohmann::json &config,
        int space_dimension,
        int max_boundary_attribute) const;
};
} // namespace autosage
