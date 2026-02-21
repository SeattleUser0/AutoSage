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
class HeatTransferSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct HeatBoundaryCondition
    {
        int attribute = 0;
        std::string type;
        double value = 0.0;
    };

    struct HeatConfig
    {
        double conductivity = 1.0;
        double specific_heat = 1.0;
        double initial_temperature = 293.15;
        double source = 0.0;
        double dt = 0.01;
        double t_final = 1.0;
        int output_interval_steps = 10;
        std::vector<int> fixed_temperature_marker;
        std::vector<double> fixed_temperature_values;
        std::vector<double> heat_flux_values;
    };

    HeatConfig ParseConfig(
        const nlohmann::json &config,
        int max_boundary_attribute) const;
};
} // namespace autosage
