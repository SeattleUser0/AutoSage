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
class LinearElasticitySolver final : public PhysicsSolver
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

    struct ParsedConfig
    {
        std::vector<double> lambda_by_attribute;
        std::vector<double> mu_by_attribute;
        std::vector<int> essential_boundary_marker;
        std::vector<TractionBoundary> tractions;
        std::vector<double> body_force;
    };

    ParsedConfig ParseConfig(
        const nlohmann::json &config,
        int dimension,
        int max_domain_attribute,
        int max_boundary_attribute) const;
};
} // namespace autosage
