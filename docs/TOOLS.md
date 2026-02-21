# AutoSage Tools Contract

## Stability levels
- Stable:
- `echo_json`
- `write_text_artifact`
- Experimental:
- Other tools in `ToolRegistry.default` may change while integrations harden.

## Naming conventions
- Prefer lowercase snake_case names (example: `echo_json`).
- Dotted names are allowed for compatibility with existing integrations (example: `circuits.simulate`).

## ToolResult JSON schema
`POST /v1/tools/execute` always returns this shape (including error responses):

```json
{
  "status": "ok|error",
  "solver": "string",
  "summary": "string",
  "stdout": "string",
  "stderr": "string",
  "exit_code": 0,
  "artifacts": [
    {
      "name": "string",
      "path": "/v1/jobs/<job_id>/artifacts/<artifact_name>",
      "mime_type": "string",
      "bytes": 0
    }
  ],
  "metrics": {
    "key": "json value"
  },
  "output": {}
}
```

## Truncation and limits
- Execution limits come from `ToolExecutionLimits`.
- If stdout/stderr are truncated, the response includes:
- `metrics.stdout_truncated_bytes`
- `metrics.stderr_truncated_bytes`
- Summary text is capped and appends a limits note when truncation/removal occurs.

## Artifact URL rules
- Artifact URLs are job-scoped:
- `/v1/jobs/<job_id>/artifacts/<artifact_name>`
- `artifact_name` is URL-encoded when needed.
- Paths are deterministic and stable for a given job ID and artifact name.
