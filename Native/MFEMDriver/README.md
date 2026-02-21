# MFEM Driver

`mfem-driver` is a dedicated native binary used by AutoSage for `fea.solve`.

It follows a strict JSON file contract:

- Input: `job_input.json`
- Outputs:
  - `job_result.json`
  - `job_summary.json`
  - `solution.vtk`

Input payload shape:

```json
{
  "solver_class": "LinearElasticity",
  "mesh": {
    "type": "file",
    "path": "/absolute/path/to/beam.mesh"
  },
  "config": {
    "materials": [{"attribute": 1, "E": 210000000000.0, "nu": 0.3}],
    "bcs": [{"attribute": 1, "type": "fixed"}],
    "analysis_opts": {"max_iter": 500, "rel_tol": 1e-10}
  }
}
```

CFD payloads use:

- `"solver_class": "NavierStokes"`
- `config.viscosity`
- `config.density`
- `config.t_final`
- `config.dt`
- `config.bcs` entries of:
  - `{ "attr": 1, "type": "inlet", "velocity": [1.0, 0.0, 0.0] }`
  - `{ "attr": 2, "type": "wall", "velocity": [0.0, 0.0, 0.0] }`
  - `{ "attr": 3, "type": "outlet", "pressure": 0.0 }`

Heat payloads use:

- `"solver_class": "HeatTransfer"`
- `config.conductivity`
- `config.specific_heat`
- `config.initial_temperature`
- `config.dt`
- `config.t_final`
- `config.bcs` entries of:
  - `{ "attribute": 1, "type": "fixed_temp", "value": 350.0 }`
  - `{ "attribute": 2, "type": "heat_flux", "value": 50.0 }`

## Build

```bash
cd Native/MFEMDriver
cmake -S . -B build
cmake --build build -j
```

By default the executable is `Native/MFEMDriver/build/mfem-driver`.

## CLI

```bash
mfem-driver \
  --input /path/to/job_input.json \
  --result /path/to/job_result.json \
  --summary /path/to/job_summary.json \
  --vtk /path/to/solution.vtk
```
