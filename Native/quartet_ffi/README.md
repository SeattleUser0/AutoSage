# quartet_ffi

C++ flat C ABI wrapper for Quartet tetrahedral meshing, used by AutoSage `volume_mesh_quartet`.

## Build

```bash
cmake -S Native/quartet_ffi -B Native/quartet_ffi/build
cmake --build Native/quartet_ffi/build -j
```

If Quartet is installed in a non-standard location, set `QUARTET_ROOT` to the install prefix:

```bash
export QUARTET_ROOT=/absolute/path/to/quartet/install
```

Expected output on macOS:

- `Native/quartet_ffi/build/libquartet_ffi.dylib`

## API

Header: `include/quartet_ffi.h`

- `quartet_generate_mesh(...)`
- `quartet_free_result(...)`

The API returns `QuartetResult` with:

- meshing statistics (`QuartetStats`)
- `error_code`
- `error_message`

No C++ exception crosses the C ABI boundary.
