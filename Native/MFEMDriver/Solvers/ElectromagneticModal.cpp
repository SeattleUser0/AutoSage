// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "ElectromagneticModal.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>

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
} // namespace

namespace autosage
{
const char *ElectromagneticModalSolver::Name() const
{
    return "ElectromagneticModal";
}

ElectromagneticModalSolver::ElectromagneticModalConfig ElectromagneticModalSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    if (!config.contains("permittivity") || !config["permittivity"].is_number())
    {
        throw std::runtime_error("config.permittivity is required and must be numeric.");
    }
    if (!config.contains("permeability") || !config["permeability"].is_number())
    {
        throw std::runtime_error("config.permeability is required and must be numeric.");
    }
    if (!config.contains("num_modes") || !config["num_modes"].is_number_integer())
    {
        throw std::runtime_error("config.num_modes is required and must be an integer.");
    }
    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    ElectromagneticModalConfig parsed;
    parsed.permittivity = config["permittivity"].get<double>();
    parsed.permeability = config["permeability"].get<double>();
    parsed.num_modes = config["num_modes"].get<int>();
    if (!(parsed.permittivity > 0.0))
    {
        throw std::runtime_error("config.permittivity must be > 0.");
    }
    if (!(parsed.permeability > 0.0))
    {
        throw std::runtime_error("config.permeability must be > 0.");
    }
    if (parsed.num_modes <= 0)
    {
        throw std::runtime_error("config.num_modes must be > 0.");
    }
    if (parsed.num_modes > 64)
    {
        throw std::runtime_error("config.num_modes must be <= 64.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.perfect_conductor_marker.assign(boundary_slots, 0);
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
        if (type == "perfect_conductor" || type == "perfect-conductor" || type == "perfectconductor")
        {
            parsed.perfect_conductor_marker[attribute - 1] = 1;
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be perfect_conductor.");
    }

    if (boundary_slots > 0)
    {
        const bool has_perfect_conductor = std::any_of(
            parsed.perfect_conductor_marker.begin(),
            parsed.perfect_conductor_marker.end(),
            [](int marker) { return marker != 0; }
        );
        if (!has_perfect_conductor)
        {
            throw std::runtime_error("config.bcs must include at least one perfect_conductor boundary condition.");
        }
    }

    return parsed;
}

SolveSummary ElectromagneticModalSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    const ElectromagneticModalConfig parsed = ParseConfig(config, max_boundary_attribute);

    mfem::ND_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.perfect_conductor_marker[i];
    }

    mfem::ConstantCoefficient mu_inverse_coeff(1.0 / parsed.permeability);
    mfem::ConstantCoefficient epsilon_coeff(parsed.permittivity);

    mfem::ParBilinearForm stiffness_form(&fespace);
    stiffness_form.AddDomainIntegrator(new mfem::CurlCurlIntegrator(mu_inverse_coeff));
    stiffness_form.Assemble();
    stiffness_form.EliminateEssentialBCDiag(ess_bdr, 1.0);
    stiffness_form.Finalize();
    std::unique_ptr<mfem::HypreParMatrix> stiffness(stiffness_form.ParallelAssemble());

    mfem::ParBilinearForm mass_form(&fespace);
    mass_form.AddDomainIntegrator(new mfem::VectorFEMassIntegrator(epsilon_coeff));
    mass_form.Assemble();
    mass_form.EliminateEssentialBCDiag(ess_bdr, std::numeric_limits<mfem::real_t>::min());
    mass_form.Finalize();
    std::unique_ptr<mfem::HypreParMatrix> mass(mass_form.ParallelAssemble());

    mfem::HypreAMS ams(*stiffness, &fespace);
    ams.SetPrintLevel(0);
    ams.SetSingularProblem();

    mfem::HypreLOBPCG lobpcg(MPI_COMM_WORLD);
    lobpcg.SetNumModes(parsed.num_modes);
    lobpcg.SetRandomSeed(75);
    lobpcg.SetPreconditioner(ams);
    lobpcg.SetMaxIter(200);
    lobpcg.SetTol(1.0e-8);
    lobpcg.SetPrecondUsageMode(1);
    lobpcg.SetPrintLevel(0);
    lobpcg.SetMassMatrix(*mass);
    lobpcg.SetOperator(*stiffness);
    lobpcg.Solve();

    mfem::Array<mfem::real_t> eigenvalues;
    lobpcg.GetEigenvalues(eigenvalues);
    if (eigenvalues.Size() == 0)
    {
        throw std::runtime_error("HypreLOBPCG did not return any eigenvalues.");
    }
    for (int i = 0; i < eigenvalues.Size(); ++i)
    {
        if (!std::isfinite(static_cast<double>(eigenvalues[i])))
        {
            throw std::runtime_error(
                "HypreLOBPCG returned non-finite eigenvalues for ElectromagneticModal."
            );
        }
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
    paraview.RegisterField("electric_mode_1", &first_mode);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# electromagnetic mode fields written to " << collection_name << ".pvd\n";

    const fs::path modes_path = fs::path(context.working_directory) / "electromagnetic_modes.json";
    json modes_data;
    modes_data["solver_class"] = "ElectromagneticModal";
    modes_data["solver_backend"] = "lobpcg";
    modes_data["permittivity"] = parsed.permittivity;
    modes_data["permeability"] = parsed.permeability;
    modes_data["eigenvalues"] = json::array();
    modes_data["resonant_frequencies_rad_s"] = json::array();
    for (int i = 0; i < eigenvalues.Size(); ++i)
    {
        const double eigenvalue = static_cast<double>(eigenvalues[i]);
        modes_data["eigenvalues"].push_back(eigenvalue);
        modes_data["resonant_frequencies_rad_s"].push_back(std::sqrt(std::max(0.0, eigenvalue)));
    }
    std::ofstream modes_out(modes_path);
    if (!modes_out)
    {
        throw std::runtime_error("Unable to write electromagnetic_modes.json.");
    }
    modes_out << modes_data.dump(2);

    mfem::Vector residual_data(stiffness->GetNumRows());
    mfem::HypreParVector residual(
        stiffness->GetComm(),
        stiffness->GetGlobalNumRows(),
        residual_data,
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
        throw std::runtime_error("ElectromagneticModal residual norm is non-finite.");
    }
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("ElectromagneticModal solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
