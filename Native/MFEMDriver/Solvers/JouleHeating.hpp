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
class JouleHeatingSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct ParsedConfig
    {
        double electrical_conductivity = 0.0;
        double thermal_conductivity = 0.0;
        double heat_capacity = 0.0;
        double dt = 0.0;
        double t_final = 0.0;
        int output_interval_steps = 1;
        std::vector<int> electric_marker;
        std::vector<double> electric_values;
        std::vector<int> thermal_marker;
        std::vector<double> thermal_values;
    };

    ParsedConfig ParseConfig(const nlohmann::json &config, int max_boundary_attribute) const;
};
} // namespace autosage
