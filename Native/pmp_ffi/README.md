# pmp_ffi

C++ flat C ABI wrapper for the Polygon Mesh Processing (PMP) library, used by AutoSage `mesh_repair_pmp`.

## Build

```bash
cmake -S Native/pmp_ffi -B Native/pmp_ffi/build
cmake --build Native/pmp_ffi/build -j
```

Expected output on macOS:

- `Native/pmp_ffi/build/libpmp_ffi.dylib`

## API

Header: `include/pmp_ffi.h`

- `pmp_process_mesh(...)`
- `pmp_free_result(...)`

The function returns `PmpResult` with:

- initial defect counts (`PmpDefectReport`)
- `error_code`
- `error_message`

No C++ exception crosses the C ABI boundary.
