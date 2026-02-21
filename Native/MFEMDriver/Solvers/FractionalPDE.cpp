// SPDX-License-Identifier: MIT
// AutoSage MFEM driver extension.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include "FractionalPDE.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
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

// Adapted from MFEM example ex33 shared helper (ex33.hpp, BSD-3-Clause).
void RationalApproximation_AAA(
    const mfem::Vector &val,
    const mfem::Vector &pt,
    mfem::Array<mfem::real_t> &z,
    mfem::Array<mfem::real_t> &f,
    mfem::Vector &w,
    mfem::real_t tol,
    int max_order)
{
    const int size = val.Size();
    MFEM_VERIFY(pt.Size() == size, "size mismatch");

    mfem::Array<int> J(size);
    for (int i = 0; i < size; i++) { J[i] = i; }
    z.SetSize(0);
    f.SetSize(0);

    mfem::DenseMatrix C;
    mfem::DenseMatrix Ctemp;
    mfem::DenseMatrix A;
    mfem::DenseMatrix Am;
    mfem::Vector f_vec;
    mfem::Array<mfem::real_t> c_i;

    mfem::Vector R(val.Size());
    const mfem::real_t mean_val = val.Sum() / size;
    for (int i = 0; i < R.Size(); i++) { R(i) = mean_val; }

    for (int k = 0; k < max_order; k++)
    {
        int idx = 0;
        mfem::real_t tmp_max = 0.0;
        for (int j = 0; j < size; j++)
        {
            const mfem::real_t tmp = std::abs(val(j) - R(j));
            if (tmp > tmp_max)
            {
                tmp_max = tmp;
                idx = j;
            }
        }

        z.Append(pt(idx));
        f.Append(val(idx));
        J.DeleteFirst(idx);

        mfem::Array<mfem::real_t> C_tmp(size);
        for (int j = 0; j < size; j++)
        {
            C_tmp[j] = 1.0 / (pt(j) - pt(idx));
        }
        c_i.Append(C_tmp);
        C.UseExternalData(c_i.GetData(), C_tmp.Size(), k + 1);

        Ctemp = C;
        f_vec.SetDataAndSize(f.GetData(), f.Size());
        Ctemp.InvLeftScaling(val);
        Ctemp.RightScaling(f_vec);

        A.SetSize(C.Height(), C.Width());
        Add(C, Ctemp, -1.0, A);
        A.LeftScaling(val);

        Am.SetSize(J.Size(), A.Width());
        for (int i = 0; i < J.Size(); i++)
        {
            const int ii = J[i];
            for (int j = 0; j < A.Width(); j++)
            {
                Am(i, j) = A(ii, j);
            }
        }

#ifdef MFEM_USE_LAPACK
        mfem::DenseMatrixSVD svd(Am, 'N', 'A');
        svd.Eval(Am);
        mfem::DenseMatrix &v = svd.RightSingularvectors();
        v.GetRow(k, w);
#else
        mfem::mfem_error("Compiled without LAPACK");
#endif

        mfem::Vector aux(w);
        aux *= f_vec;
        mfem::Vector N(C.Height());
        C.Mult(aux, N);
        mfem::Vector D(C.Height());
        C.Mult(w, D);

        R = val;
        for (int i = 0; i < J.Size(); i++)
        {
            const int ii = J[i];
            R(ii) = N(ii) / D(ii);
        }

        mfem::Vector verr(val);
        verr -= R;
        if (verr.Normlinf() <= tol * val.Normlinf()) { break; }
    }
}

