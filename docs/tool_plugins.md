# Adding Tool Plugins

Implement new tools in `AutoSageCore` by conforming to `Tool`.

Required members:

- `name`
- `version`
- `description`
- `jsonSchema`
- `run(input:context:)`

`context` includes:

- `jobID`
- `jobDirectoryURL`
- execution `limits` (timeout and output/artifact size caps)

Tool outputs should always include normalized execution fields:

- `status`
- `solver`
- `summary`
- `stdout`
- `stderr`
- `exit_code`
- `artifacts`
- `metrics`

Then register the tool in `ToolRegistry.default`.

For external-process tools (FEA/CFD/etc.):

1. Validate input strictly.
2. Write deterministic files under `context.jobDirectoryURL`.
3. Enforce timeout/size limits from `context.limits`.
4. Return bounded outputs and artifact metadata only (no unbounded arrays/logs).

`fea.solve` follows a driver-binary pattern:

1. Swift writes `job_input.json`.
2. Swift invokes only `mfem-driver` (no generic shell execution path).
3. Driver writes `job_result.json`, `job_summary.json`, and `solution.vtk`.
4. Swift reads JSON output and returns normalized tool results through AutoSage.

`fea.solve` uses a passthrough contract so Swift stays solver-agnostic:

- `solver_class`: selects native solver implementation.
- `mesh`: standard mesh object (`type`, plus `data` or `path`).
- `config`: opaque object forwarded directly to the native driver.

Do not add solver-specific physics fields to top-level Swift request structs; put them under `config`.

`cfd.solve` follows the same binary path and forwards:

- `solver_class = "NavierStokes"`
- `mesh` passthrough
- `config` with `viscosity`, `density`, `dt`, `t_final`, and `bcs`

`heat.solve` follows the same binary path and forwards:

- `solver_class = "HeatTransfer"`
- `mesh` passthrough
- `config` with `conductivity`, `specific_heat`, `initial_temperature`, `dt`, `t_final`, and `bcs`

`cad_import_truck` follows a native FFI path:

1. Swift validates `file_path`, `linear_deflection`, and output format.
2. Swift loads only the `libtruck_ffi` C API (`truck_load_step` and `truck_free_result`).
3. Rust reads STEP, tessellates to indexed triangles, and returns mesh/metadata in a C-compatible struct.
4. Swift writes the selected artifact format (`obj`, `stl`, or `glb`) under the job directory and returns bounded metadata fields.

`mesh_repair_pmp` follows a native C++ FFI path:

1. Swift validates mesh-processing arguments and computes deterministic output paths in the job directory.
2. Swift calls only the PMP C ABI (`pmp_process_mesh` / `pmp_free_result`) from `libpmp_ffi`.
3. C++ loads mesh data into `pmp::SurfaceMesh`, computes defect diagnostics, runs optional hole filling and decimation, and writes repaired/decimated meshes.
4. Swift maps FFI error codes into stable AutoSage errors (`ERR_NON_MANIFOLD_UNRESOLVABLE`, `ERR_HOLE_TOO_LARGE`, etc.) and returns bounded artifact metadata.
