// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "Hyperelasticity.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <memory>
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

std::vector<double> parse_vector_value(
    const json &value,
    const std::string &field_name,
    int dimension,
    bool required)
{
    if (value.is_null())
    {
        if (required)
        {
            throw std::runtime_error(field_name + " is required.");
        }
        return std::vector<double>(dimension, 0.0);
    }
    if (!value.is_array())
    {
        throw std::runtime_error(field_name + " must be an array.");
    }
    std::vector<double> parsed;
    for (const auto &component : value)
    {
        if (!component.is_number())
        {
            throw std::runtime_error(field_name + " entries must be numeric.");
        }
        parsed.push_back(component.get<double>());
    }
    if (static_cast<int>(parsed.size()) < dimension)
    {
        throw std::runtime_error(field_name + " must provide at least mesh-dimension components.");
    }
    parsed.resize(dimension);
    return parsed;
}
} // namespace

namespace autosage
{
const char *HyperelasticSolver::Name() const
{
    return "Hyperelastic";
}

HyperelasticSolver::HyperelasticConfig HyperelasticSolver::ParseConfig(
    const json &config,
    int dimension,
    int max_boundary_attribute) const
{
    if (!config.contains("shear_modulus") || !config["shear_modulus"].is_number())
    {
        throw std::runtime_error("config.shear_modulus is required and must be numeric.");
    }
    if (!config.contains("bulk_modulus") || !config["bulk_modulus"].is_number())
    {
        throw std::runtime_error("config.bulk_modulus is required and must be numeric.");
    }

    HyperelasticConfig parsed;
    parsed.shear_modulus = config["shear_modulus"].get<double>();
    parsed.bulk_modulus = config["bulk_modulus"].get<double>();
    if (!(parsed.shear_modulus > 0.0))
    {
        throw std::runtime_error("config.shear_modulus must be > 0.");
    }
    if (!(parsed.bulk_modulus > 0.0))
    {
        throw std::runtime_error("config.bulk_modulus must be > 0.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.essential_boundary_marker.assign(boundary_slots, 0);
    parsed.body_force.assign(dimension, 0.0);

    if (config.contains("body_force"))
    {
        parsed.body_force = parse_vector_value(config["body_force"], "config.body_force", dimension, true);
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }
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
        if (type == "fixed")
        {
            parsed.essential_boundary_marker[attribute - 1] = 1;
            continue;
        }
        if (type == "traction")
        {
            TractionBoundary traction;
            traction.attribute = attribute;
            traction.value = parse_vector_value(
                bc.contains("value") ? bc["value"] : json(nullptr),
                "config.bcs[].value",
                dimension,
                true
            );
            parsed.tractions.push_back(std::move(traction));
            continue;
        }
        throw std::runtime_error("config.bcs[].type must be fixed or traction.");
    }

    if (boundary_slots > 0)
    {
        const bool has_fixed = std::any_of(
            parsed.essential_boundary_marker.begin(),
            parsed.essential_boundary_marker.end(),
            [](int marker) { return marker != 0; }
        );
        if (!has_fixed)
        {
            throw std::runtime_error("config.bcs must include at least one fixed boundary condition.");
        }
    }

    return parsed;
}

SolveSummary HyperelasticSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dimension = mesh.Dimension();
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const HyperelasticConfig parsed = ParseConfig(config, dimension, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(1, dimension);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec, dimension);
    mfem::ParGridFunction displacement(&fespace);
    displacement = 0.0;

    mfem::Array<int> ess_bdr(max_boundary_attribute);
    ess_bdr = 0;
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        ess_bdr[i] = parsed.essential_boundary_marker[i];
    }

    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    auto material = std::make_unique<mfem::NeoHookeanModel>(parsed.shear_modulus, parsed.bulk_modulus);
    mfem::ParNonlinearForm nonlinear_form(&fespace);
    nonlinear_form.AddDomainIntegrator(new mfem::HyperelasticNLFIntegrator(material.get()));

    mfem::ParLinearForm rhs_form(&fespace);
    std::vector<std::unique_ptr<mfem::VectorConstantCoefficient>> owned_vector_coeffs;
    const bool has_body_force = std::any_of(
        parsed.body_force.begin(),
        parsed.body_force.end(),
        [](double value) { return std::fabs(value) > 0.0; }
    );
    if (has_body_force)
    {
        mfem::Vector body_force_vector(dimension);
        for (int i = 0; i < dimension; ++i)
        {
            body_force_vector[i] = parsed.body_force[i];
        }
        owned_vector_coeffs.push_back(std::make_unique<mfem::VectorConstantCoefficient>(body_force_vector));
        rhs_form.AddDomainIntegrator(new mfem::VectorDomainLFIntegrator(*owned_vector_coeffs.back()));
    }

    std::vector<mfem::Array<int>> traction_markers;
    for (const TractionBoundary &traction : parsed.tractions)
    {
        mfem::Vector traction_vector(dimension);
        for (int i = 0; i < dimension; ++i)
        {
            traction_vector[i] = traction.value[i];
        }
        owned_vector_coeffs.push_back(std::make_unique<mfem::VectorConstantCoefficient>(traction_vector));
        traction_markers.emplace_back(max_boundary_attribute);
        traction_markers.back() = 0;
        traction_markers.back()[traction.attribute - 1] = 1;
        rhs_form.AddBoundaryIntegrator(new mfem::VectorBoundaryLFIntegrator(*owned_vector_coeffs.back()), traction_markers.back());
    }
    rhs_form.Assemble();

    mfem::Vector rhs_true(fespace.GetTrueVSize());
    rhs_form.ParallelAssemble(rhs_true);
    nonlinear_form.SetEssentialBC(ess_bdr, &rhs_true);

    mfem::Vector displacement_true(fespace.GetTrueVSize());
    displacement_true = 0.0;

    mfem::HypreSmoother jacobi;
    jacobi.SetType(mfem::HypreSmoother::Jacobi);

    mfem::CGSolver linear_solver(MPI_COMM_WORLD);
    linear_solver.iterative_mode = false;
    linear_solver.SetRelTol(1.0e-8);
    linear_solver.SetAbsTol(0.0);
    linear_solver.SetMaxIter(500);
    linear_solver.SetPrintLevel(0);
    linear_solver.SetPreconditioner(jacobi);

    mfem::NewtonSolver newton_solver(MPI_COMM_WORLD);
    newton_solver.iterative_mode = false;
    newton_solver.SetSolver(linear_solver);
    newton_solver.SetOperator(nonlinear_form);
    newton_solver.SetRelTol(1.0e-8);
    newton_solver.SetAbsTol(1.0e-10);
    newton_solver.SetMaxIter(50);
    newton_solver.SetPrintLevel(0);
    newton_solver.Mult(rhs_true, displacement_true);

    displacement.SetFromTrueDofs(displacement_true);

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
    paraview.RegisterField("displacement", &displacement);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# displacement field written to " << collection_name << ".pvd\n";

    mfem::Vector residual(rhs_true.Size());
    nonlinear_form.Mult(displacement_true, residual);
    residual -= rhs_true;

    SolveSummary summary;
    summary.energy = nonlinear_form.GetEnergy(displacement_true);
    summary.iterations = newton_solver.GetNumIterations();
    summary.error_norm = std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
    summary.dimension = dimension;
    return summary;
#else
    (void)mesh;
    (void)parsed;
    (void)context;
    throw std::runtime_error("Hyperelastic solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
