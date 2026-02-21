// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "LinearElasticity.hpp"

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

std::pair<double, double> lame_from_material(double youngs_modulus, double poisson_ratio)
{
    if (youngs_modulus <= 0.0)
    {
        throw std::runtime_error("materials[].E must be > 0.");
    }
    if (poisson_ratio <= -1.0 || poisson_ratio >= 0.5)
    {
        throw std::runtime_error("materials[].nu must be in (-1, 0.5).");
    }
    const double lambda = (youngs_modulus * poisson_ratio) /
                          ((1.0 + poisson_ratio) * (1.0 - 2.0 * poisson_ratio));
    const double mu = youngs_modulus / (2.0 * (1.0 + poisson_ratio));
    return {lambda, mu};
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
const char *LinearElasticitySolver::Name() const
{
    return "LinearElasticity";
}

LinearElasticitySolver::ParsedConfig LinearElasticitySolver::ParseConfig(
    const json &config,
    int dimension,
    int max_domain_attribute,
    int max_boundary_attribute) const
{
    if (!config.contains("materials") || !config["materials"].is_array() || config["materials"].empty())
    {
        throw std::runtime_error("config.materials must be a non-empty array.");
    }

    const int domain_slots = std::max(1, max_domain_attribute);
    const int boundary_slots = std::max(0, max_boundary_attribute);

    ParsedConfig parsed;
    parsed.lambda_by_attribute.resize(domain_slots, 0.0);
    parsed.mu_by_attribute.resize(domain_slots, 0.0);
    parsed.essential_boundary_marker.resize(boundary_slots, 0);
    parsed.body_force.assign(dimension, 0.0);

    // Use the first material as default, then override by attribute.
    const json &first_material = config["materials"][0];
    const auto [default_lambda, default_mu] = lame_from_material(
        first_material.value("E", 0.0),
        first_material.value("nu", 0.0)
    );
    std::fill(parsed.lambda_by_attribute.begin(), parsed.lambda_by_attribute.end(), default_lambda);
    std::fill(parsed.mu_by_attribute.begin(), parsed.mu_by_attribute.end(), default_mu);

    for (const auto &material : config["materials"])
    {
        if (!material.is_object())
        {
            throw std::runtime_error("config.materials entries must be objects.");
        }
        if (!material.contains("attribute") || !material["attribute"].is_number_integer())
        {
            throw std::runtime_error("config.materials[].attribute is required and must be an integer.");
        }
        const int attribute = material["attribute"].get<int>();
        if (attribute <= 0)
        {
            throw std::runtime_error("config.materials[].attribute must be > 0.");
        }
        if (max_domain_attribute > 0 && attribute > max_domain_attribute)
        {
            throw std::runtime_error("config.materials[].attribute exceeds mesh domain attribute count.");
        }
        const auto [lambda, mu] = lame_from_material(
            material.value("E", 0.0),
            material.value("nu", 0.0)
        );
        parsed.lambda_by_attribute[attribute - 1] = lambda;
        parsed.mu_by_attribute[attribute - 1] = mu;
    }

    if (config.contains("gravity"))
    {
        const double density = config.value("density", 1.0);
        const std::vector<double> gravity = parse_vector_value(config["gravity"], "config.gravity", dimension, true);
        for (int i = 0; i < dimension; ++i)
        {
            parsed.body_force[i] = density * gravity[i];
        }
    }
    if (config.contains("acceleration"))
    {
        const double density = config.value("density", 1.0);
        const std::vector<double> acceleration = parse_vector_value(config["acceleration"], "config.acceleration", dimension, true);
        for (int i = 0; i < dimension; ++i)
        {
            parsed.body_force[i] = density * acceleration[i];
        }
    }
    if (config.contains("body_force"))
    {
        parsed.body_force = parse_vector_value(config["body_force"], "config.body_force", dimension, true);
    }

    if (!config.contains("bcs"))
    {
        return parsed;
    }
    if (!config["bcs"].is_array())
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
        if (type == "load")
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
        throw std::runtime_error("config.bcs[].type must be fixed or load.");
    }

    return parsed;
}