// Adapted from MFEM example ex33 shared helper (ex33.hpp, BSD-3-Clause).
void ComputePolesAndZeros(
    const mfem::Vector &z,
    const mfem::Vector &f,
    const mfem::Vector &w,
    mfem::Array<mfem::real_t> &poles,
    mfem::Array<mfem::real_t> &zeros,
    mfem::real_t &scale)
{
    poles.SetSize(0);
    zeros.SetSize(0);

    const int m = w.Size();
    mfem::DenseMatrix B(m + 1);
    B = 0.0;
    mfem::DenseMatrix E(m + 1);
    E = 0.0;
    for (int i = 1; i <= m; i++)
    {
        B(i, i) = 1.0;
        E(0, i) = w(i - 1);
        E(i, 0) = 1.0;
        E(i, i) = z(i - 1);
    }

#ifdef MFEM_USE_LAPACK
    mfem::DenseMatrixGeneralizedEigensystem eig1(E, B);
    eig1.Eval();
    mfem::Vector &evalues = eig1.EigenvaluesRealPart();
    for (int i = 0; i < evalues.Size(); i++)
    {
        if (mfem::IsFinite(evalues(i)))
        {
            poles.Append(evalues(i));
        }
    }
#else
    mfem::mfem_error("Compiled without LAPACK");
#endif

    B = 0.0;
    E = 0.0;
    for (int i = 1; i <= m; i++)
    {
        B(i, i) = 1.0;
        E(0, i) = w(i - 1) * f(i - 1);
        E(i, 0) = 1.0;
        E(i, i) = z(i - 1);
    }

#ifdef MFEM_USE_LAPACK
    mfem::DenseMatrixGeneralizedEigensystem eig2(E, B);
    eig2.Eval();
    mfem::Vector &evalues_2 = eig2.EigenvaluesRealPart();
    for (int i = 0; i < evalues_2.Size(); i++)
    {
        if (mfem::IsFinite(evalues_2(i)))
        {
            zeros.Append(evalues_2(i));
        }
    }
#else
    mfem::mfem_error("Compiled without LAPACK");
#endif

    scale = w * f / w.Sum();
}

// Adapted from MFEM example ex33 shared helper (ex33.hpp, BSD-3-Clause).
void PartialFractionExpansion(
    mfem::real_t scale,
    mfem::Array<mfem::real_t> &poles,
    mfem::Array<mfem::real_t> &zeros,
    mfem::Array<mfem::real_t> &coeffs)
{
    const int psize = poles.Size();
    const int zsize = zeros.Size();
    coeffs.SetSize(psize);
    coeffs = scale;

    for (int i = 0; i < psize; i++)
    {
        mfem::real_t tmp_numer = 1.0;
        for (int j = 0; j < zsize; j++)
        {
            tmp_numer *= poles[i] - zeros[j];
        }

        mfem::real_t tmp_denom = 1.0;
        for (int k = 0; k < psize; k++)
        {
            if (k != i) { tmp_denom *= poles[i] - poles[k]; }
        }
        coeffs[i] *= tmp_numer / tmp_denom;
    }
}

