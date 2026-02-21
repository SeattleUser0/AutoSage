# open3d_ffi

C++ flat C ABI wrapper for Open3D primitive fitting, used by AutoSage `dsl_fit_open3d`.

## Build

```bash
cmake -S Native/open3d_ffi -B Native/open3d_ffi/build
cmake --build Native/open3d_ffi/build -j
```

If CMake cannot find Open3D, set `Open3D_DIR` (or `CMAKE_PREFIX_PATH`) to the directory containing `Open3DConfig.cmake`.

Expected output on macOS:

- `Native/open3d_ffi/build/libopen3d_ffi.dylib`

## API

Header: `include/open3d_ffi.h`

- `open3d_extract_primitives(...)`
- `open3d_free_result(...)`

The API returns `O3DResult` with:

- extracted primitive list (`O3DPrimitive`)
- `unassigned_points_ratio`
- `error_code`
- `error_message`

No C++ exception crosses the C ABI boundary.
