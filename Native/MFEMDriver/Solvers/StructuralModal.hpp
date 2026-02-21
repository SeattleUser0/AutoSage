// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace autosage
{
class StructuralModalSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct StructuralModalConfig
    {
        double density = 7800.0;
        double youngs_modulus = 2.0e11;
        double poisson_ratio = 0.3;
        int num_modes = 10;
        std::vector<int> fixed_marker;
    };

    StructuralModalConfig ParseConfig(const nlohmann::json &config, int max_boundary_attribute) const;
};
} // namespace autosage
