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
class AcousticWaveSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct AcousticWaveConfig
    {
        double wave_speed = 343.0;
        double dt = 0.001;
        double t_final = 0.5;
        double initial_amplitude = 1.0;
        std::vector<double> initial_center;
        std::vector<int> rigid_wall_marker;
    };

    AcousticWaveConfig ParseConfig(const nlohmann::json &config, int max_boundary_attribute, int dim) const;
};
} // namespace autosage
