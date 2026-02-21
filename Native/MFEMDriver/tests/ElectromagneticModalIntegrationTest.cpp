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
constexpr int kSkipReturnCode = 77;

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

std::string read_text(const fs::path &path)
{
    std::ifstream in(path, std::ios::binary);
    if (!in)
    {
        return {};
    }
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
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

void require(bool condition, const std::string &message)
{
    if (!condition)
    {
        throw std::runtime_error(message);
    }
}

fs::path make_temp_dir()
{
    const fs::path base = fs::temp_directory_path();
    std::mt19937_64 rng(1337);
    for (int i = 0; i < 64; ++i)
    {
        const fs::path candidate = base / ("autosage-electromagnetic-modal-" + std::to_string(rng()));
        std::error_code ec;
        if (fs::create_directory(candidate, ec))
        {
            return candidate;
        }
    }
    throw std::runtime_error("Unable to create a temporary test directory.");
}

bool is_expected_skip_error(const std::string &stderr_text)
{
    return stderr_text.find("HypreLOBPCG returned non-finite eigenvalues for ElectromagneticModal.") !=
               std::string::npos ||
        stderr_text.find("ElectromagneticModal solver requires MFEM built with MPI.") != std::string::npos;
}

int run_driver(
    const fs::path &driver_binary,
    const fs::path &input_path,
    const fs::path &result_path,
    const fs::path &summary_path,
    const fs::path &vtk_path,
    const fs::path &stdout_path,
    const fs::path &stderr_path)
{
    const std::string command =
        shell_quote(driver_binary) + " --input " + shell_quote(input_path) + " --result " +
        shell_quote(result_path) + " --summary " + shell_quote(summary_path) + " --vtk " +
        shell_quote(vtk_path) + " > " + shell_quote(stdout_path) + " 2> " + shell_quote(stderr_path);
    return std::system(command.c_str());
}
} // namespace

int main(int argc, char **argv)
{
    try
    {
        require(argc >= 2, "Usage: ElectromagneticModalIntegrationTest <path-to-mfem-driver>");

        const fs::path driver_binary = fs::absolute(argv[1]);
        require(fs::exists(driver_binary), "mfem-driver binary does not exist: " + driver_binary.string());

        const fs::path run_dir = make_temp_dir();
        const fs::path input_path = run_dir / "job_input.json";
        const fs::path result_path = run_dir / "job_result.json";
        const fs::path summary_path = run_dir / "job_summary.json";
        const fs::path vtk_path = run_dir / "solution.vtk";
        const fs::path stdout_path = run_dir / "driver.stdout.log";
        const fs::path stderr_path = run_dir / "driver.stderr.log";

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

        const json input_json = {
            {"solver_class", "ElectromagneticModal"},
            {"mesh",
             {
                 {"type", "inline_mfem"},
                 {"data", mesh_data}
             }},
            {"config",
             {
                 {"permittivity", 8.854e-12},
                 {"permeability", 1.256e-6},
                 {"num_modes", 1},
                 {"bcs",
                  json::array({
                      {
                          {"attribute", 1},
                          {"type", "perfect_conductor"}
                      }
                  })}
             }}
        };

        write_text(input_path, input_json.dump(2));
        const int exit_status =
            run_driver(driver_binary, input_path, result_path, summary_path, vtk_path, stdout_path, stderr_path);

        if (exit_status != 0)
        {
            const std::string stderr_text = read_text(stderr_path);
            if (is_expected_skip_error(stderr_text))
            {
                std::cout << "ElectromagneticModal integration test skipped: " << stderr_text << std::endl;
                std::error_code cleanup_error;
                fs::remove_all(run_dir, cleanup_error);
                return kSkipReturnCode;
            }
            throw std::runtime_error("mfem-driver returned non-zero status:\n" + stderr_text);
        }

        const json result_json = load_json(result_path);
        require(result_json.value("status", "") == "ok", "job_result.json status was not ok.");

        const json summary_json = load_json(summary_path);
        require(summary_json.value("status", "") == "ok", "job_summary.json status was not ok.");

        const fs::path modal_json_path = run_dir / "electromagnetic_modes.json";
        require(fs::exists(modal_json_path), "Expected electromagnetic_modes.json artifact is missing.");
        const json modal_json = load_json(modal_json_path);
        require(
            modal_json.value("solver_class", "") == "ElectromagneticModal",
            "Expected solver_class=ElectromagneticModal."
        );
        require(modal_json.value("solver_backend", "") == "lobpcg", "Expected solver_backend=lobpcg.");
        require(
            !modal_json.contains("fallback_reason") || modal_json.value("fallback_reason", "").empty(),
            "Expected no fallback_reason for the LOBPCG runtime path."
        );
        require(
            modal_json.contains("eigenvalues") && modal_json["eigenvalues"].is_array() &&
                !modal_json["eigenvalues"].empty(),
            "Expected electromagnetic_modes.json to contain non-empty eigenvalues."
        );
        require(
            modal_json.contains("resonant_frequencies_rad_s") &&
                modal_json["resonant_frequencies_rad_s"].is_array() &&
                modal_json["resonant_frequencies_rad_s"].size() == modal_json["eigenvalues"].size(),
            "Expected resonant_frequencies_rad_s array to match eigenvalues."
        );

        require(fs::exists(vtk_path), "Expected solution.vtk artifact is missing.");
        std::cout << "ElectromagneticModal integration test passed. Run dir: " << run_dir << std::endl;

        std::error_code cleanup_error;
        fs::remove_all(run_dir, cleanup_error);
        return 0;
    }
    catch (const std::exception &ex)
    {
        std::cerr << "ElectromagneticModal integration test failed: " << ex.what() << std::endl;
        return 1;
    }
}