SolveSummary LinearElasticitySolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dimension = mesh.Dimension();
    const int max_domain_attribute = mesh.attributes.Size() > 0 ? mesh.attributes.Max() : 0;
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const ParsedConfig parsed = ParseConfig(config, dimension, max_domain_attribute, max_boundary_attribute);

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    mfem::H1_FECollection fec(1, dimension);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec, dimension);
    mfem::ParGridFunction displacement(&fespace);
    displacement = 0.0;

    mfem::Vector lambda_values(static_cast<int>(parsed.lambda_by_attribute.size()));
    mfem::Vector mu_values(static_cast<int>(parsed.mu_by_attribute.size()));
    for (int i = 0; i < lambda_values.Size(); ++i)
    {
        lambda_values[i] = parsed.lambda_by_attribute[i];
        mu_values[i] = parsed.mu_by_attribute[i];
    }
    mfem::PWConstCoefficient lambda_coeff(lambda_values);
    mfem::PWConstCoefficient mu_coeff(mu_values);

    mfem::ParBilinearForm stiffness(&fespace);
    stiffness.AddDomainIntegrator(new mfem::ElasticityIntegrator(lambda_coeff, mu_coeff));
    stiffness.Assemble();

    mfem::ParLinearForm rhs(&fespace);
    std::vector<std::unique_ptr<mfem::VectorConstantCoefficient>> owned_vector_coeffs;
    const bool has_body_force = std::any_of(
        parsed.body_force.begin(),
        parsed.body_force.end(),
        [](double value) { return std::fabs(value) > 0.0; }
    );
    if (has_body_force)
    {
        mfem::Vector body_force_vector(dimension);
        for (int i = 0; i < dimension; ++i) { body_force_vector[i] = parsed.body_force[i]; }
        owned_vector_coeffs.push_back(std::make_unique<mfem::VectorConstantCoefficient>(body_force_vector));
        rhs.AddDomainIntegrator(new mfem::VectorDomainLFIntegrator(*owned_vector_coeffs.back()));
    }

    std::vector<mfem::Array<int>> traction_markers;
    for (const TractionBoundary &traction : parsed.tractions)
    {
        mfem::Vector traction_vector(dimension);
        for (int i = 0; i < dimension; ++i) { traction_vector[i] = traction.value[i]; }
        owned_vector_coeffs.push_back(std::make_unique<mfem::VectorConstantCoefficient>(traction_vector));
        traction_markers.emplace_back(max_boundary_attribute);
        traction_markers.back() = 0;
        traction_markers.back()[traction.attribute - 1] = 1;
        rhs.AddBoundaryIntegrator(new mfem::VectorBoundaryLFIntegrator(*owned_vector_coeffs.back()), traction_markers.back());
    }
    rhs.Assemble();

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

    mfem::OperatorPtr A;
    mfem::Vector B;
    mfem::Vector X;
    stiffness.FormLinearSystem(ess_tdof_list, displacement, rhs, A, X, B);

    auto &A_hypre = dynamic_cast<mfem::HypreParMatrix &>(*A.Ptr());
    mfem::HypreBoomerAMG amg(A_hypre);
    amg.SetElasticityOptions(&fespace);
    amg.SetPrintLevel(0);

    mfem::CGSolver solver(MPI_COMM_WORLD);
    solver.SetRelTol(1.0e-12);
    solver.SetAbsTol(0.0);
    solver.SetMaxIter(500);
    solver.SetPrintLevel(0);
    solver.SetOperator(A_hypre);
    solver.SetPreconditioner(amg);
    solver.Mult(B, X);

    mfem::Vector residual(B.Size());
    A_hypre.Mult(X, residual);
    residual -= B;

    stiffness.RecoverFEMSolution(X, rhs, displacement);
    const fs::path vtk_path(context.vtk_path);
    const std::string collection_name = vtk_path.stem().empty() ? "solution" : vtk_path.stem().string();
    const std::string output_dir = vtk_path.has_parent_path() ? vtk_path.parent_path().string() : context.working_directory;
    mfem::ParaViewDataCollection paraview(collection_name, &pmesh);
    paraview.SetPrefixPath(output_dir);
    paraview.SetLevelsOfDetail(1);
    paraview.SetDataFormat(mfem::VTKFormat::ASCII);
    paraview.RegisterField("displacement", &displacement);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();
    // Keep deterministic artifact expected by current Swift tooling.
    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# displacement field written to " << collection_name << ".pvd\n";

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(X, B);
    summary.iterations = solver.GetNumIterations();
    summary.error_norm = residual.Norml2();
    summary.dimension = dimension;
    return summary;
