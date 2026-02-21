// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace autosage
{
class EigenvalueSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct EigenvalueConfig
    {
        double material_coefficient = 1.0;
        int num_eigenmodes = 5;
        std::vector<int> fixed_marker;
    };

    EigenvalueConfig ParseConfig(const nlohmann::json &config, int max_boundary_attribute) const;
};
} // namespace autosage
