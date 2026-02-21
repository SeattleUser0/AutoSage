# AutoSage Dependency Modes

## 1) Core server mode (Swift-only)
With only Swift installed, the server works for:
- `GET /healthz`
- `GET /openapi.yaml` and `GET /openapi.json`
- `GET /v1/tools`
- Stable tool execution:
  - `echo_json`
  - `write_text_artifact`

## 2) Native-enabled tools mode
Some tools require external binaries or native shared libraries.
When missing, tool execution returns an error ToolResult (`status: "error"`) with a dependency-oriented error code/message.

| Dependency | Detection method | Install/config hint | Tools that depend on it |
|---|---|---|---|
| `mfem-driver` executable | `AUTOSAGE_MFEM_DRIVER` or `PATH` lookup at runtime | Build/install `mfem-driver`, set `AUTOSAGE_MFEM_DRIVER` if not on `PATH` | `fea.solve`, `cfd.solve`, and MFEM-wrapper PDE tools |
| `ngspice` executable | `PATH` check (`which ngspice`) before shell execution | Install `ngspice` and ensure it is on `PATH` | `circuits.simulate` |
| `ngspice_ffi` shared library | dynamic loader (`AUTOSAGE_NGSPICE_FFI_LIB` override or default loader search) | Build `Native/ngspice_ffi` and set `AUTOSAGE_NGSPICE_FFI_LIB` when needed | `circuit_simulate_ngspice` |
| `truck_ffi` shared library | dynamic loader (`AUTOSAGE_TRUCK_FFI_LIB` override or default loader search) | Build `Native/truck_ffi` and set `AUTOSAGE_TRUCK_FFI_LIB` when needed | `cad_import_truck` |
| `pmp_ffi` shared library | dynamic loader (`AUTOSAGE_PMP_FFI_LIB` override or default loader search) | Build `Native/pmp_ffi` and set `AUTOSAGE_PMP_FFI_LIB` when needed | `mesh_repair_pmp` |
| `quartet_ffi` shared library | dynamic loader (`AUTOSAGE_QUARTET_FFI_LIB` override or default loader search) | Build `Native/quartet_ffi` and set `AUTOSAGE_QUARTET_FFI_LIB` when needed | `volume_mesh_quartet` |
| `vtk_ffi` shared library | dynamic loader (`AUTOSAGE_VTK_FFI_LIB` override or default loader search) | Build `Native/vtk_ffi` and set `AUTOSAGE_VTK_FFI_LIB` when needed | `render_pack_vtk` |
| `open3d_ffi` shared library | dynamic loader (`AUTOSAGE_OPEN3D_FFI_LIB` override or default loader search) | Build `Native/open3d_ffi` and set `AUTOSAGE_OPEN3D_FFI_LIB` when needed | `dsl_fit_open3d` |

## Error behavior on missing dependencies
- Shell-based tools return `missing_dependency` with search-path context.
- FFI-based tools return explicit tool error codes and include configuration hints in `details.hint` where available.
