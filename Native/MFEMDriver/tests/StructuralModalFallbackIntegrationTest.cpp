// SPDX-License-Identifier: MIT
// AutoSage MFEM driver integration test.
// Uses MFEM (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace
{
std::string shell_quote(const fs::path &path)
{
    const std::string raw = path.string();
    std::string quoted = "'";
    for (char c : raw)
    {
        if (c == '\'')
        {
            quoted += "'\\''";
        }
        else
        {
            quoted += c;
        }
    }
    quoted += "'";
    return quoted;
}

void write_text(const fs::path &path, const std::string &text)
{
    fs::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary);
    if (!out)
    {
        throw std::runtime_error("Unable to write file: " + path.string());
    }
    out << text;
}

json load_json(const fs::path &path)
{
    std::ifstream in(path, std::ios::binary);
    if (!in)
    {
        throw std::runtime_error("Unable to read JSON file: " + path.string());
    }
    return json::parse(in);
}

fs::path make_temp_dir()
{
    const fs::path base = fs::temp_directory_path();
    std::mt19937_64 rng(75);
    for (int i = 0; i < 64; ++i)
    {
        const fs::path candidate = base / ("autosage-structural-modal-fallback-" + std::to_string(rng()));
        std::error_code ec;
        if (fs::create_directory(candidate, ec))
        {
            return candidate;
        }
    }
    throw std::runtime_error("Unable to create a temporary test directory.");
}

void set_force_fallback_env()
{
#if defined(_WIN32)
    if (_putenv_s("AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK", "1") != 0)
    {
        throw std::runtime_error("Failed to set AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK.");
    }
#else
    if (setenv("AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK", "1", 1) != 0)
    {
        throw std::runtime_error("Failed to set AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK.");
    }
#endif
}

void clear_force_fallback_env()
{
#if defined(_WIN32)
    _putenv_s("AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK", "");
#else
    unsetenv("AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK");
#endif
}

int run_driver(
    const fs::path &driver_binary,
    const fs::path &input_path,
    const fs::path &result_path,
    const fs::path &summary_path,
    const fs::path &vtk_path)
{
    set_force_fallback_env();
    const std::string command =
        shell_quote(driver_binary) + " --input " + shell_quote(input_path) + " --result " +
        shell_quote(result_path) + " --summary " + shell_quote(summary_path) + " --vtk " +
        shell_quote(vtk_path);
    const int status = std::system(command.c_str());
    clear_force_fallback_env();
    return status;
}

void require(bool condition, const std::string &message)
{
    if (!condition)
    {
        throw std::runtime_error(message);
    }
}
} // namespace

int main(int argc, char **argv)
{
    try
    {
        require(argc >= 2, "Usage: StructuralModalFallbackIntegrationTest <path-to-mfem-driver>");

        const fs::path driver_binary = fs::absolute(argv[1]);
        require(fs::exists(driver_binary), "mfem-driver binary does not exist: " + driver_binary.string());

        const fs::path run_dir = make_temp_dir();
        const fs::path input_path = run_dir / "job_input.json";
        const fs::path result_path = run_dir / "job_result.json";
        const fs::path summary_path = run_dir / "job_summary.json";
        const fs::path vtk_path = run_dir / "solution.vtk";

        const char *mesh_data = R"(MFEM mesh v1.0

dimension
2

elements
1
1 2 0 1 2

boundary
3
1 1 0 1
2 1 1 2
2 1 2 0

vertices
3
2
0 0
1 0
0 1
)";

        json input_json = {
            {"solver_class", "StructuralModal"},
            {"mesh",
             {
                 {"type", "inline_mfem"},
                 {"data", mesh_data}
             }},
            {"config",
             {
                 {"density", 7800.0},
                 {"youngs_modulus", 2.0e11},
                 {"poisson_ratio", 0.3},
                 {"num_modes", 2},
                 {"bcs",
                  json::array({
                      {
                          {"attribute", 1},
                          {"type", "fixed"}
                      }
                  })}
             }}
        };

        write_text(input_path, input_json.dump(2));
        const int exit_status = run_driver(driver_binary, input_path, result_path, summary_path, vtk_path);
        require(exit_status == 0, "mfem-driver returned non-zero status.");

        const json result_json = load_json(result_path);
        require(result_json.value("status", "") == "ok", "job_result.json status was not ok.");

        const json summary_json = load_json(summary_path);
        require(summary_json.value("status", "") == "ok", "job_summary.json status was not ok.");

        const fs::path modal_json_path = run_dir / "structural_modes.json";
        require(fs::exists(modal_json_path), "Expected structural_modes.json artifact is missing.");

        const json modal_json = load_json(modal_json_path);
        require(
            modal_json.value("solver_backend", "") == "inverse_iteration_fallback",
            "Expected solver_backend=inverse_iteration_fallback."
        );
        const std::string reason = modal_json.value("fallback_reason", "");
        require(
            reason.find("AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK") != std::string::npos,
            "Expected fallback_reason to mention AUTOSAGE_STRUCTURAL_MODAL_FORCE_FALLBACK."
        );
        require(
            modal_json.contains("eigenvalues") && modal_json["eigenvalues"].is_array() &&
                !modal_json["eigenvalues"].empty(),
            "Expected structural_modes.json to contain non-empty eigenvalues array."
        );
        require(fs::exists(vtk_path), "Expected solution.vtk artifact is missing.");

        std::cout << "StructuralModal fallback integration test passed. Run dir: " << run_dir << std::endl;

        std::error_code cleanup_error;
        fs::remove_all(run_dir, cleanup_error);
        return 0;
    }
    catch (const std::exception &ex)
    {
        std::cerr << "StructuralModal fallback integration test failed: " << ex.what() << std::endl;
        return 1;
    }
}
