#include "Solvers/AMRLaplace.hpp"
#include "Solvers/AnisotropicDiffusion.hpp"
#include "Solvers/AcousticWave.hpp"
#include "Solvers/Advection.hpp"
#include "Solvers/CompressibleEuler.hpp"
#include "Solvers/DPGLaplace.hpp"
#include "Solvers/Elastodynamics.hpp"
#include "Solvers/Electromagnetics.hpp"
#include "Solvers/ElectromagneticModal.hpp"
#include "Solvers/ElectromagneticScattering.hpp"
#include "Solvers/Electrostatics.hpp"
#include "Solvers/DarcyFlow.hpp"
#include "Solvers/Eigenvalue.hpp"
#include "Solvers/FractionalPDE.hpp"
#include "Solvers/HeatTransfer.hpp"
#include "Solvers/Hyperelasticity.hpp"
#include "Solvers/IncompressibleElasticity.hpp"
#include "Solvers/JouleHeating.hpp"
#include "Solvers/LinearElasticity.hpp"
#include "Solvers/Magnetostatics.hpp"
#include "Solvers/NavierStokes.hpp"
#include "Solvers/SurfacePDE.hpp"
#include "Solvers/StokesFlow.hpp"
#include "Solvers/StructuralModal.hpp"
#include "Solvers/TransientMaxwell.hpp"

#include <mfem.hpp>
#include <nlohmann/json.hpp>

#if defined(MFEM_USE_MPI)
#include <mpi.h>
#endif

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace
{
struct DriverArgs
{
    std::string input_path;
    std::string result_path;
    std::string summary_path;
    std::string vtk_path;
};

using autosage::SolveSummary;

#if defined(MFEM_USE_MPI)
class MPIContext
{
public:
    MPIContext(int &argc, char **&argv)
    {
        int initialized = 0;
        if (MPI_Initialized(&initialized) != MPI_SUCCESS)
        {
            throw std::runtime_error("Failed to query MPI initialization state.");
        }
        if (!initialized)
        {
            if (MPI_Init(&argc, &argv) != MPI_SUCCESS)
            {
                throw std::runtime_error("MPI_Init failed.");
            }
            started_here_ = true;
        }
    }

    ~MPIContext()
    {
        int finalized = 0;
        if (MPI_Finalized(&finalized) == MPI_SUCCESS && !finalized && started_here_)
        {
            MPI_Finalize();
        }
    }

private:
    bool started_here_ = false;
};
#endif

std::string require_flag_value(int argc, char **argv, const std::string &flag)
{
    for (int i = 1; i + 1 < argc; ++i)
    {
        if (flag == argv[i]) { return argv[i + 1]; }
    }
    throw std::runtime_error("Missing required flag: " + flag);
}

DriverArgs parse_args(int argc, char **argv)
{
    return DriverArgs{
        require_flag_value(argc, argv, "--input"),
        require_flag_value(argc, argv, "--result"),
        require_flag_value(argc, argv, "--summary"),
        require_flag_value(argc, argv, "--vtk")
    };
}

std::string read_text(const std::string &path)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) { throw std::runtime_error("Unable to open file for reading: " + path); }
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

void write_text(const std::string &path, const std::string &text)
{
    fs::create_directories(fs::path(path).parent_path());
    std::ofstream out(path, std::ios::binary);
    if (!out) { throw std::runtime_error("Unable to open file for writing: " + path); }
    out << text;
}

void write_json(const std::string &path, const json &value)
{
    write_text(path, value.dump(2));
}