// Adapted from MFEM example ex33 shared helper (ex33.hpp, BSD-3-Clause).
void ComputePartialFractionApproximation(
    mfem::real_t &alpha,
    mfem::Array<mfem::real_t> &coeffs,
    mfem::Array<mfem::real_t> &poles,
    mfem::real_t lmax = 1000.0,
    mfem::real_t tol = 1e-10,
    int npoints = 1000,
    int max_order = 100)
{
    MFEM_VERIFY(alpha < 1.0, "alpha must be less than 1");
    MFEM_VERIFY(alpha > 0.0, "alpha must be greater than 0");
    MFEM_VERIFY(npoints > 2, "npoints must be greater than 2");
    MFEM_VERIFY(lmax > 0.0, "lmax must be greater than 0");
    MFEM_VERIFY(tol > 0.0, "tol must be greater than 0");

    bool print_warning = true;
#ifdef MFEM_USE_MPI
    if ((mfem::Mpi::IsInitialized() && !mfem::Mpi::Root())) { print_warning = false; }
#endif

#ifndef MFEM_USE_LAPACK
    if (print_warning)
    {
        mfem::out
            << "\n" << std::string(80, '=')
            << "\nMFEM is compiled without LAPACK."
            << "\nUsing precomputed values for PartialFractionApproximation."
            << "\nOnly alpha = 0.33, 0.5, and 0.99 are available."
            << "\nThe default is alpha = 0.5.\n" << std::string(80, '=') << "\n"
            << std::endl;
    }
    const mfem::real_t eps = std::numeric_limits<mfem::real_t>::epsilon();
    if (std::abs(alpha - 0.33) < eps)
    {
        coeffs = mfem::Array<mfem::real_t>(
            {1.821898e+03, 9.101221e+01, 2.650611e+01, 1.174937e+01,
             6.140444e+00, 3.441713e+00, 1.985735e+00, 1.162634e+00,
             6.891560e-01, 4.111574e-01, 2.298736e-01});
        poles = mfem::Array<mfem::real_t>(
            {-4.155583e+04, -2.956285e+03, -8.331715e+02, -3.139332e+02,
             -1.303448e+02, -5.563385e+01, -2.356255e+01, -9.595516e+00,
             -3.552160e+00, -1.032136e+00, -1.241480e-01});
    }
    else if (std::abs(alpha - 0.99) < eps)
    {
        coeffs = mfem::Array<mfem::real_t>(
            {2.919591e-02, 1.419750e-02, 1.065798e-02, 9.395094e-03,
             8.915329e-03, 8.822991e-03, 9.058247e-03, 9.814521e-03,
             1.180396e-02, 1.834554e-02, 9.840482e-01});
        poles = mfem::Array<mfem::real_t>(
            {-1.069683e+04, -1.769370e+03, -5.718374e+02, -2.242095e+02,
             -9.419132e+01, -4.031012e+01, -1.701525e+01, -6.810088e+00,
             -2.382810e+00, -5.700059e-01, -1.384324e-03});
    }
    else
    {
        if (std::abs(alpha - 0.5) > eps)
        {
            alpha = 0.5;
        }
        coeffs = mfem::Array<mfem::real_t>(
            {2.290262e+02, 2.641819e+01, 1.005566e+01, 5.390411e+00,
             3.340725e+00, 2.211205e+00, 1.508883e+00, 1.049474e+00,
             7.462709e-01, 5.482686e-01, 4.232510e-01, 3.578967e-01});
        poles = mfem::Array<mfem::real_t>(
            {-3.168211e+04, -3.236077e+03, -9.868287e+02, -3.945597e+02,
             -1.738889e+02, -7.925178e+01, -3.624992e+01, -1.629196e+01,
             -6.982956e+00, -2.679984e+00, -7.782607e-01, -7.649166e-02});
    }

    if (print_warning)
    {
        mfem::out << "=> Using precomputed values for alpha = " << alpha << "\n" << std::endl;
    }
    return;
#else
    MFEM_CONTRACT_VAR(print_warning);
#endif

    mfem::Vector x(npoints);
    mfem::Vector val(npoints);
    const mfem::real_t dx = lmax / static_cast<mfem::real_t>(npoints - 1);
    for (int i = 0; i < npoints; i++)
    {
        x(i) = dx * static_cast<mfem::real_t>(i);
        val(i) = std::pow(x(i), 1.0 - alpha);
    }

    mfem::Array<mfem::real_t> z;
    mfem::Array<mfem::real_t> f;
    mfem::Vector w;
    RationalApproximation_AAA(val, x, z, f, w, tol, max_order);

    mfem::Vector vecz;
    vecz.SetDataAndSize(z.GetData(), z.Size());
    mfem::Vector vecf;
    vecf.SetDataAndSize(f.GetData(), f.Size());

    mfem::real_t scale = 0.0;
    mfem::Array<mfem::real_t> zeros;
    ComputePolesAndZeros(vecz, vecf, w, poles, zeros, scale);
    zeros.DeleteFirst(0.0);
    PartialFractionExpansion(scale, poles, zeros, coeffs);
}

json to_json_array(const mfem::Array<mfem::real_t> &values, int max_entries)
{
    json out = json::array();
    const int count = std::max(0, std::min(values.Size(), max_entries));
    for (int i = 0; i < count; i++)
    {
        out.push_back(values[i]);
    }
    return out;
}
} // namespace