#else
    mfem::H1_FECollection fec(1, dimension);
    mfem::FiniteElementSpace fespace(&mesh, &fec, dimension);
    mfem::GridFunction displacement(&fespace);
    displacement = 0.0;

    mfem::Vector lambda_values(static_cast<int>(parsed.lambda_by_attribute.size()));
    mfem::Vector mu_values(static_cast<int>(parsed.mu_by_attribute.size()));
    for (int i = 0; i < lambda_values.Size(); ++i)
    {
        lambda_values[i] = parsed.lambda_by_attribute[i];
        mu_values[i] = parsed.mu_by_attribute[i];
    }
    mfem::PWConstCoefficient lambda_coeff(lambda_values);
    mfem::PWConstCoefficient mu_coeff(mu_values);

    mfem::BilinearForm stiffness(&fespace);
    stiffness.AddDomainIntegrator(new mfem::ElasticityIntegrator(lambda_coeff, mu_coeff));

    mfem::LinearForm rhs(&fespace);
    const bool has_body_force = std::any_of(
        parsed.body_force.begin(),
        parsed.body_force.end(),
        [](double value) { return std::fabs(value) > 0.0; }
    );
    std::vector<std::unique_ptr<mfem::VectorConstantCoefficient>> owned_coeffs;
    if (has_body_force)
    {
        mfem::Vector body_force_vector(dimension);
        for (int i = 0; i < dimension; ++i) { body_force_vector[i] = parsed.body_force[i]; }
        owned_coeffs.push_back(std::make_unique<mfem::VectorConstantCoefficient>(body_force_vector));
        rhs.AddDomainIntegrator(new mfem::VectorDomainLFIntegrator(*owned_coeffs.back()));
    }

    std::vector<mfem::Array<int>> traction_markers;
    for (const TractionBoundary &traction : parsed.tractions)
    {
        mfem::Vector traction_vector(dimension);
        for (int i = 0; i < dimension; ++i) { traction_vector[i] = traction.value[i]; }
        owned_coeffs.push_back(std::make_unique<mfem::VectorConstantCoefficient>(traction_vector));
        traction_markers.emplace_back(max_boundary_attribute);
        traction_markers.back() = 0;
        traction_markers.back()[traction.attribute - 1] = 1;
        rhs.AddBoundaryIntegrator(new mfem::VectorBoundaryLFIntegrator(*owned_coeffs.back()), traction_markers.back());
    }

    stiffness.Assemble();
    rhs.Assemble();

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

    mfem::OperatorPtr A;
    mfem::Vector B;
    mfem::Vector X;
    stiffness.FormLinearSystem(ess_tdof_list, displacement, rhs, A, X, B);

    auto &A_sparse = dynamic_cast<mfem::SparseMatrix &>(*A.Ptr());
    mfem::GSSmoother preconditioner(A_sparse);
    mfem::CGSolver solver;
    solver.SetRelTol(1.0e-12);
    solver.SetAbsTol(0.0);
    solver.SetMaxIter(500);
    solver.SetPrintLevel(0);
    solver.SetOperator(A_sparse);
    solver.SetPreconditioner(preconditioner);
    solver.Mult(B, X);

    mfem::Vector residual(B.Size());
    A_sparse.Mult(X, residual);
    residual -= B;

    stiffness.RecoverFEMSolution(X, rhs, displacement);
    std::ofstream out(context.vtk_path);
    if (!out)
    {
        throw std::runtime_error("Unable to write VTK output: " + context.vtk_path);
    }
    mesh.PrintVTK(out, 1);
    displacement.SaveVTK(out, "displacement", 1);

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(X, B);
    summary.iterations = solver.GetNumIterations();
    summary.error_norm = residual.Norml2();
    summary.dimension = dimension;
    return summary;
#endif
}
} // namespace autosage
