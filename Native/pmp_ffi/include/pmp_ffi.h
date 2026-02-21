// SPDX-License-Identifier: MIT

#ifndef PMP_FFI_H
#define PMP_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum PmpErrorCode {
    PMP_SUCCESS = 0,
    PMP_ERR_INVALID_ARGUMENT = 1,
    PMP_ERR_IO = 2,
    PMP_ERR_ALGORITHM = 3,
    PMP_ERR_NON_MANIFOLD_UNRESOLVABLE = 4,
    PMP_ERR_HOLE_FILL_FAILED = 5
};

typedef struct PmpDefectReport {
    int initial_holes;
    int initial_non_manifold_edges;
    int initial_degenerate_faces;
    int unresolved_errors;
} PmpDefectReport;

typedef struct PmpResult {
    PmpDefectReport report;
    int error_code;
    const char *error_message;
} PmpResult;

PmpResult *pmp_process_mesh(const char *input_path,
                            const char *repaired_output_path,
                            const char *decimated_output_path,
                            int target_decimation_faces,
                            int fill_holes,
                            int resolve_intersections);

void pmp_free_result(PmpResult *result);

#ifdef __cplusplus
}
#endif

#endif // PMP_FFI_H
