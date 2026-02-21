// SPDX-License-Identifier: MIT

#ifndef NGSPICE_FFI_H
#define NGSPICE_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum NgspiceErrorCode {
    NGSPICE_FFI_SUCCESS = 0,
    NGSPICE_FFI_ERR_INVALID_ARGUMENT = 1,
    NGSPICE_FFI_ERR_INIT_FAILED = 2,
    NGSPICE_FFI_ERR_COMMAND_FAILED = 3,
    NGSPICE_FFI_ERR_VECTOR_NOT_FOUND = 4,
    NGSPICE_FFI_ERR_RUNTIME = 5
};

typedef struct NgspiceVector {
    const char *name;
    double *data;
    int length;
} NgspiceVector;

typedef struct NgspiceResult {
    NgspiceVector *vectors;
    int vector_count;
    int error_code;
    const char *error_message;
    const char *stdout_log;
    const char *stderr_log;
} NgspiceResult;

NgspiceResult *ngspice_run_netlist(const char *netlist_path,
                                   const char *const *requested_vectors,
                                   int requested_vector_count);

void ngspice_free_result(NgspiceResult *result);

#ifdef __cplusplus
}
#endif

#endif // NGSPICE_FFI_H
