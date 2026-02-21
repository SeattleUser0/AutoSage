// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "StructuralModal.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <random>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace
{
std::string to_lower(std::string value)
{
    std::transform(
        value.begin(),
        value.end(),
        value.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

std::pair<double, double> lame_from_material(double youngs_modulus, double poisson_ratio)
{
    if (youngs_modulus <= 0.0)
    {
        throw std::runtime_error("config.youngs_modulus must be > 0.");
    }
    if (poisson_ratio <= -1.0 || poisson_ratio >= 0.5)
    {
        throw std::runtime_error("config.poisson_ratio must be in (-1, 0.5).");
    }
    const double lambda = (youngs_modulus * poisson_ratio) /
                          ((1.0 + poisson_ratio) * (1.0 - 2.0 * poisson_ratio));
    const double mu = youngs_modulus / (2.0 * (1.0 + poisson_ratio));
    return {lambda, mu};
}

bool is_truthy_env_value(std::string value)
{
    value.erase(
        std::remove_if(
            value.begin(),
            value.end(),
            [](unsigned char c) { return std::isspace(c) != 0; }
        ),
        value.end()
    );
    value = to_lower(value);
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

bool should_force_structural_modal_fallback()
{
    const char *raw_value = std::getenv("AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK");
    if (raw_value == nullptr)
    {
        return false;
    }
    return is_truthy_env_value(raw_value);
}
} // namespace

namespace autosage
{
const char *StructuralModalSolver::Name() const
{
    return "StructuralModal";
}

StructuralModalSolver::StructuralModalConfig StructuralModalSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    if (!config.contains("density") || !config["density"].is_number())
    {
        throw std::runtime_error("config.density is required and must be numeric.");
    }
    if (!config.contains("youngs_modulus") || !config["youngs_modulus"].is_number())
    {
        throw std::runtime_error("config.youngs_modulus is required and must be numeric.");
    }
    if (!config.contains("poisson_ratio") || !config["poisson_ratio"].is_number())
    {
        throw std::runtime_error("config.poisson_ratio is required and must be numeric.");
    }
    if (!config.contains("num_modes") || !config["num_modes"].is_number_integer())
    {
        throw std::runtime_error("config.num_modes is required and must be an integer.");
    }
    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    StructuralModalConfig parsed;
    parsed.density = config["density"].get<double>();
    if (!(parsed.density > 0.0))
    {
        throw std::runtime_error("config.density must be > 0.");
    }
    parsed.youngs_modulus = config["youngs_modulus"].get<double>();
    parsed.poisson_ratio = config["poisson_ratio"].get<double>();
    // validates range and finite formulas
    (void)lame_from_material(parsed.youngs_modulus, parsed.poisson_ratio);

    parsed.num_modes = config["num_modes"].get<int>();
    if (parsed.num_modes <= 0)
    {
        throw std::runtime_error("config.num_modes must be > 0.");
    }
    if (parsed.num_modes > 64)
    {
        throw std::runtime_error("config.num_modes must be <= 64.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.fixed_marker.assign(boundary_slots, 0);
    if (boundary_slots == 0 && !config["bcs"].empty())
    {
        throw std::runtime_error("Mesh has no boundary attributes but config.bcs was provided.");
    }

    for (const auto &bc : config["bcs"])
    {
        if (!bc.is_object())
        {
            throw std::runtime_error("config.bcs entries must be objects.");
        }
        if (!bc.contains("attribute") || !bc["attribute"].is_number_integer())
        {
            throw std::runtime_error("config.bcs[].attribute is required and must be an integer.");
        }
        const int attribute = bc["attribute"].get<int>();
        if (attribute <= 0)
        {
            throw std::runtime_error("config.bcs[].attribute must be > 0.");
        }
        if (max_boundary_attribute > 0 && attribute > max_boundary_attribute)
        {
            throw std::runtime_error("config.bcs[].attribute exceeds mesh boundary attribute count.");
        }
        const std::string type = to_lower(bc.value("type", ""));
        if (type != "fixed")
        {
            throw std::runtime_error("config.bcs[].type must be fixed.");
        }
        parsed.fixed_marker[attribute - 1] = 1;
    }

    if (max_boundary_attribute > 0)
    {
        const bool has_fixed = std::any_of(
            parsed.fixed_marker.begin(),
            parsed.fixed_marker.end(),
            [](int marker) { return marker != 0; }
        );
        if (!has_fixed)
        {
            throw std::runtime_error("config.bcs must include at least one fixed boundary condition.");
        }
    }

    return parsed;
}

SolveSummary StructuralModalSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const StructuralModalConfig parsed = ParseConfig(config, max_boundary_attribute);
    const auto lame = lame_from_material(parsed.youngs_modulus, parsed.poisson_ratio);
    const double lame_lambda = lame.first;
    const double lame_mu = lame.second;

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec, dim, mfem::Ordering::byVDIM);

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.fixed_marker[i];
    }

    mfem::ConstantCoefficient lambda_coeff(lame_lambda);
    mfem::ConstantCoefficient mu_coeff(lame_mu);
    mfem::ConstantCoefficient density_coeff(parsed.density);

    mfem::ParBilinearForm stiffness_form(&fespace);
    stiffness_form.AddDomainIntegrator(new mfem::ElasticityIntegrator(lambda_coeff, mu_coeff));
    stiffness_form.Assemble();
    stiffness_form.EliminateEssentialBCDiag(ess_bdr, 1.0);
    stiffness_form.Finalize();
    std::unique_ptr<mfem::HypreParMatrix> stiffness(stiffness_form.ParallelAssemble());

    mfem::ParBilinearForm mass_form(&fespace);
    mass_form.AddDomainIntegrator(new mfem::VectorMassIntegrator(density_coeff));
    mass_form.Assemble();
    // Shift eliminated dofs to very large generalized eigenvalues, matching ex12.
    mass_form.EliminateEssentialBCDiag(ess_bdr, std::numeric_limits<mfem::real_t>::min());
    mass_form.Finalize();
    std::unique_ptr<mfem::HypreParMatrix> mass(mass_form.ParallelAssemble());

    mfem::HypreBoomerAMG amg(*stiffness);
    amg.SetPrintLevel(0);
    amg.SetElasticityOptions(&fespace);

    auto solve_with_inverse_iteration_fallback = [&](const std::string &failure_reason) -> SolveSummary
    {
        mfem::CGSolver cg(stiffness->GetComm());
        cg.SetRelTol(1.0e-10);
        cg.SetAbsTol(0.0);
        cg.SetMaxIter(500);
        cg.SetPrintLevel(0);
        cg.SetPreconditioner(amg);
        cg.SetOperator(*stiffness);

        auto m_inner = [&](const mfem::HypreParVector &u, const mfem::HypreParVector &v) -> double
        {
            mfem::HypreParVector mass_times_v(*mass);
            mass->Mult(v, mass_times_v);
            return mfem::InnerProduct(fespace.GetComm(), u, mass_times_v);
        };

        auto orthogonalize_against_modes = [&](
            mfem::HypreParVector &candidate,
            const std::vector<mfem::HypreParVector> &modes)
        {
            for (const auto &mode : modes)
            {
                const double projection = m_inner(candidate, mode);
                if (std::isfinite(projection))
                {
                    candidate.Add(-projection, mode);
                }
            }
        };

        auto normalize_m = [&](mfem::HypreParVector &vector)
        {
            const double norm_sq = m_inner(vector, vector);
            if (!(norm_sq > 0.0) || !std::isfinite(norm_sq))
            {
                throw std::runtime_error("Inverse-iteration fallback produced a non-positive M-norm.");
            }
            vector *= 1.0 / std::sqrt(norm_sq);
        };

        std::mt19937 rng(75);
        std::uniform_real_distribution<double> dist(-1.0, 1.0);

        std::vector<mfem::HypreParVector> modes;
        std::vector<double> eigenvalues_fallback;
        modes.reserve(parsed.num_modes);
        eigenvalues_fallback.reserve(parsed.num_modes);

        for (int mode_index = 0; mode_index < parsed.num_modes; ++mode_index)
        {
            mfem::HypreParVector mode(*stiffness);
            bool initialized = false;
            for (int attempt = 0; attempt < 5; ++attempt)
            {
                for (int i = 0; i < mode.Size(); ++i)
                {
                    mode(i) = dist(rng);
                }
                orthogonalize_against_modes(mode, modes);
                try
                {
                    normalize_m(mode);
                    initialized = true;
                    break;
                }
                catch (const std::exception &)
                {
                    // Re-seed with a new random vector.
                }
            }
            if (!initialized)
            {
                throw std::runtime_error(
                    "Inverse-iteration fallback could not initialize a valid mode vector."
                );
            }

            mfem::HypreParVector rhs(*mass);
            mfem::HypreParVector next_mode(*stiffness);
            mfem::HypreParVector stiffness_times_mode(*stiffness);
            mfem::HypreParVector mass_times_mode(*mass);

            double lambda_estimate = 0.0;
            for (int iter = 0; iter < 250; ++iter)
            {
                mass->Mult(mode, rhs);
                next_mode = 0.0;
                cg.Mult(rhs, next_mode);

                orthogonalize_against_modes(next_mode, modes);
                normalize_m(next_mode);

                stiffness->Mult(next_mode, stiffness_times_mode);
                mass->Mult(next_mode, mass_times_mode);

                const double denominator = mfem::InnerProduct(fespace.GetComm(), next_mode, mass_times_mode);
                const double numerator = mfem::InnerProduct(
                    fespace.GetComm(),
                    next_mode,
                    stiffness_times_mode
                );
                if (!(denominator > 0.0) || !std::isfinite(denominator) || !std::isfinite(numerator))
                {
                    throw std::runtime_error(
                        "Inverse-iteration fallback produced an invalid Rayleigh quotient."
                    );
                }

                const double lambda_new = numerator / denominator;
                if (!std::isfinite(lambda_new) || lambda_new <= 0.0)
                {
                    throw std::runtime_error(
                        "Inverse-iteration fallback produced a non-positive eigenvalue estimate."
                    );
                }

                if (iter > 0 &&
                    std::abs(lambda_new - lambda_estimate) <=
                        1.0e-8 * std::max(1.0, std::abs(lambda_estimate)))
                {
                    lambda_estimate = lambda_new;
                    mode = next_mode;
                    break;
                }

                lambda_estimate = lambda_new;
                mode = next_mode;
            }

            modes.push_back(mode);
            eigenvalues_fallback.push_back(lambda_estimate);
        }

        if (modes.empty() || eigenvalues_fallback.empty())
        {
            throw std::runtime_error("Inverse-iteration fallback did not produce any modes.");
        }

        mfem::ParGridFunction first_mode(&fespace);
        first_mode = modes.front();

        const fs::path vtk_path(context.vtk_path);
        const std::string collection_name = vtk_path.stem().empty() ? "solution" : vtk_path.stem().string();
        const std::string output_dir = vtk_path.has_parent_path()
            ? vtk_path.parent_path().string()
            : context.working_directory;
        fs::create_directories(output_dir);

        mfem::ParaViewDataCollection paraview(collection_name, &pmesh);
        paraview.SetPrefixPath(output_dir);
        paraview.SetLevelsOfDetail(1);
        paraview.SetDataFormat(mfem::VTKFormat::ASCII);
        paraview.RegisterField("mode_1", &first_mode);
        paraview.SetCycle(0);
        paraview.SetTime(0.0);
        paraview.Save();

        std::ofstream vtk_stub(context.vtk_path);
        vtk_stub << "# structural mode fields written to " << collection_name
                 << ".pvd (inverse-iteration fallback)\n";

        const fs::path eigenvalues_path = fs::path(context.working_directory) / "structural_modes.json";
        json modal_data;
        modal_data["solver_class"] = "StructuralModal";
        modal_data["solver_backend"] = "inverse_iteration_fallback";
        modal_data["fallback_reason"] = failure_reason;
        modal_data["density"] = parsed.density;
        modal_data["youngs_modulus"] = parsed.youngs_modulus;
        modal_data["poisson_ratio"] = parsed.poisson_ratio;
        modal_data["eigenvalues"] = json::array();
        modal_data["natural_frequencies_rad_s"] = json::array();
        for (double eigenvalue : eigenvalues_fallback)
        {
            modal_data["eigenvalues"].push_back(eigenvalue);
            modal_data["natural_frequencies_rad_s"].push_back(std::sqrt(std::max(0.0, eigenvalue)));
        }
        std::ofstream modal_out(eigenvalues_path);
        if (!modal_out)
        {
            throw std::runtime_error("Unable to write structural_modes.json.");
        }
        modal_out << modal_data.dump(2);

        mfem::Vector residual_data(stiffness->GetNumRows());
        mfem::HypreParVector residual(
            stiffness->GetComm(),
            stiffness->GetGlobalNumRows(),
            residual_data,
            0,
            stiffness->GetRowStarts()
        );
        stiffness->Mult(modes.front(), residual);

        mfem::Vector mx_data(mass->GetNumRows());
        mfem::HypreParVector mx(
            mass->GetComm(),
            mass->GetGlobalNumRows(),
            mx_data,
            0,
            mass->GetRowStarts()
        );
        mass->Mult(modes.front(), mx);
        mx *= eigenvalues_fallback.front();
        residual -= mx;

        SolveSummary summary;
        summary.energy = eigenvalues_fallback.front();
        summary.iterations = static_cast<int>(eigenvalues_fallback.size());
        summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
        if (!std::isfinite(summary.error_norm))
        {
            throw std::runtime_error("Structural modal residual norm is non-finite.");
        }
        summary.dimension = dim;
        return summary;
    };

    mfem::HypreLOBPCG lobpcg(MPI_COMM_WORLD);
    lobpcg.SetNumModes(parsed.num_modes);
    lobpcg.SetRandomSeed(75);
    lobpcg.SetPreconditioner(amg);
    lobpcg.SetMaxIter(200);
    lobpcg.SetTol(1.0e-8);
    lobpcg.SetPrecondUsageMode(1);
    lobpcg.SetPrintLevel(0);
    lobpcg.SetMassMatrix(*mass);
    lobpcg.SetOperator(*stiffness);

    if (should_force_structural_modal_fallback())
    {
        return solve_with_inverse_iteration_fallback(
            "Forced fallback via AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK."
        );
    }

    mfem::Array<mfem::real_t> eigenvalues;
    std::string lobpcg_failure_reason;
    try
    {
        lobpcg.Solve();
        lobpcg.GetEigenvalues(eigenvalues);
        if (eigenvalues.Size() == 0)
        {
            lobpcg_failure_reason = "HypreLOBPCG returned no eigenvalues.";
        }
        else
        {
            for (int i = 0; i < eigenvalues.Size(); ++i)
            {
                if (!std::isfinite(static_cast<double>(eigenvalues[i])))
                {
                    lobpcg_failure_reason = "HypreLOBPCG returned non-finite eigenvalues.";
                    break;
                }
            }
        }
    }
    catch (const std::exception &ex)
    {
        lobpcg_failure_reason = ex.what();
    }
    if (!lobpcg_failure_reason.empty())
    {
        return solve_with_inverse_iteration_fallback(lobpcg_failure_reason);
    }

    mfem::ParGridFunction first_mode(&fespace);
    first_mode = lobpcg.GetEigenvector(0);

    const fs::path vtk_path(context.vtk_path);
    const std::string collection_name = vtk_path.stem().empty() ? "solution" : vtk_path.stem().string();
    const std::string output_dir = vtk_path.has_parent_path()
        ? vtk_path.parent_path().string()
        : context.working_directory;
    fs::create_directories(output_dir);

    mfem::ParaViewDataCollection paraview(collection_name, &pmesh);
    paraview.SetPrefixPath(output_dir);
    paraview.SetLevelsOfDetail(1);
    paraview.SetDataFormat(mfem::VTKFormat::ASCII);
    paraview.RegisterField("mode_1", &first_mode);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# structural mode fields written to " << collection_name << ".pvd\n";

    const fs::path eigenvalues_path = fs::path(context.working_directory) / "structural_modes.json";
    json modal_data;
    modal_data["solver_class"] = "StructuralModal";
    modal_data["density"] = parsed.density;
    modal_data["youngs_modulus"] = parsed.youngs_modulus;
    modal_data["poisson_ratio"] = parsed.poisson_ratio;
    modal_data["eigenvalues"] = json::array();
    modal_data["natural_frequencies_rad_s"] = json::array();
    for (int i = 0; i < eigenvalues.Size(); ++i)
    {
        const double lambda_i = static_cast<double>(eigenvalues[i]);
        modal_data["eigenvalues"].push_back(lambda_i);
        modal_data["natural_frequencies_rad_s"].push_back(std::sqrt(std::max(0.0, lambda_i)));
    }
    std::ofstream modal_out(eigenvalues_path);
    if (!modal_out)
    {
        throw std::runtime_error("Unable to write structural_modes.json.");
    }
    modal_out << modal_data.dump(2);

    mfem::Vector r_data(stiffness->GetNumRows());
    mfem::HypreParVector residual(
        stiffness->GetComm(),
        stiffness->GetGlobalNumRows(),
        r_data,
        0,
        stiffness->GetRowStarts()
    );
    stiffness->Mult(lobpcg.GetEigenvector(0), residual);

    mfem::Vector mx_data(mass->GetNumRows());
    mfem::HypreParVector mx(
        mass->GetComm(),
        mass->GetGlobalNumRows(),
        mx_data,
        0,
        mass->GetRowStarts()
    );
    mass->Mult(lobpcg.GetEigenvector(0), mx);
    mx *= eigenvalues[0];
    residual -= mx;

    SolveSummary summary;
    summary.energy = static_cast<double>(eigenvalues[0]);
    summary.iterations = eigenvalues.Size();
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    if (!std::isfinite(summary.error_norm))
    {
        throw std::runtime_error("Structural modal residual norm is non-finite.");
    }
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("StructuralModal solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
