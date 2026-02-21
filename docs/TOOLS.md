# AutoSage Tools Contract

All tools provide JSON Schema input documentation via `/v1/tools`.
Stable tools have the highest-quality schemas; experimental tools are best-effort but non-empty.

## Stability Levels
- `stable`: supported for integrations and expected to remain backward-compatible.
- `experimental`: available for evaluation; request/response behavior may change.
- `deprecated`: available for compatibility only and scheduled for removal.

## Stable Tool Set
- `echo_json`
- `write_text_artifact`

## Tool Naming Conventions
- Prefer lower snake_case IDs (example: `echo_json`).
- Category prefixes are encouraged for new tools: `mesh_`, `pde_`, `em_`, `io_`, `util_`.
- Existing IDs using dotted compatibility names (example: `circuits.simulate`) remain valid.
- Do not rename a shipped tool ID. Mark old tools `deprecated` and introduce a new ID.

## `/v1/tools` Schema
`GET /v1/tools` returns a deterministic, name-sorted list. Optional filters:
- `?stability=stable|experimental|deprecated`
- `?tags=tag_a,tag_b` (match any tag)

Example item:

```json
{
  "name": "echo_json",
  "version": "1",
  "stability": "stable",
  "tags": ["deterministic", "util"],
  "description": "Echoes a message deterministically and optionally repeats it n times.",
  "input_schema": {
    "type": "object",
    "properties": {
      "message": { "type": "string" },
      "n": { "type": "integer", "minimum": 1, "maximum": 64 }
    },
    "required": ["message"],
    "additionalProperties": false
  }
}
```

## ToolResult JSON Schema
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

## Truncation Metrics
- Execution limits are applied from `ToolExecutionLimits`.
- If stdout/stderr are truncated, the response includes:
- `metrics.stdout_truncated_bytes`
- `metrics.stderr_truncated_bytes`
- The `summary` is capped and includes a `limits:` note when truncation/removal occurs.

## Artifact URL Rules
- Artifact URLs are job-scoped:
- `/v1/jobs/<job_id>/artifacts/<artifact_name>`
- `artifact_name` is URL-encoded when needed.
- Paths are deterministic for a given job ID and artifact name.