std::string to_lower(std::string value)
{
    std::transform(
        value.begin(),
        value.end(),
        value.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

std::vector<unsigned char> decode_base64(const std::string &input)
{
    static constexpr unsigned char kInvalid = 255;
    static unsigned char table[256];
    static bool initialized = false;
    if (!initialized)
    {
        std::fill(std::begin(table), std::end(table), kInvalid);
        const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (size_t i = 0; i < alphabet.size(); ++i)
        {
            table[static_cast<unsigned char>(alphabet[i])] = static_cast<unsigned char>(i);
        }
        initialized = true;
    }

    std::vector<unsigned char> output;
    int val = 0;
    int valb = -8;
    for (unsigned char c : input)
    {
        if (c == '=' || c == '\n' || c == '\r' || c == ' ' || c == '\t') { continue; }
        unsigned char decoded = table[c];
        if (decoded == kInvalid) { throw std::runtime_error("Invalid base64 mesh data."); }
        val = (val << 6) + decoded;
        valb += 6;
        if (valb >= 0)
        {
            output.push_back(static_cast<unsigned char>((val >> valb) & 0xFF));
            valb -= 8;
        }
    }
    return output;
}

json load_input_json(const std::string &input_path)
{
    const std::string text = read_text(input_path);
    return json::parse(text);
}

std::string normalize_solver_class(const std::string &raw_solver_class)
{
    const std::string normalized = to_lower(raw_solver_class);
    if (normalized == "poisson") { return "Poisson"; }
    if (normalized == "linearelasticity" || normalized == "linear_elasticity" || normalized == "linear-elasticity")
    {
        return "LinearElasticity";
    }
    if (normalized == "navierstokes" || normalized == "navier_stokes" || normalized == "navier-stokes")
    {
        return "NavierStokes";
    }
    if (normalized == "stokes" || normalized == "stokesflow" || normalized == "stokes_flow" || normalized == "stokes-flow")
    {
        return "StokesFlow";
    }
    if (normalized == "heattransfer" || normalized == "heat_transfer" || normalized == "heat-transfer")
    {
        return "HeatTransfer";
    }
    if (normalized == "jouleheating" || normalized == "joule_heating" || normalized == "joule-heating")
    {
        return "JouleHeating";
    }
    if (normalized == "electrostatics" || normalized == "electro_statics" || normalized == "electro-statics")
    {
        return "Electrostatics";
    }
    if (normalized == "electromagnetics" || normalized == "electro_magnetics" || normalized == "electro-magnetics")
    {
        return "Electromagnetics";
    }
    if (normalized == "electromagneticmodal" || normalized == "electromagnetic_modal" || normalized == "electromagnetic-modal" ||
        normalized == "emmodal" || normalized == "em_modal" || normalized == "em-modal")
    {
        return "ElectromagneticModal";
    }
    if (normalized == "electromagneticscattering" || normalized == "electromagnetic_scattering" ||
        normalized == "electromagnetic-scattering" || normalized == "emscattering" ||
        normalized == "em_scattering" || normalized == "em-scattering")
    {
        return "ElectromagneticScattering";
    }
    if (normalized == "magnetostatics" || normalized == "magneto_statics" || normalized == "magneto-statics")
    {
        return "Magnetostatics";
    }
    if (normalized == "darcyflow" || normalized == "darcy_flow" || normalized == "darcy-flow")
    {
        return "DarcyFlow";
    }
    if (normalized == "acousticwave" || normalized == "acoustic_wave" || normalized == "acoustic-wave")
    {
        return "AcousticWave";
    }
    if (normalized == "advection" || normalized == "linearadvection" || normalized == "linear_advection" || normalized == "linear-advection")
    {
        return "Advection";
    }
    if (normalized == "dpglaplace" || normalized == "dpg_laplace" || normalized == "dpg-laplace")
    {
        return "DPGLaplace";
    }
    if (normalized == "amrlaplace" || normalized == "amr_laplace" || normalized == "amr-laplace")
    {
        return "AMRLaplace";
    }
    if (normalized == "anisotropicdiffusion" || normalized == "anisotropic_diffusion" ||
        normalized == "anisotropic-diffusion")
    {
        return "AnisotropicDiffusion";
    }
    if (normalized == "surfacepde" || normalized == "surface_pde" || normalized == "surface-pde")
    {
        return "SurfacePDE";
    }
    if (normalized == "eigenvalue" || normalized == "eigen_value" || normalized == "eigen-value")
    {
        return "Eigenvalue";
    }
    if (normalized == "fractionalpde" || normalized == "fractional_pde" || normalized == "fractional-pde")
    {
        return "FractionalPDE";
    }
    if (normalized == "structuralmodal" || normalized == "structural_modal" || normalized == "structural-modal")
    {
        return "StructuralModal";
    }
    if (normalized == "compressibleeuler" || normalized == "compressible_euler" || normalized == "compressible-euler")
    {
        return "CompressibleEuler";
    }
    if (normalized == "elastodynamics" || normalized == "elasto_dynamics" || normalized == "elasto-dynamics")
    {
        return "Elastodynamics";
    }
    if (normalized == "transientmaxwell" || normalized == "transient_maxwell" || normalized == "transient-maxwell" ||
        normalized == "transientem" || normalized == "transient_em" || normalized == "transient-em")
    {
        return "TransientMaxwell";
    }
    if (normalized == "hyperelastic" || normalized == "hyper_elastic" || normalized == "hyper-elastic" ||
        normalized == "hyperelasticity" || normalized == "hyper_elasticity" || normalized == "hyper-elasticity")
    {
        return "Hyperelastic";
    }
    if (normalized == "incompressibleelasticity" || normalized == "incompressible_elasticity" ||
        normalized == "incompressible-elasticity")
    {
        return "IncompressibleElasticity";
    }
    throw std::runtime_error(
        "solver_class must be LinearElasticity, Poisson, NavierStokes, StokesFlow, HeatTransfer, "
        "JouleHeating, Electrostatics, Electromagnetics, ElectromagneticModal, ElectromagneticScattering, Magnetostatics, DarcyFlow, AcousticWave, Advection, DPGLaplace, AMRLaplace, AnisotropicDiffusion, SurfacePDE, Eigenvalue, FractionalPDE, StructuralModal, "
        "CompressibleEuler, Elastodynamics, TransientMaxwell, Hyperelastic, or IncompressibleElasticity.");
}

const json &require_object_field(const json &object, const std::string &field_name)
{
    if (!object.contains(field_name) || !object[field_name].is_object())
    {
        throw std::runtime_error(field_name + " must be an object.");
    }
    return object[field_name];
}

std::string prepare_mesh_file(const json &mesh, const fs::path &working_dir)
{
    const std::string mesh_type = to_lower(mesh.value("type", ""));
    if (mesh_type == "file")
    {
        const std::string path = mesh.value("path", "");
        if (path.empty()) { throw std::runtime_error("mesh.path is required when mesh.type=file."); }
        return path;
    }
    if (mesh_type == "inline_mfem")
    {
        const std::string data = mesh.value("data", "");
        if (data.empty()) { throw std::runtime_error("mesh.data is required when mesh.type=inline_mfem."); }
        const std::string encoding = to_lower(mesh.value("encoding", "plain"));
        const fs::path mesh_path = working_dir / "inline.mesh";
        if (encoding == "base64")
        {
            const std::vector<unsigned char> decoded = decode_base64(data);
            fs::create_directories(mesh_path.parent_path());
            std::ofstream out(mesh_path, std::ios::binary);
            if (!out) { throw std::runtime_error("Unable to write inline mesh file."); }
            out.write(reinterpret_cast<const char *>(decoded.data()), static_cast<std::streamsize>(decoded.size()));
        }
        else if (encoding == "plain")
        {
            write_text(mesh_path.string(), data);
        }
        else
        {
            throw std::runtime_error("mesh.encoding must be plain or base64.");
        }
        return mesh_path.string();
    }

    throw std::runtime_error("mesh.type must be inline_mfem or file.");
}

const json *analysis_opts_or_null(const json &config)
{
    if (config.contains("analysis_opts") && config["analysis_opts"].is_object())
    {
        return &config["analysis_opts"];
    }
    return nullptr;
}

int analysis_max_iter(const json &config, int fallback)
{
    const json *opts = analysis_opts_or_null(config);
    if (opts != nullptr && opts->contains("max_iter") && (*opts)["max_iter"].is_number_integer())
    {
        const int value = (*opts)["max_iter"].get<int>();
        if (value > 0) { return value; }
    }
    return fallback;
}

double analysis_rel_tol(const json &config, double fallback)
{
    const json *opts = analysis_opts_or_null(config);
    if (opts != nullptr && opts->contains("rel_tol") && (*opts)["rel_tol"].is_number())
    {
        const double value = (*opts)["rel_tol"].get<double>();
        if (value > 0.0) { return value; }
    }
    return fallback;
}

std::vector<int> fixed_attributes(const json &config)
{
    std::vector<int> attributes;
    if (config.contains("fixed_attributes") && config["fixed_attributes"].is_array())
    {
        for (const auto &value : config["fixed_attributes"])
        {
            if (value.is_number_integer())
            {
                const int attr = value.get<int>();
                if (attr > 0) { attributes.push_back(attr); }
            }
        }
    }

    for (const std::string key : {"bcs", "boundary_conditions"})
    {
        if (!config.contains(key) || !config[key].is_array()) { continue; }
        for (const auto &bc : config[key])
        {
            if (!bc.is_object()) { continue; }
            if (to_lower(bc.value("type", "")) != "fixed") { continue; }
            if (!bc.contains("attribute") || !bc["attribute"].is_number_integer()) { continue; }
            const int attr = bc["attribute"].get<int>();
            if (attr > 0) { attributes.push_back(attr); }
        }
    }

    return attributes;
}

mfem::Array<int> fixed_boundary_markers(const json &config, int max_attr)
{
    mfem::Array<int> marker(max_attr);
    marker = 0;

    const std::vector<int> attrs = fixed_attributes(config);
    for (const int attr : attrs)
    {
        if (attr >= 1 && attr <= marker.Size()) { marker[attr - 1] = 1; }
    }
    return marker;
}

void add_load_components(const json &values, mfem::Vector &load)
{
    if (!values.is_array()) { return; }
    const int count = std::min<int>(load.Size(), static_cast<int>(values.size()));
    for (int i = 0; i < count; ++i)
    {
        if (values[i].is_number()) { load[i] += values[i].get<double>(); }
    }
}

mfem::Vector load_vector_from_config(const json &config, int dim)
{
    mfem::Vector load(dim);
    load = 0.0;

    if (config.contains("load")) { add_load_components(config["load"], load); }
    if (config.contains("body_force")) { add_load_components(config["body_force"], load); }

    for (const std::string key : {"bcs", "boundary_conditions"})
    {
        if (!config.contains(key) || !config[key].is_array()) { continue; }
        for (const auto &bc : config[key])
        {
            if (!bc.is_object()) { continue; }
            if (to_lower(bc.value("type", "")) != "load") { continue; }
            if (bc.contains("value")) { add_load_components(bc["value"], load); }
        }
    }
    return load;
}

double poisson_rhs(const json &config, int dim)
{
    if (config.contains("rhs") && config["rhs"].is_number())
    {
        return config["rhs"].get<double>();
    }
    const mfem::Vector load = load_vector_from_config(config, dim);
    return load.Size() > 0 ? load[0] : 0.0;
}

void write_solution_vtk(const std::string &vtk_path, mfem::Mesh &mesh, mfem::GridFunction &solution, const std::string &field_name)
{
    fs::create_directories(fs::path(vtk_path).parent_path());
    std::ofstream out(vtk_path);
    if (!out) { throw std::runtime_error("Unable to write VTK output: " + vtk_path); }
    mesh.PrintVTK(out, 1);
    solution.SaveVTK(out, field_name.c_str(), 1);
}

SolveSummary solve_poisson(const json &config, mfem::Mesh &mesh, const std::string &vtk_path)
{
    const int dim = mesh.Dimension();
    const int order = 1;

    mfem::H1_FECollection fec(order, dim);
    mfem::FiniteElementSpace fespace(&mesh, &fec);

    mfem::Array<int> ess_tdof_list;
    if (mesh.bdr_attributes.Size() > 0)
    {
        mfem::Array<int> ess_bdr = fixed_boundary_markers(config, mesh.bdr_attributes.Max());
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    const double rhs = poisson_rhs(config, dim);
    mfem::ConstantCoefficient rhs_coeff(rhs);

    mfem::BilinearForm a(&fespace);
    mfem::LinearForm b(&fespace);
    mfem::GridFunction x(&fespace);
    x = 0.0;

    mfem::ConstantCoefficient one(1.0);
    a.AddDomainIntegrator(new mfem::DiffusionIntegrator(one));
    b.AddDomainIntegrator(new mfem::DomainLFIntegrator(rhs_coeff));
    a.Assemble();
    b.Assemble();

    mfem::OperatorPtr A;
    mfem::Vector B, X;
    a.FormLinearSystem(ess_tdof_list, x, b, A, X, B);

    auto &A_sparse = dynamic_cast<mfem::SparseMatrix &>(*A);
    mfem::GSSmoother M(A_sparse);
    mfem::CGSolver cg;
    cg.SetRelTol(analysis_rel_tol(config, 1e-12));
    cg.SetAbsTol(0.0);
    cg.SetMaxIter(analysis_max_iter(config, 1000));
    cg.SetPrintLevel(0);
    cg.SetOperator(A_sparse);
    cg.SetPreconditioner(M);
    cg.Mult(B, X);

    mfem::Vector residual(B.Size());
    A_sparse.Mult(X, residual);
    residual -= B;

    a.RecoverFEMSolution(X, b, x);
    write_solution_vtk(vtk_path, mesh, x, "solution");

    SolveSummary summary;
    summary.energy = 0.5 * mfem::InnerProduct(X, B);
    summary.iterations = cg.GetNumIterations();
    summary.error_norm = residual.Norml2();
    summary.dimension = dim;
    return summary;
}

class PoissonSolver final : public autosage::PhysicsSolver
{
public:
    const char *Name() const override { return "Poisson"; }

    SolveSummary Run(
        mfem::Mesh &mesh,
        const json &config,
        const autosage::SolverExecutionContext &context) override
    {
        return solve_poisson(config, mesh, context.vtk_path);
    }
};

using SolverFactory = std::function<std::unique_ptr<autosage::PhysicsSolver>()>;

const std::unordered_map<std::string, SolverFactory> &solver_factories()
{
    static const std::unordered_map<std::string, SolverFactory> factories = {
        {"Poisson", [] { return std::make_unique<PoissonSolver>(); }},
        {"LinearElasticity", [] { return std::make_unique<autosage::LinearElasticitySolver>(); }},
        {"NavierStokes", [] { return std::make_unique<autosage::NavierStokesSolver>(); }},
        {"StokesFlow", [] { return std::make_unique<autosage::StokesFlowSolver>(); }},
        {"HeatTransfer", [] { return std::make_unique<autosage::HeatTransferSolver>(); }},
        {"JouleHeating", [] { return std::make_unique<autosage::JouleHeatingSolver>(); }},
        {"Electrostatics", [] { return std::make_unique<autosage::ElectrostaticsSolver>(); }},
        {"Electromagnetics", [] { return std::make_unique<autosage::ElectromagneticsSolver>(); }},
        {"ElectromagneticModal", [] { return std::make_unique<autosage::ElectromagneticModalSolver>(); }},
        {"ElectromagneticScattering", [] { return std::make_unique<autosage::ElectromagneticScatteringSolver>(); }},
        {"Magnetostatics", [] { return std::make_unique<autosage::MagnetostaticsSolver>(); }},
        {"DarcyFlow", [] { return std::make_unique<autosage::DarcyFlowSolver>(); }},
        {"AcousticWave", [] { return std::make_unique<autosage::AcousticWaveSolver>(); }},
        {"Advection", [] { return std::make_unique<autosage::AdvectionSolver>(); }},
        {"DPGLaplace", [] { return std::make_unique<autosage::DPGLaplaceSolver>(); }},
        {"AMRLaplace", [] { return std::make_unique<autosage::AMRLaplaceSolver>(); }},
        {"AnisotropicDiffusion", [] { return std::make_unique<autosage::AnisotropicDiffusionSolver>(); }},
        {"SurfacePDE", [] { return std::make_unique<autosage::SurfacePDESolver>(); }},
        {"Eigenvalue", [] { return std::make_unique<autosage::EigenvalueSolver>(); }},
        {"FractionalPDE", [] { return std::make_unique<autosage::FractionalPDESolver>(); }},
        {"StructuralModal", [] { return std::make_unique<autosage::StructuralModalSolver>(); }},
        {"CompressibleEuler", [] { return std::make_unique<autosage::CompressibleEulerSolver>(); }},
        {"Elastodynamics", [] { return std::make_unique<autosage::ElastodynamicsSolver>(); }},
        {"TransientMaxwell", [] { return std::make_unique<autosage::TransientMaxwellSolver>(); }},
        {"Hyperelastic", [] { return std::make_unique<autosage::HyperelasticSolver>(); }},
        {"IncompressibleElasticity", [] { return std::make_unique<autosage::IncompressibleElasticitySolver>(); }}
    };
    return factories;
}

std::unique_ptr<autosage::PhysicsSolver> create_solver(const std::string &solver_class)
{
    const auto &factories = solver_factories();
    const auto it = factories.find(solver_class);
    if (it == factories.end())
    {
        throw std::runtime_error("No solver registered for solver_class=" + solver_class + ".");
    }
    return it->second();
}

json build_summary_json(const SolveSummary &summary, const std::string &solver_class)
{
    return json{
        {"status", "ok"},
        {"solver_class", solver_class},
        {"energy", summary.energy},
        {"iterations", summary.iterations},
        {"error_norm", summary.error_norm},
        {"dimension", summary.dimension},
        {"summary", solver_class + " solve completed."}
    };
}
} // namespace

int main(int argc, char **argv)
{
#if defined(MFEM_USE_MPI)
    std::optional<MPIContext> mpi_context;
    try
    {
        mpi_context.emplace(argc, argv);
    }
    catch (const std::exception &ex)
    {
        std::cerr << "mfem-driver error: " << ex.what() << std::endl;
        return 1;
    }
#endif

    try
    {
#if defined(MFEM_USE_MPI)
        mfem::Hypre::Init();
#endif
        const DriverArgs args = parse_args(argc, argv);
        const fs::path working_dir = fs::absolute(fs::path(args.input_path)).parent_path();

        const json input = load_input_json(args.input_path);
        const std::string solver_class = normalize_solver_class(input.value("solver_class", ""));
        const json &mesh_input = require_object_field(input, "mesh");
        const json &config = require_object_field(input, "config");
        const std::string mesh_path = prepare_mesh_file(mesh_input, working_dir);

        mfem::Mesh mesh(mesh_path.c_str(), 1, 1);
        mesh.EnsureNodes();

        const std::unique_ptr<autosage::PhysicsSolver> solver = create_solver(solver_class);
        const autosage::SolverExecutionContext context{
            working_dir.string(),
            args.vtk_path
        };
        const SolveSummary summary = solver->Run(mesh, config, context);

        const json summary_json = build_summary_json(summary, solver_class);
        json result_json = summary_json;
        result_json["summary_file"] = args.summary_path;
        result_json["vtk_file"] = args.vtk_path;

        write_json(args.summary_path, summary_json);
        write_json(args.result_path, result_json);
        std::cout << "mfem-driver completed " << solver_class << " solve." << std::endl;
        return 0;
    }
    catch (const std::exception &ex)
    {
        std::cerr << "mfem-driver error: " << ex.what() << std::endl;
        return 1;
    }
}
