// SPDX-License-Identifier: MIT

#include "ngspice_ffi.h"

#include <sharedspice.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <exception>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct RunContext {
    std::string stdout_log;
    std::string stderr_log;
    bool controlled_exit = false;
    int exit_code = 0;
    bool quit_exit = false;
};

char *dup_c_string(const std::string &value)
{
    const auto size = value.size();
    auto *out = new char[size + 1];
    std::memcpy(out, value.c_str(), size + 1);
    return out;
}

NgspiceResult *make_result(int code,
                           const std::string &message,
                           const std::string &stdout_log,
                           const std::string &stderr_log)
{
    auto *result = new NgspiceResult{};
    result->vectors = nullptr;
    result->vector_count = 0;
    result->error_code = code;
    result->error_message = message.empty() ? nullptr : dup_c_string(message);
    result->stdout_log = stdout_log.empty() ? nullptr : dup_c_string(stdout_log);
    result->stderr_log = stderr_log.empty() ? nullptr : dup_c_string(stderr_log);
    return result;
}

bool non_empty_path(const char *path)
{
    return path != nullptr && path[0] != '\0';
}

std::string trim_copy(const std::string &value)
{
    std::size_t start = 0;
    while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start])) != 0) {
        ++start;
    }

    std::size_t end = value.size();
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
        --end;
    }

    return value.substr(start, end - start);
}

