// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace autosage
{
class HyperelasticSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct TractionBoundary
    {
        int attribute = 0;
        std::vector<double> value;
    };

    struct HyperelasticConfig
    {
        double shear_modulus = 50'000.0;
        double bulk_modulus = 100'000.0;
        std::vector<int> essential_boundary_marker;
        std::vector<TractionBoundary> tractions;
        std::vector<double> body_force;
    };

    HyperelasticConfig ParseConfig(
        const nlohmann::json &config,
        int dimension,
        int max_boundary_attribute) const;
};
} // namespace autosage
