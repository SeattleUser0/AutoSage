// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace autosage
{
class SurfacePDESolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct SurfacePDEConfig
    {
        double diffusion_coefficient = 1.0;
        double source_term = 0.0;
        bool is_closed_surface = false;
        std::vector<int> fixed_marker;
        std::vector<double> fixed_values;
    };

    SurfacePDEConfig ParseConfig(
        const nlohmann::json &config,
        int max_boundary_attribute) const;
};
} // namespace autosage
