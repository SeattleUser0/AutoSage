// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "ElectromagneticScattering.hpp"

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

std::vector<double> parse_vector_components(
    const json &entry,
    const char *key,
    int dim,
    bool required)
{
    if (!entry.contains(key))
    {
        if (required)
        {
            throw std::runtime_error(std::string(key) + " is required.");
        }
        return std::vector<double>(dim, 0.0);
    }

    if (!entry[key].is_array())
    {
        throw std::runtime_error(std::string(key) + " must be an array.");
    }

    std::vector<double> values;
    values.reserve(entry[key].size());
    for (const auto &component : entry[key])
    {
        if (!component.is_number())
        {
            throw std::runtime_error(std::string(key) + " components must be numeric.");
        }
        values.push_back(component.get<double>());
    }

    if (static_cast<int>(values.size()) < dim)
    {
        throw std::runtime_error(std::string(key) + " must provide at least mesh-dimension components.");
    }
    values.resize(dim);
    return values;
}

class PMLRegion
{
public:
    PMLRegion(int max_element_attribute, const std::vector<int> &pml_attributes)
        : computational_marker_(max_element_attribute),
          pml_marker_(max_element_attribute)
    {
        computational_marker_ = 1;
        pml_marker_ = 0;
        for (const int attribute : pml_attributes)
        {
            if (attribute >= 1 && attribute <= max_element_attribute)
            {
                pml_marker_[attribute - 1] = 1;
                computational_marker_[attribute - 1] = 0;
            }
        }
    }

    mfem::Array<int> &ComputationalMarker() { return computational_marker_; }
    mfem::Array<int> &PMLMarker() { return pml_marker_; }

    bool HasPML() const
    {
        for (int i = 0; i < pml_marker_.Size(); ++i)
        {
            if (pml_marker_[i] != 0) { return true; }
        }
        return false;
    }

private:
    mfem::Array<int> computational_marker_;
    mfem::Array<int> pml_marker_;
};
} // namespace

