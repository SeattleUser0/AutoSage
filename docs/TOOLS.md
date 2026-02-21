# AutoSage Tool Catalog and Contract

## Stability Levels
- Stable tools:
- `echo_json`
- `write_text_artifact`
- Experimental tools:
- Any additional tools in `ToolRegistry.default` are available for development and may evolve.

## Naming Convention
- Use lowercase snake_case for standalone tools (for example `echo_json`).
- Domain-scoped tools may use dotted names (for example `circuits.simulate`) for compatibility.

## ToolResult Contract
All tool executions returned by `POST /v1/tools/execute` conform to the normalized JSON contract:

```json
{
  "status": "ok|error",
  "solver": "tool_or_solver_name",
  "summary": "short human-readable summary",
  "stdout": "string",
  "stderr": "string",
  "exit_code": 0,
  "artifacts": [
    {
      "name": "file.ext",
      "path": "/v1/jobs/<job_id>/artifacts/file.ext",
      "mime_type": "application/octet-stream",
      "bytes": 123
    }
  ],
  "metrics": {},
  "output": {}
}
```

Notes:
- `POST /v1/tools/execute` always returns this JSON shape, even for errors.
- Execution limits from `ToolExecutionLimits` are applied and reported in `metrics` when truncation occurs.
