// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#pragma once

#include "NavierStokes.hpp"

#include <nlohmann/json.hpp>

#include <optional>
#include <vector>

namespace autosage
{
class ElectromagneticScatteringSolver final : public PhysicsSolver
{
public:
    const char *Name() const override;
    SolveSummary Run(
        mfem::Mesh &mesh,
        const nlohmann::json &config,
        const SolverExecutionContext &context) override;

private:
    struct SourceCurrent
    {
        std::vector<int> attributes;
        std::vector<double> j_real;
        std::vector<double> j_imag;
    };

    struct ScatteringConfig
    {
        double frequency = 0.0;
        double angular_frequency = 0.0;
        double permittivity = 0.0;
        double permeability = 0.0;
        std::vector<int> pml_attributes;
        std::optional<SourceCurrent> source_current;
        std::vector<int> perfect_conductor_marker;
    };

    ScatteringConfig ParseConfig(
        const nlohmann::json &config,
        int dimension,
        int max_element_attribute,
        int max_boundary_attribute) const;
};
} // namespace autosage