namespace autosage
{
const char *FractionalPDESolver::Name() const
{
    return "FractionalPDE";
}

FractionalPDESolver::ParsedConfig FractionalPDESolver::ParseConfig(
    const json &config,
    int max_boundary_attribute) const
{
    ParsedConfig parsed;

    if (!config.contains("alpha") || !config["alpha"].is_number())
    {
        throw std::runtime_error("config.alpha is required and must be numeric.");
    }
    parsed.alpha = config["alpha"].get<double>();
    if (!std::isfinite(parsed.alpha) || !(parsed.alpha > 0.0 && parsed.alpha < 1.0))
    {
        throw std::runtime_error("config.alpha must be finite and satisfy 0 < alpha < 1.");
    }

    if (!config.contains("num_poles") || !config["num_poles"].is_number_integer())
    {
        throw std::runtime_error("config.num_poles is required and must be an integer.");
    }
    parsed.num_poles = config["num_poles"].get<int>();
    if (parsed.num_poles <= 0)
    {
        throw std::runtime_error("config.num_poles must be > 0.");
    }
    if (parsed.num_poles > 256)
    {
        throw std::runtime_error("config.num_poles must be <= 256.");
    }

    if (config.contains("source_term"))
    {
        if (!config["source_term"].is_number())
        {
            throw std::runtime_error("config.source_term must be numeric when provided.");
        }
        parsed.source_term = config["source_term"].get<double>();
    }
    if (!std::isfinite(parsed.source_term))
    {
        throw std::runtime_error("config.source_term must be finite.");
    }

    if (!config.contains("bcs") || !config["bcs"].is_array())
    {
        throw std::runtime_error("config.bcs must be an array.");
    }

    const int boundary_slots = std::max(0, max_boundary_attribute);
    parsed.fixed_marker.assign(boundary_slots, 0);
    parsed.fixed_values.assign(boundary_slots, 0.0);
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
        if (!bc.contains("type") || !bc["type"].is_string())
        {
            throw std::runtime_error("config.bcs[].type is required and must be a string.");
        }
        if (!bc.contains("value") || !bc["value"].is_number())
        {
            throw std::runtime_error("config.bcs[].value is required and must be numeric.");
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
        const std::string type = to_lower(bc["type"].get<std::string>());
        if (type != "fixed")
        {
            throw std::runtime_error("config.bcs[].type must be fixed.");
        }

        const double value = bc["value"].get<double>();
        if (!std::isfinite(value))
        {
            throw std::runtime_error("config.bcs[].value must be finite.");
        }
        parsed.fixed_marker[attribute - 1] = 1;
        parsed.fixed_values[attribute - 1] = value;
    }

    const bool has_fixed = std::any_of(
        parsed.fixed_marker.begin(),
        parsed.fixed_marker.end(),
        [](int marker) { return marker != 0; }
    );
    if (!has_fixed)
    {
        throw std::runtime_error("config.bcs must include at least one fixed boundary condition.");
    }

    return parsed;
}

SolveSummary FractionalPDESolver::Run(
    mfem::Mesh &mesh,
    const json &config,
    const SolverExecutionContext &context)
{
#ifdef MFEM_USE_SINGLE
    throw std::runtime_error("FractionalPDE solver is not supported in single precision builds.");
#else
    const int dim = mesh.Dimension();
    if (dim <= 0 || dim > 3)
    {
        throw std::runtime_error("FractionalPDE supports mesh dimensions 1, 2, and 3.");
    }

    const int max_boundary_attribute = mesh.bdr_attributes.Size() > 0 ? mesh.bdr_attributes.Max() : 0;
    const ParsedConfig parsed = ParseConfig(config, max_boundary_attribute);

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

    mfem::Vector fixed_values(max_boundary_attribute);
    for (int i = 0; i < max_boundary_attribute; ++i)
    {
        fixed_values[i] = parsed.fixed_values[i];
    }
    mfem::PWConstCoefficient fixed_coeff(fixed_values);

    mfem::Array<int> ess_tdof_list;
    if (max_boundary_attribute > 0)
    {
        fespace.GetEssentialTrueDofs(ess_bdr, ess_tdof_list);
    }

    mfem::ParLinearForm b(&fespace);
    mfem::ConstantCoefficient source_coeff(parsed.source_term);
    b.AddDomainIntegrator(new mfem::DomainLFIntegrator(source_coeff));
    b.Assemble();

    mfem::Array<mfem::real_t> coeffs;
    mfem::Array<mfem::real_t> poles;
    mfem::real_t effective_alpha = parsed.alpha;
    ComputePartialFractionApproximation(
        effective_alpha,
        coeffs,
        poles,
        1000.0,
        1e-10,
        1000,
        std::max(parsed.num_poles, 2)
    );

    if (coeffs.Size() <= 0 || poles.Size() <= 0)
    {
        throw std::runtime_error("FractionalPDE rational approximation produced no poles.");
    }

    const int poles_used = std::min({parsed.num_poles, coeffs.Size(), poles.Size()});
    if (poles_used <= 0)
    {
        throw std::runtime_error("FractionalPDE requested zero usable poles.");
    }

    mfem::ParGridFunction u(&fespace);
    u = 0.0;
    if (max_boundary_attribute > 0)
    {
        u.ProjectBdrCoefficient(fixed_coeff, ess_bdr);
    }

    int total_iterations = 0;
    double max_shift_residual = 0.0;

    for (int i = 0; i < poles_used; ++i)
    {
        mfem::ParGridFunction x(&fespace);
        x = 0.0;
        if (max_boundary_attribute > 0)
        {
            x.ProjectBdrCoefficient(fixed_coeff, ess_bdr);
        }

        mfem::ParBilinearForm a(&fespace);
        mfem::ConstantCoefficient one_coeff(1.0);
        a.AddDomainIntegrator(new mfem::DiffusionIntegrator(one_coeff));
        mfem::ConstantCoefficient shift_coeff(-poles[i]);
        a.AddDomainIntegrator(new mfem::MassIntegrator(shift_coeff));
        a.Assemble();

        mfem::OperatorPtr A;
        mfem::Vector B;
        mfem::Vector X;
        a.FormLinearSystem(ess_tdof_list, x, b, A, X, B);

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
        pcg.SetTol(1.0e-10);
        pcg.SetAbsTol(0.0);
        pcg.SetMaxIter(2000);
        pcg.SetPrintLevel(0);
        pcg.SetPreconditioner(amg);
        pcg.Mult(B_hypre, X_hypre);

        int shift_iterations = 0;
        pcg.GetNumIterations(shift_iterations);
        total_iterations += shift_iterations;

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
        for (int j = 0; j < ess_tdof_list.Size(); ++j)
        {
            const int tdof = ess_tdof_list[j];
            if (tdof >= 0 && tdof < residual.Size())
            {
                residual[tdof] = 0.0;
            }
        }

        const double residual_norm =
            std::sqrt(mfem::InnerProduct(fespace.GetComm(), residual, residual));
        if (!std::isfinite(residual_norm))
        {
            throw std::runtime_error("FractionalPDE shifted solve residual is non-finite.");
        }
        max_shift_residual = std::max(max_shift_residual, residual_norm);

        a.RecoverFEMSolution(X, b, x);
        x *= coeffs[i];
        u += x;
    }

    if (max_boundary_attribute > 0)
    {
        u.ProjectBdrCoefficient(fixed_coeff, ess_bdr);
    }

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
    paraview.RegisterField("solution", &u);
    paraview.SetCycle(0);
    paraview.SetTime(0.0);
    paraview.Save();

    std::ofstream vtk_stub(context.vtk_path);
    if (!vtk_stub)
    {
        throw std::runtime_error("Unable to write solution.vtk stub for FractionalPDE.");
    }
    vtk_stub << "# fractional PDE field written to " << collection_name << ".pvd\n";

    SolveSummary summary;
    summary.energy = u.Norml2();
    summary.iterations = total_iterations;
    summary.error_norm = max_shift_residual;
    summary.dimension = dim;
    if (!std::isfinite(summary.energy) || !std::isfinite(summary.error_norm))
    {
        throw std::runtime_error("FractionalPDE produced non-finite summary metrics.");
    }

    const fs::path metadata_path = fs::path(context.working_directory) / "fractional_pde.json";
    json metadata = {
        {"solver_class", "FractionalPDE"},
        {"solver_backend", "fractional_shifted_laplacian_pcg"},
        {"alpha_requested", parsed.alpha},
        {"alpha_effective", static_cast<double>(effective_alpha)},
        {"num_poles_requested", parsed.num_poles},
        {"num_poles_used", poles_used},
        {"source_term", parsed.source_term},
        {"iterations", summary.iterations},
        {"residual_norm", summary.error_norm},
        {"l2_norm", summary.energy},
        {"coefficients", to_json_array(coeffs, 64)},
        {"poles", to_json_array(poles, 64)}
    };
    std::ofstream metadata_out(metadata_path);
    if (!metadata_out)
    {
        throw std::runtime_error("Unable to write fractional_pde.json.");
    }
    metadata_out << metadata.dump(2);

    return summary;
#else
    (void)mesh;
    (void)config;
    (void)context;
    throw std::runtime_error("FractionalPDE solver requires MFEM built with MPI.");
#endif
#endif
}
} // namespace autosage
