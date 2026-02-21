# vtk_ffi

C++ flat C ABI wrapper for headless VTK rendering, used by AutoSage `render_pack_vtk`.

## Build

```bash
cmake -S Native/vtk_ffi -B Native/vtk_ffi/build
cmake --build Native/vtk_ffi/build -j
```

If CMake cannot find VTK, set `VTK_DIR` to the folder containing `VTKConfig.cmake`
or add the VTK prefix to `CMAKE_PREFIX_PATH`.

Expected output on macOS:

- `Native/vtk_ffi/build/libvtk_ffi.dylib`

## API

Header: `include/vtk_ffi.h`

- `vtk_render_pack(...)`
- `vtk_free_result(...)`

The function returns `VtkRenderOutput` with:

- per-view buffer paths (`color_path`, `depth_path`, `normal_path`)
- 3x3 camera intrinsics matrix (flat row-major array)
- `error_code`
- `error_message`

No C++ exception crosses the C ABI boundary.
