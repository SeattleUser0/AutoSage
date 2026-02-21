// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "Eigenvalue.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
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
} // namespace

namespace autosage
{
const char *EigenvalueSolver::Name() const
{
    return "Eigenvalue";
}

EigenvalueSolver::EigenvalueConfig EigenvalueSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    if (!config.contains("material_coefficient") || !config["material_coefficient"].is_number())
    {
        throw std::runtime_error("config.material_coefficient is required and must be numeric.");
    }
    if (!config.contains("num_eigenmodes") || !config["num_eigenmodes"].is_number_integer())
    {
        throw std::runtime_error("config.num_eigenmodes is required and must be an integer.");
    }
    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    EigenvalueConfig parsed;
    parsed.material_coefficient = config["material_coefficient"].get<double>();
    if (!(parsed.material_coefficient > 0.0))
    {
        throw std::runtime_error("config.material_coefficient must be > 0.");
    }

    parsed.num_eigenmodes = config["num_eigenmodes"].get<int>();
    if (parsed.num_eigenmodes <= 0)
    {
        throw std::runtime_error("config.num_eigenmodes must be > 0.");
    }
    if (parsed.num_eigenmodes > 64)
    {
        throw std::runtime_error("config.num_eigenmodes must be <= 64.");
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

SolveSummary EigenvalueSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const EigenvalueConfig parsed = ParseConfig(config, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.fixed_marker[i];
    }

    mfem::ConstantCoefficient one(1.0);
    mfem::ConstantCoefficient kappa(parsed.material_coefficient);

    mfem::ParBilinearForm stiffness_form(&fespace);
    stiffness_form.AddDomainIntegrator(new mfem::DiffusionIntegrator(kappa));
    if (max_boundary_attribute == 0)
    {
        // Shift the null-space for closed/periodic meshes, following ex11p.
        stiffness_form.AddDomainIntegrator(new mfem::MassIntegrator(one));
    }
    stiffness_form.Assemble();
    stiffness_form.EliminateEssentialBCDiag(ess_bdr, 1.0);
    stiffness_form.Finalize();
    std::unique_ptr<mfem::HypreParMatrix> stiffness(stiffness_form.ParallelAssemble());

    mfem::ParBilinearForm mass_form(&fespace);
    mass_form.AddDomainIntegrator(new mfem::MassIntegrator(one));
    mass_form.Assemble();
    // Keep eliminated dofs finite and positive to avoid singular mass blocks.
    mass_form.EliminateEssentialBCDiag(ess_bdr, 1.0e-12);
    mass_form.Finalize();
    std::unique_ptr<mfem::HypreParMatrix> mass(mass_form.ParallelAssemble());

    mfem::HypreBoomerAMG amg(*stiffness);
    amg.SetPrintLevel(0);

    mfem::HypreLOBPCG lobpcg(MPI_COMM_WORLD);
    lobpcg.SetNumModes(parsed.num_eigenmodes);
    lobpcg.SetRandomSeed(75);
    lobpcg.SetPreconditioner(amg);
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
                "HypreLOBPCG returned non-finite eigenvalues. "
                "Check mesh quality, boundary conditions, and Hypre BLOPEX availability."
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
    paraview.RegisterField("mode_1", &first_mode);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# eigenmode fields written to " << collection_name << ".pvd\n";

    const fs::path eigenvalues_path = fs::path(context.working_directory) / "eigenvalues.json";
    json eigenvalues_json;
    eigenvalues_json["solver_class"] = "Eigenvalue";
    eigenvalues_json["material_coefficient"] = parsed.material_coefficient;
    eigenvalues_json["eigenvalues"] = json::array();
    for (int i = 0; i < eigenvalues.Size(); ++i)
    {
        eigenvalues_json["eigenvalues"].push_back(static_cast<double>(eigenvalues[i]));
    }
    std::ofstream eigenvalues_out(eigenvalues_path);
    if (!eigenvalues_out)
    {
        throw std::runtime_error("Unable to write eigenvalues.json.");
    }
    eigenvalues_out << eigenvalues_json.dump(2);

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
    summary.energy = eigenvalues[0];
    summary.iterations = eigenvalues.Size();
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    if (!std::isfinite(summary.error_norm))
    {
        throw std::runtime_error("Eigenvalue residual norm is non-finite.");
    }
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("Eigenvalue solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
