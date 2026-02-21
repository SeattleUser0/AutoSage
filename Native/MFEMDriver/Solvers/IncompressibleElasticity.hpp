// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace autosage
{
class IncompressibleElasticitySolver final : public PhysicsSolver
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

    struct IncompressibleElasticityConfig
    {
        double shear_modulus = 50'000.0;
        double bulk_modulus = 1.0e9;
        int order = 2;
        std::vector<int> essential_boundary_marker;
        std::vector<TractionBoundary> tractions;
    };

    IncompressibleElasticityConfig ParseConfig(
        const nlohmann::json &config,
        int dimension,
        int max_boundary_attribute) const;
};
} // namespace autosage
