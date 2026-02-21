// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "Electrostatics.hpp"

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

bool has_nonzero_entries(const std::vector<double> &values)
{
    for (double value : values)
    {
        if (std::abs(value) > 0.0)
        {
            return true;
        }
    }
    return false;
}
} // namespace

namespace autosage
{
const char *ElectrostaticsSolver::Name() const
{
    return "Electrostatics";
}

ElectrostaticsSolver::ElectrostaticsConfig ElectrostaticsSolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    if (!config.contains("permittivity") || !config["permittivity"].is_number())
    {
        throw std::runtime_error("config.permittivity is required and must be numeric.");
    }
    const double permittivity = config["permittivity"].get<double>();
    if (!(permittivity > 0.0))
    {
        throw std::runtime_error("config.permittivity must be > 0.");
    }

    ElectrostaticsConfig parsed;
    parsed.permittivity = permittivity;

    if (config.contains("charge_density"))
    {
        if (!config["charge_density"].is_number())
        {
            throw std::runtime_error("config.charge_density must be numeric when provided.");
        }
        parsed.charge_density = config["charge_density"].get<double>();
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.fixed_voltage_marker.assign(boundary_slots, 0);
    parsed.fixed_voltage_values.assign(boundary_slots, 0.0);
    parsed.surface_charge_values.assign(boundary_slots, 0.0);

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
        if (!bc.contains("value") || !bc["value"].is_number())
        {
            throw std::runtime_error("config.bcs[].value is required and must be numeric.");
        }
        const double value = bc["value"].get<double>();
        const std::string type = to_lower(bc.value("type", ""));
        if (type == "fixed_voltage")
        {
            parsed.fixed_voltage_marker[attribute - 1] = 1;
            parsed.fixed_voltage_values[attribute - 1] = value;
            continue;
        }
        if (type == "surface_charge")
        {
            parsed.surface_charge_values[attribute - 1] += value;
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be fixed_voltage or surface_charge.");
    }

    const bool has_dirichlet = std::any_of(
        parsed.fixed_voltage_marker.begin(),
        parsed.fixed_voltage_marker.end(),
        [](int marker) { return marker != 0; }
    );
    if (!has_dirichlet)
    {
        throw std::runtime_error("At least one fixed_voltage boundary condition is required.");
    }

    return parsed;
}

SolveSummary ElectrostaticsSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const ElectrostaticsConfig parsed = ParseConfig(config, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);
    mfem::ParGridFunction potential(&fespace);
    potential = 0.0;

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.fixed_voltage_marker[i];
    }

    mfem::Vector fixed_voltage_values(max_boundary_attribute);
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        fixed_voltage_values[i] = parsed.fixed_voltage_values[i];
    }
    mfem::PWConstCoefficient fixed_voltage_coeff(fixed_voltage_values);
    if (max_boundary_attribute > 0)
    {
        potential.ProjectBdrCoefficient(fixed_voltage_coeff, ess_bdr);
    }

    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    mfem::ParBilinearForm stiffness(&fespace);
    mfem::ConstantCoefficient permittivity_coeff(parsed.permittivity);
    stiffness.AddDomainIntegrator(new mfem::DiffusionIntegrator(permittivity_coeff));

    mfem::ParLinearForm rhs(&fespace);
    std::unique_ptr<mfem::ConstantCoefficient> charge_density_coeff;
    if (std::abs(parsed.charge_density) > 0.0)
    {
        charge_density_coeff = std::make_unique<mfem::ConstantCoefficient>(parsed.charge_density);
        rhs.AddDomainIntegrator(new mfem::DomainLFIntegrator(*charge_density_coeff));
    }
    std::unique_ptr<mfem::PWConstCoefficient> surface_charge_coeff;
    if (max_boundary_attribute > 0 && has_nonzero_entries(parsed.surface_charge_values))
    {
        mfem::Vector surface_charge_values(max_boundary_attribute);
        for (int i = 0; i < max_boundary_attribute; ++i)
        {
            surface_charge_values[i] = parsed.surface_charge_values[i];
        }
        surface_charge_coeff = std::make_unique<mfem::PWConstCoefficient>(surface_charge_values);
        rhs.AddBoundaryIntegrator(new mfem::BoundaryLFIntegrator(*surface_charge_coeff));
    }

    stiffness.Assemble();
    rhs.Assemble();

    mfem::OperatorPtr A;
    mfem::Vector X;
    mfem::Vector B;
    stiffness.FormLinearSystem(ess_tdof_list, potential, rhs, A, X, B);

    auto &A_hypre = dynamic_cast<mfem::HypreParMatrix &>(*A.Ptr());
    mfem::HypreParVector B_hypre(
        A_hypre.GetComm(),
        A_hypre.GetGlobalNumRows(),
        B,
        0,
        A_hypre.GetRowStarts()
    );
    mfem::HypreParVector X_hypre(
        A_hypre.GetComm(),
        A_hypre.GetGlobalNumRows(),
        X,
        0,
        A_hypre.GetRowStarts()
    );
    X_hypre = 0.0;

    mfem::HypreBoomerAMG amg(A_hypre);
    amg.SetPrintLevel(0);

    mfem::HyprePCG pcg(A_hypre);
    pcg.SetTol(1.0e-12);
    pcg.SetAbsTol(0.0);
    pcg.SetMaxIter(2000);
    pcg.SetPrintLevel(0);
    pcg.SetPreconditioner(amg);
    pcg.Mult(B_hypre, X_hypre);

    mfem::Vector residual(B.Size());
    mfem::HypreParVector residual_hypre(
        A_hypre.GetComm(),
        A_hypre.GetGlobalNumRows(),
        residual,
        0,
        A_hypre.GetRowStarts()
    );
    A_hypre.Mult(X_hypre, residual_hypre);
    residual_hypre -= B_hypre;
    for (int i = 0; i < ess_tdof_list.Size(); ++i)
    {
        const int tdof = ess_tdof_list[i];
        if (tdof >= 0 && tdof < residual.Size())
        {
            residual[tdof] = 0.0;
        }
    }

    stiffness.RecoverFEMSolution(X, rhs, potential);

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
    paraview.RegisterField("potential", &potential);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# potential field written to " << collection_name << ".pvd\n";

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(fespace.GetComm(), X, B);
    int num_iterations = 0;
    pcg.GetNumIterations(num_iterations);
    summary.iterations = num_iterations;
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    summary.dimension = dim;
    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("Electrostatics solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