namespace autosage
{
const char *ElectromagneticScatteringSolver::Name() const
{
    return "ElectromagneticScattering";
}

ElectromagneticScatteringSolver::ScatteringConfig ElectromagneticScatteringSolver::ParseConfig(
    const json &config,
    int dimension,
    int max_element_attribute,
    int max_boundary_attribute) const
{
    if (!config.contains("frequency") || !config["frequency"].is_number())
    {
        throw std::runtime_error("config.frequency is required and must be numeric.");
    }
    if (!config.contains("permittivity") || !config["permittivity"].is_number())
    {
        throw std::runtime_error("config.permittivity is required and must be numeric.");
    }
    if (!config.contains("permeability") || !config["permeability"].is_number())
    {
        throw std::runtime_error("config.permeability is required and must be numeric.");
    }
    if (!config.contains("pml_attributes") || !config["pml_attributes"].is_array())
    {
        throw std::runtime_error("config.pml_attributes is required and must be an array.");
    }
    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    ScatteringConfig parsed;
    parsed.frequency = config["frequency"].get<double>();
    parsed.angular_frequency = 2.0 * M_PI * parsed.frequency;
    parsed.permittivity = config["permittivity"].get<double>();
    parsed.permeability = config["permeability"].get<double>();
    if (!(parsed.frequency > 0.0))
    {
        throw std::runtime_error("config.frequency must be > 0.");
    }
    if (!(parsed.permittivity > 0.0))
    {
        throw std::runtime_error("config.permittivity must be > 0.");
    }
    if (!(parsed.permeability > 0.0))
    {
        throw std::runtime_error("config.permeability must be > 0.");
    }

    if (max_element_attribute == 0 && !config["pml_attributes"].empty())
    {
        throw std::runtime_error("Mesh has no element attributes but config.pml_attributes was provided.");
    }
    for (const auto &attribute_json : config["pml_attributes"])
    {
        if (!attribute_json.is_number_integer())
        {
            throw std::runtime_error("config.pml_attributes entries must be integers.");
        }
        const int attribute = attribute_json.get<int>();
        if (attribute <= 0)
        {
            throw std::runtime_error("config.pml_attributes entries must be > 0.");
        }
        if (max_element_attribute > 0 && attribute > max_element_attribute)
        {
            throw std::runtime_error("config.pml_attributes entry exceeds mesh element attribute count.");
        }
        parsed.pml_attributes.push_back(attribute);
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

    if (config.contains("source_current"))
    {
        if (!config["source_current"].is_object())
        {
            throw std::runtime_error("config.source_current must be an object.");
        }
        const json &source = config["source_current"];
        if (!source.contains("attributes") || !source["attributes"].is_array())
        {
            throw std::runtime_error("config.source_current.attributes is required and must be an array.");
        }

        SourceCurrent parsed_source;
        if (source["attributes"].empty())
        {
            throw std::runtime_error("config.source_current.attributes must not be empty.");
        }
        if (max_element_attribute == 0)
        {
            throw std::runtime_error("Mesh has no element attributes but source_current.attributes was provided.");
        }

        for (const auto &attribute_json : source["attributes"])
        {
            if (!attribute_json.is_number_integer())
            {
                throw std::runtime_error("config.source_current.attributes entries must be integers.");
            }
            const int attribute = attribute_json.get<int>();
            if (attribute <= 0)
            {
                throw std::runtime_error("config.source_current.attributes entries must be > 0.");
            }
            if (attribute > max_element_attribute)
            {
                throw std::runtime_error("config.source_current.attributes entry exceeds mesh element attribute count.");
            }
            parsed_source.attributes.push_back(attribute);
        }

        parsed_source.j_real = parse_vector_components(source, "J_real", dimension, true);
        parsed_source.j_imag = parse_vector_components(source, "J_imag", dimension, false);
        parsed.source_current = parsed_source;
    }

    return parsed;
}

SolveSummary ElectromagneticScatteringSolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
    const int dim = mesh.Dimension();
    const int max_element_attribute = mesh.attributes.Size() > 0 ? mesh.attributes.Max() : 0;
    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;

#if defined(MFEM_USE_MPI)
    mfem::ParMesh pmesh(MPI_COMM_WORLD, mesh);
    const ScatteringConfig parsed = ParseConfig(config, dim, max_element_attribute, max_boundary_attribute);
    PMLRegion pml(max_element_attribute, parsed.pml_attributes);

    mfem::ND_FECollection fec(1, dim);
    mfem::ParFiniteElementSpace fespace(&pmesh, &fec);

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

    const mfem::ComplexOperator::Convention convention = mfem::ComplexOperator::HERMITIAN;

    mfem::ParComplexLinearForm rhs(&fespace, convention);
    rhs = std::complex<mfem::real_t>(0.0, 0.0);
    std::unique_ptr<mfem::VectorConstantCoefficient> rhs_real_coeff;
    std::unique_ptr<mfem::VectorConstantCoefficient> rhs_imag_coeff;
    std::unique_ptr<mfem::Array<int>> source_marker;
    if (parsed.source_current.has_value())
    {
        const SourceCurrent &source = parsed.source_current.value();
        source_marker = std::make_unique<mfem::Array<int>>(max_element_attribute);
        *source_marker = 0;
        for (const int attribute : source.attributes)
        {
            (*source_marker)[attribute - 1] = 1;
        }

        mfem::Vector rhs_real(dim);
        mfem::Vector rhs_imag(dim);
        for (int d = 0; d < dim; ++d)
        {
            // -i * omega * (J_real + i J_imag)
            rhs_real[d] = parsed.angular_frequency * source.j_imag[d];
            rhs_imag[d] = -parsed.angular_frequency * source.j_real[d];
        }
        rhs_real_coeff = std::make_unique<mfem::VectorConstantCoefficient>(rhs_real);
        rhs_imag_coeff = std::make_unique<mfem::VectorConstantCoefficient>(rhs_imag);
        rhs.AddDomainIntegrator(
            new mfem::VectorFEDomainLFIntegrator(*rhs_real_coeff),
            new mfem::VectorFEDomainLFIntegrator(*rhs_imag_coeff),
            *source_marker
        );
    }
    rhs.Assemble();

    mfem::ParComplexGridFunction electric_field(&fespace);
    electric_field = std::complex<mfem::real_t>(0.0, 0.0);
    if (max_boundary_attribute > 0)
    {
        mfem::Vector zero_vector(dim);
        zero_vector = 0.0;
        mfem::VectorConstantCoefficient zero_coeff(zero_vector);
        electric_field.ProjectBdrCoefficientTangent(zero_coeff, zero_coeff, ess_bdr);
    }

    mfem::ConstantCoefficient mu_inverse_coeff(1.0 / parsed.permeability);
    mfem::ConstantCoefficient neg_mass_coeff(
        -parsed.angular_frequency * parsed.angular_frequency * parsed.permittivity
    );
    mfem::ConstantCoefficient pos_mass_coeff(
        parsed.angular_frequency * parsed.angular_frequency * parsed.permittivity
    );
    mfem::ConstantCoefficient pml_loss_coeff(parsed.angular_frequency * parsed.permittivity);
    std::unique_ptr<mfem::Vector> pml_loss_values;
    std::unique_ptr<mfem::PWConstCoefficient> pml_loss_pw_coeff;
    if (max_element_attribute > 0 && pml.HasPML())
    {
        pml_loss_values = std::make_unique<mfem::Vector>(max_element_attribute);
        *pml_loss_values = 0.0;
        for (const int attribute : parsed.pml_attributes)
        {
            if (attribute >= 1 && attribute <= max_element_attribute)
            {
                (*pml_loss_values)[attribute - 1] = pml_loss_coeff.constant;
            }
        }
        pml_loss_pw_coeff = std::make_unique<mfem::PWConstCoefficient>(*pml_loss_values);
    }

    mfem::ParSesquilinearForm system_form(&fespace, convention);
    system_form.AddDomainIntegrator(new mfem::CurlCurlIntegrator(mu_inverse_coeff), nullptr);
    system_form.AddDomainIntegrator(new mfem::VectorFEMassIntegrator(neg_mass_coeff), nullptr);
    if (pml_loss_pw_coeff)
    {
        system_form.AddDomainIntegrator(nullptr, new mfem::VectorFEMassIntegrator(*pml_loss_pw_coeff));
    }
    system_form.Assemble();

    mfem::OperatorHandle system_operator;
    mfem::Vector true_solution;
    mfem::Vector true_rhs;
    system_form.FormLinearSystem(ess_tdof_list, electric_field, rhs, system_operator, true_solution, true_rhs);

    mfem::ParBilinearForm preconditioner_form(&fespace);
    preconditioner_form.AddDomainIntegrator(new mfem::CurlCurlIntegrator(mu_inverse_coeff));
    preconditioner_form.AddDomainIntegrator(new mfem::VectorFEMassIntegrator(pos_mass_coeff));
    if (pml_loss_pw_coeff)
    {
        preconditioner_form.AddDomainIntegrator(new mfem::VectorFEMassIntegrator(*pml_loss_pw_coeff));
    }
    preconditioner_form.Assemble();

    mfem::OperatorHandle preconditioner_operator;
    preconditioner_form.FormSystemMatrix(ess_tdof_list, preconditioner_operator);
    auto *preconditioner_matrix = preconditioner_operator.As<mfem::HypreParMatrix>();
    if (preconditioner_matrix == nullptr)
    {
        throw std::runtime_error("Failed to assemble ElectromagneticScattering preconditioner matrix.");
    }

    mfem::Array<int> block_offsets(3);
    block_offsets[0] = 0;
    block_offsets[1] = fespace.GetTrueVSize();
    block_offsets[2] = fespace.GetTrueVSize();
    block_offsets.PartialSum();

    auto *pc_real = new mfem::HypreAMS(*preconditioner_matrix, &fespace);
    pc_real->SetPrintLevel(0);
    auto *pc_imag = new mfem::ScaledOperator(pc_real, -1.0);

    mfem::BlockDiagonalPreconditioner block_preconditioner(block_offsets);
    block_preconditioner.SetDiagonalBlock(0, pc_real);
    block_preconditioner.SetDiagonalBlock(1, pc_imag);
    block_preconditioner.owns_blocks = 1;

    mfem::FGMRESSolver solver(MPI_COMM_WORLD);
    solver.SetKDim(200);
    solver.SetMaxIter(1000);
    solver.SetRelTol(1.0e-8);
    solver.SetAbsTol(0.0);
    solver.SetPrintLevel(0);
    solver.SetOperator(*system_operator.Ptr());
    solver.SetPreconditioner(block_preconditioner);
    solver.Mult(true_rhs, true_solution);

    system_form.RecoverFEMSolution(true_solution, rhs, electric_field);

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
    paraview.RegisterField("electric_field_real", &electric_field.real());
    paraview.RegisterField("electric_field_imag", &electric_field.imag());
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    vtk_stub << "# electromagnetic scattering fields written to " << collection_name << ".pvd\n";

    mfem::Vector residual(true_rhs.Size());
    system_operator.Ptr()->Mult(true_solution, residual);
    residual -= true_rhs;

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(true_solution, true_rhs);
    summary.iterations = solver.GetNumIterations();
    summary.error_norm = residual.Norml2();
    summary.dimension = dim;
    if (!std::isfinite(summary.error_norm))
    {
        throw std::runtime_error("ElectromagneticScattering residual norm is non-finite.");
    }

    const fs::path scattering_path = fs::path(context.working_directory) / "electromagnetic_scattering.json";
    json scattering_data;
    scattering_data["solver_class"] = "ElectromagneticScattering";
    scattering_data["solver_backend"] = "fgmres_block_ams";
    scattering_data["frequency"] = parsed.frequency;
    scattering_data["angular_frequency"] = parsed.angular_frequency;
    scattering_data["permittivity"] = parsed.permittivity;
    scattering_data["permeability"] = parsed.permeability;
    scattering_data["pml_attributes"] = parsed.pml_attributes;
    scattering_data["iterations"] = summary.iterations;
    scattering_data["residual_norm"] = summary.error_norm;
    if (parsed.source_current.has_value())
    {
        scattering_data["source_attributes"] = parsed.source_current.value().attributes;
    }
    std::ofstream scattering_out(scattering_path);
    if (!scattering_out)
    {
        throw std::runtime_error("Unable to write electromagnetic_scattering.json.");
    }
    scattering_out << scattering_data.dump(2);

    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("ElectromagneticScattering solver requires MFEM built with MPI.");
#endif
}
} // namespace autosage
