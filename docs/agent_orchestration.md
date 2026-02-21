# Agent Orchestration Notes

AutoSage supports OpenAI-style routes used by tool-calling orchestrators:

- `POST /v1/responses`
- `POST /v1/chat/completions`

AutoSage also exposes a generic orchestration bootstrap route:

- `GET /v1/agent/config`

This returns:

- `system_message` in OpenAI message format (`{"role":"system","content":"..."}`)
- `messages` with the same system message ready to inject into an OpenAI request
- `tools` as OpenAI function-calling descriptors (`type=function`, `function.name`, `function.description`, `function.parameters`)
- `manifest_path` (`manifest.json`) as the required source of truth
- deterministic `pipeline_sequence`
- deterministic `error_routing`
- deterministic `escalation_errors`

Related session/workspace routes used by frontend and orchestrator loops:

- `POST /v1/sessions` (multipart upload + workspace initialization)
- `GET /v1/sessions/{session_id}` (manifest polling)
- `POST /v1/sessions/{session_id}/chat` (prompt ingestion + SSE updates)
- `GET /v1/sessions/{session_id}/assets/{asset_path...}` (artifact serving)

Example:

```bash
curl -s http://127.0.0.1:8080/v1/agent/config
```

Expected behavior encoded in the returned prompt:

- Run the pipeline in this order: `cad_import_truck -> mesh_repair_pmp -> volume_mesh_quartet -> solve -> render_pack_vtk`
- Read/write `manifest.json` on every iteration
- Route `ERR_NOT_WATERTIGHT` to `mesh_repair_pmp`
- Request user intervention only for `ERR_NON_MANIFOLD_UNRESOLVABLE`

Use `tool_choice` with a function payload to force a tool run with structured arguments.

Example (`circuits.simulate`):

```json
{
  "model": "autosage-0.1",
  "messages": [{"role": "user", "content": "run tool"}],
  "tool_choice": {
    "type": "function",
    "function": {
      "name": "circuits.simulate",
      "arguments": {
        "netlist": "V1 in 0 DC 1\nR1 in 0 1k\n.end",
        "control": ["op", "quit"]
      }
    }
  }
}
```

Example (`fea.solve` via MFEM driver):

```json
{
  "model": "autosage-0.1",
  "messages": [{"role": "user", "content": "run fea"}],
  "tool_choice": {
    "type": "function",
    "function": {
      "name": "fea.solve",
      "arguments": {
        "solver_class": "LinearElasticity",
        "mesh": {
          "type": "file",
          "path": "/absolute/path/to/beam.mesh"
        },
        "config": {
          "materials": [
            {"attribute": 1, "E": 210000000000.0, "nu": 0.3}
          ],
          "bcs": [
            {"attribute": 1, "type": "fixed"},
            {"attribute": 2, "type": "load", "value": [0, -1000, 0]}
          ],
          "analysis_opts": {
            "max_iter": 500,
            "rel_tol": 1e-10
          }
        }
      }
    }
  }
}
```

Example (`cfd.solve` via MFEM driver):

```json
{
  "model": "autosage-0.1",
  "messages": [{"role": "user", "content": "run cfd"}],
  "tool_choice": {
    "type": "function",
    "function": {
      "name": "cfd.solve",
      "arguments": {
        "solver_class": "NavierStokes",
        "mesh": {
          "type": "file",
          "path": "/absolute/path/to/channel.mesh"
        },
        "config": {
          "viscosity": 0.001,
          "density": 1.2,
          "dt": 0.01,
          "t_final": 1.0,
          "bcs": [
            {"attr": 1, "type": "inlet", "velocity": [1.0, 0.0, 0.0]},
            {"attr": 2, "type": "wall", "velocity": [0.0, 0.0, 0.0]},
            {"attr": 3, "type": "outlet", "pressure": 0.0}
          ]
        }
      }
    }
  }
}
```

Example (`heat.solve` via MFEM driver):

```json
{
  "model": "autosage-0.1",
  "messages": [{"role": "user", "content": "run heat transfer"}],
  "tool_choice": {
    "type": "function",
    "function": {
      "name": "heat.solve",
      "arguments": {
        "solver_class": "HeatTransfer",
        "mesh": {
          "type": "file",
          "path": "/absolute/path/to/domain.mesh"
        },
        "config": {
          "conductivity": 1.0,
          "specific_heat": 1.0,
          "initial_temperature": 293.15,
          "dt": 0.01,
          "t_final": 1.0,
          "bcs": [
            {"attribute": 1, "type": "fixed_temp", "value": 350.0},
            {"attribute": 2, "type": "heat_flux", "value": 50.0}
          ]
        }
      }
    }
  }
}
```

Example (`cad_import_truck` via Truck FFI):

```json
{
  "model": "autosage-0.1",
  "messages": [{"role": "user", "content": "import CAD STEP"}],
  "tool_choice": {
    "type": "function",
    "function": {
      "name": "cad_import_truck",
      "arguments": {
        "file_path": "/absolute/path/to/model.step",
        "linear_deflection": 0.001,
        "output_format": "obj",
        "output_file": "model_mesh"
      }
    }
  }
}
```

Example (`mesh_repair_pmp` via PMP FFI):

```json
{
  "model": "autosage-0.1",
  "messages": [{"role": "user", "content": "repair mesh defects"}],
  "tool_choice": {
    "type": "function",
    "function": {
      "name": "mesh_repair_pmp",
      "arguments": {
        "input_path": "/absolute/path/to/model.obj",
        "target_decimation_faces": 5000,
        "fill_holes": true,
        "resolve_intersections": true
      }
    }
  }
}
```

If a tool finishes quickly, result data is returned inline in `tool_results`.  
If not, a job reference with `job_id` is returned and should be polled via `/v1/jobs/{job_id}`.
