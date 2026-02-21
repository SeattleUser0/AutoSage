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
class ElectrostaticsSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct ElectrostaticsConfig
    {
        double permittivity = 0.0;
        double charge_density = 0.0;
        std::vector<int> fixed_voltage_marker;
        std::vector<double> fixed_voltage_values;
        std::vector<double> surface_charge_values;
    };

    ElectrostaticsConfig ParseConfig(
        const nlohmann::json &config,
        int max_boundary_attribute) const;
};
} // namespace autosage
