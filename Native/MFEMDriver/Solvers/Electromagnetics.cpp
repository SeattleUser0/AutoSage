// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "Electromagnetics.hpp"

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
const char *ElectromagneticsSolver::Name() const
{
    return "Electromagnetics";
}

ElectromagneticsSolver::ElectromagneticsConfig ElectromagneticsSolver::ParseConfig(
    const json &config,
    int space_dimension,
    int max_boundary_attribute) const
{
    if (!config.contains("permeability") || !config["permeability"].is_number())
    {
        throw std::runtime_error("config.permeability is required and must be numeric.");
    }
    if (!config.contains("kappa") || !config["kappa"].is_number())
    {
        throw std::runtime_error("config.kappa is required and must be numeric.");
    }

    ElectromagneticsConfig parsed;
    parsed.permeability = config["permeability"].get<double>();
    parsed.kappa = config["kappa"].get<double>();
    if (!(parsed.permeability > 0.0))
    {
        throw std::runtime_error("config.permeability must be > 0.");
    }
    if (!(parsed.kappa > 0.0))
    {
        throw std::runtime_error("config.kappa must be > 0.");
    }

    parsed.current_density.assign(std::max(1, space_dimension), 0.0);
    if (config.contains("current_density"))
    {
        if (!config["current_density"].is_array())
        {
            throw std::runtime_error("config.current_density must be an array when provided.");
        }
        const auto &density = config["current_density"];
        if (static_cast<int>(density.size()) < space_dimension)
        {
            throw std::runtime_error("config.current_density must provide at least mesh-space-dimension components.");
        }
        for (int i = 0; i < space_dimension; ++i)
        {
            if (!density[static_cast<size_t>(i)].is_number())
            {
                throw std::runtime_error("config.current_density entries must be numeric.");
            }
            parsed.current_density[static_cast<size_t>(i)] = density[static_cast<size_t>(i)].get<double>();
        }
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
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

SolveSummary ElectromagneticsSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    const int space_dimension = pmesh.SpaceDimension();
    const ElectromagneticsConfig parsed = ParseConfig(config, space_dimension, max_boundary_attribute);

    mfem::ND_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);
    mfem::ParGridFunction electric_field(&fespace);
    electric_field = 0.0;

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.perfect_conductor_marker[i];
    }
    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    mfem::ParBilinearForm lhs(&fespace);
    mfem::ConstantCoefficient mu_inverse_coeff(1.0 / parsed.permeability);
    mfem::ConstantCoefficient kappa_coeff(parsed.kappa);
    lhs.AddDomainIntegrator(new mfem::CurlCurlIntegrator(mu_inverse_coeff));
    lhs.AddDomainIntegrator(new mfem::VectorFEMassIntegrator(kappa_coeff));

    mfem::ParLinearForm rhs(&fespace);
    std::unique_ptr<mfem::VectorConstantCoefficient> current_density_coeff;
    if (has_nonzero_entries(parsed.current_density))
    {
        mfem::Vector current_density_vector(space_dimension);
        for (int i = 0; i < space_dimension; ++i)
        {
            current_density_vector[i] = parsed.current_density[static_cast<size_t>(i)];
        }
        current_density_coeff = std::make_unique<mfem::VectorConstantCoefficient>(current_density_vector);
        rhs.AddDomainIntegrator(new mfem::VectorFEDomainLFIntegrator(*current_density_coeff));
    }

    lhs.Assemble();
    rhs.Assemble();

    mfem::OperatorPtr A;
    mfem::Vector X;
    mfem::Vector B;
    lhs.FormLinearSystem(ess_tdof_list, electric_field, rhs, A, X, B);

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

    mfem::HypreAMS ams(A_hypre, &fespace);
    ams.SetPrintLevel(0);

    mfem::HyprePCG pcg(A_hypre);
    pcg.SetTol(1.0e-12);
    pcg.SetAbsTol(0.0);
    pcg.SetMaxIter(1'000);
    pcg.SetPrintLevel(0);
    pcg.SetPreconditioner(ams);
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

    lhs.RecoverFEMSolution(X, rhs, electric_field);

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
    paraview.RegisterField("electric_field", &electric_field);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# electric field written to " << collection_name << ".pvd\n";

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
    (void)config;
    (void)context;
    throw std::runtime_error("Electromagnetics solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
