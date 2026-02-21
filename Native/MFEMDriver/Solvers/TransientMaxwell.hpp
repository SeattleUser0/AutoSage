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
class TransientMaxwellSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct InitialCondition
    {
        std::vector<double> center;
        std::vector<double> polarization;
    };

    struct TransientMaxwellConfig
    {
        double permittivity = 8.854e-12;
        double permeability = 1.256e-6;
        double conductivity = 0.0;
        double dt = 1.0e-11;
        double t_final = 1.0e-9;
        int order = 1;
        int output_interval_steps = 10;
        InitialCondition initial_condition;
        std::vector<int> perfect_conductor_marker;
    };

    TransientMaxwellConfig ParseConfig(
        const nlohmann::json &config,
        int space_dimension,
        int max_boundary_attribute) const;
};
} // namespace autosage