std::string to_lower_copy(const std::string &value)
{
    std::string output(value);
    std::transform(output.begin(), output.end(), output.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return output;
}

bool equals_case_insensitive(const std::string &a, const std::string &b)
{
    return to_lower_copy(a) == to_lower_copy(b);
}

std::string quote_path_for_command(const std::string &path)
{
    std::string escaped;
    escaped.reserve(path.size() + 8);
    escaped.push_back('"');
    for (char c : path) {
        if (c == '\\' || c == '"') {
            escaped.push_back('\\');
        }
        escaped.push_back(c);
    }
    escaped.push_back('"');
    return escaped;
}

void append_log_line(std::string &target, const char *line)
{
    if (line == nullptr) {
        return;
    }

    if (!target.empty() && target.back() != '\n') {
        target.push_back('\n');
    }
    target.append(line);
}

int callback_send_char(char *output, int, void *user_data)
{
    if (user_data == nullptr) {
        return 0;
    }

    auto *ctx = static_cast<RunContext *>(user_data);
    const std::string line = output == nullptr ? std::string() : trim_copy(output);
    if (line.empty()) {
        return 0;
    }

    const auto lower = to_lower_copy(line);
    if (lower.find("error") != std::string::npos || lower.find("warning") != std::string::npos) {
        append_log_line(ctx->stderr_log, line.c_str());
    } else {
        append_log_line(ctx->stdout_log, line.c_str());
    }

    return 0;
}

int callback_send_stat(char *status, int, void *user_data)
{
    if (user_data == nullptr) {
        return 0;
    }

    auto *ctx = static_cast<RunContext *>(user_data);
    const std::string line = status == nullptr ? std::string() : trim_copy(status);
    if (!line.empty()) {
        append_log_line(ctx->stdout_log, line.c_str());
    }
    return 0;
}

int callback_controlled_exit(int status, NG_BOOL, NG_BOOL quit_exit, int, void *user_data)
{
    if (user_data == nullptr) {
        return 0;
    }

    auto *ctx = static_cast<RunContext *>(user_data);
    ctx->controlled_exit = true;
    ctx->exit_code = status;
    ctx->quit_exit = static_cast<bool>(quit_exit);
    return 0;
}

int callback_send_data(pvecvaluesall, int, int, void *)
{
    return 0;
}

int callback_send_init_data(pvecinfoall, int, void *)
{
    return 0;
}

int callback_bg_running(NG_BOOL, int, void *)
{
    return 0;
}

bool run_command(const std::string &command, RunContext &ctx, std::string &error_out)
{
    std::string mutable_command = command;
    const int rc = ngSpice_Command(mutable_command.data());
    if (rc != 0) {
        std::ostringstream oss;
        oss << "ngSpice_Command failed for: " << command << " (rc=" << rc << ")";
        if (!ctx.stderr_log.empty()) {
            oss << "; stderr: " << ctx.stderr_log;
        }
        error_out = oss.str();
        return false;
    }

    if (ctx.controlled_exit && !ctx.quit_exit) {
        std::ostringstream oss;
        oss << "ngspice requested controlled exit (code=" << ctx.exit_code << ")";
        if (!ctx.stderr_log.empty()) {
            oss << "; stderr: " << ctx.stderr_log;
        }
        error_out = oss.str();
        return false;
    }

    return true;
}

pvector_info get_vector_info_with_fallback(const std::string &requested, const std::string &current_plot)
{
    if (requested.empty()) {
        return nullptr;
    }

    auto try_vector = [](const std::string &name) -> pvector_info {
        if (name.empty()) {
            return nullptr;
        }
        std::string mutable_name(name);
        return ngGet_Vec_Info(mutable_name.data());
    };

    if (auto *info = try_vector(requested)) {
        return info;
    }

    const std::string lower_requested = to_lower_copy(requested);
    if (!equals_case_insensitive(lower_requested, requested)) {
        if (auto *info = try_vector(lower_requested)) {
            return info;
        }
    }

    if (!current_plot.empty() && requested.find('.') == std::string::npos) {
        const std::string scoped = current_plot + "." + requested;
        if (auto *info = try_vector(scoped)) {
            return info;
        }

        const std::string scoped_lower = current_plot + "." + lower_requested;
        if (!equals_case_insensitive(scoped, scoped_lower)) {
            if (auto *info = try_vector(scoped_lower)) {
                return info;
            }
        }
    }

    if (!current_plot.empty()) {
        std::string plot_name(current_plot);
        char **all_vectors = ngSpice_AllVecs(plot_name.data());
        if (all_vectors != nullptr) {
            for (int idx = 0; all_vectors[idx] != nullptr; ++idx) {
                const std::string candidate(all_vectors[idx]);
                const auto separator = candidate.rfind('.');
                const std::string short_name = (separator == std::string::npos) ? candidate : candidate.substr(separator + 1);
                if (equals_case_insensitive(short_name, requested) || equals_case_insensitive(candidate, requested)) {
                    if (auto *info = try_vector(candidate)) {
                        return info;
                    }
                }
            }
        }
    }

    return nullptr;
}

NgspiceResult *run_impl(const char *netlist_path,
                        const char *const *requested_vectors,
                        int requested_vector_count)
{
    if (!non_empty_path(netlist_path)) {
        return make_result(
            NGSPICE_FFI_ERR_INVALID_ARGUMENT,
            "netlist_path must be a non-empty string",
            "",
            ""
        );
    }

    if (requested_vector_count < 0) {
        return make_result(
            NGSPICE_FFI_ERR_INVALID_ARGUMENT,
            "requested_vector_count must be >= 0",
            "",
            ""
        );
    }

    RunContext ctx;

    ngSpice_nospinit();
    ngSpice_nospiceinit();

    const int init_rc = ngSpice_Init(
        callback_send_char,
        callback_send_stat,
        callback_controlled_exit,
        callback_send_data,
        callback_send_init_data,
        callback_bg_running,
        &ctx
    );

    if (init_rc != 0) {
        std::ostringstream oss;
        oss << "ngSpice_Init failed (rc=" << init_rc << ")";
        return make_result(NGSPICE_FFI_ERR_INIT_FAILED, oss.str(), ctx.stdout_log, ctx.stderr_log);
    }

    std::string command_error;
    if (!run_command("set noaskquit", ctx, command_error)) {
        return make_result(NGSPICE_FFI_ERR_COMMAND_FAILED, command_error, ctx.stdout_log, ctx.stderr_log);
    }
    if (!run_command("destroy all", ctx, command_error)) {
        return make_result(NGSPICE_FFI_ERR_COMMAND_FAILED, command_error, ctx.stdout_log, ctx.stderr_log);
    }

    const std::string source_command = "source " + quote_path_for_command(netlist_path);
    if (!run_command(source_command, ctx, command_error)) {
        return make_result(NGSPICE_FFI_ERR_COMMAND_FAILED, command_error, ctx.stdout_log, ctx.stderr_log);
    }

    if (!run_command("run", ctx, command_error)) {
        return make_result(NGSPICE_FFI_ERR_COMMAND_FAILED, command_error, ctx.stdout_log, ctx.stderr_log);
    }

    std::string current_plot;
    if (char *plot = ngSpice_CurPlot(); plot != nullptr) {
        current_plot = plot;
    }

    std::vector<std::string> vector_names;
    if (requested_vectors != nullptr && requested_vector_count > 0) {
        vector_names.reserve(static_cast<std::size_t>(requested_vector_count));
        for (int idx = 0; idx < requested_vector_count; ++idx) {
            const char *name = requested_vectors[idx];
            if (name == nullptr) {
                continue;
            }
            const std::string trimmed = trim_copy(name);
            if (!trimmed.empty()) {
                vector_names.push_back(trimmed);
            }
        }
    }

    if (vector_names.empty()) {
        if (current_plot.empty()) {
            return make_result(
                NGSPICE_FFI_ERR_VECTOR_NOT_FOUND,
                "ngspice did not expose a current plot after run",
                ctx.stdout_log,
                ctx.stderr_log
            );
        }

        std::string mutable_plot(current_plot);
        char **all_vectors = ngSpice_AllVecs(mutable_plot.data());
        if (all_vectors != nullptr) {
            for (int idx = 0; all_vectors[idx] != nullptr; ++idx) {
                const std::string full_name(all_vectors[idx]);
                const auto dot_index = full_name.rfind('.');
                if (dot_index != std::string::npos && dot_index + 1 < full_name.size()) {
                    vector_names.push_back(full_name.substr(dot_index + 1));
                } else {
                    vector_names.push_back(full_name);
                }
            }
        }
    }

    if (vector_names.empty()) {
        return make_result(
            NGSPICE_FFI_ERR_VECTOR_NOT_FOUND,
            "no vectors available after simulation run",
            ctx.stdout_log,
            ctx.stderr_log
        );
    }

    auto *result = make_result(NGSPICE_FFI_SUCCESS, "", ctx.stdout_log, ctx.stderr_log);
    result->vector_count = static_cast<int>(vector_names.size());
    result->vectors = new NgspiceVector[vector_names.size()]{};

    for (std::size_t index = 0; index < vector_names.size(); ++index) {
        const std::string &requested = vector_names[index];
        pvector_info info = get_vector_info_with_fallback(requested, current_plot);
        if (info == nullptr) {
            ngspice_free_result(result);
            std::ostringstream oss;
            oss << "requested vector not found: " << requested;
            return make_result(NGSPICE_FFI_ERR_VECTOR_NOT_FOUND, oss.str(), ctx.stdout_log, ctx.stderr_log);
        }

        const int length = info->v_length;
        if (length <= 0) {
            ngspice_free_result(result);
            std::ostringstream oss;
            oss << "vector has no samples: " << requested;
            return make_result(NGSPICE_FFI_ERR_RUNTIME, oss.str(), ctx.stdout_log, ctx.stderr_log);
        }

        auto &output = result->vectors[index];
        output.name = dup_c_string(info->v_name != nullptr ? info->v_name : requested);
        output.length = length;
        output.data = new double[static_cast<std::size_t>(length)]{};

        if (info->v_realdata != nullptr) {
            std::memcpy(output.data, info->v_realdata, static_cast<std::size_t>(length) * sizeof(double));
        } else if (info->v_compdata != nullptr) {
            for (int value_index = 0; value_index < length; ++value_index) {
                output.data[value_index] = info->v_compdata[value_index].cx_real;
            }
        } else {
            ngspice_free_result(result);
            std::ostringstream oss;
            oss << "vector has no readable data: " << requested;
            return make_result(NGSPICE_FFI_ERR_RUNTIME, oss.str(), ctx.stdout_log, ctx.stderr_log);
        }
    }

    return result;
}

} // namespace

extern "C" NgspiceResult *ngspice_run_netlist(const char *netlist_path,
                                               const char *const *requested_vectors,
                                               int requested_vector_count)
{
    try {
        return run_impl(netlist_path, requested_vectors, requested_vector_count);
    } catch (const std::exception &error) {
        return make_result(NGSPICE_FFI_ERR_RUNTIME, error.what(), "", "");
    } catch (...) {
        return make_result(NGSPICE_FFI_ERR_RUNTIME, "unexpected ngspice_ffi failure", "", "");
    }
}

extern "C" void ngspice_free_result(NgspiceResult *result)
{
    if (result == nullptr) {
        return;
    }

    if (result->vectors != nullptr) {
        for (int index = 0; index < result->vector_count; ++index) {
            auto &vector = result->vectors[index];
            delete[] vector.name;
            vector.name = nullptr;
            delete[] vector.data;
            vector.data = nullptr;
            vector.length = 0;
        }
        delete[] result->vectors;
        result->vectors = nullptr;
    }

    delete[] result->error_message;
    result->error_message = nullptr;
    delete[] result->stdout_log;
    result->stdout_log = nullptr;
    delete[] result->stderr_log;
    result->stderr_log = nullptr;

    delete result;
}
