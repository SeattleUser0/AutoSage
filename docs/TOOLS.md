# AutoSage Tools Contract

All tools publish non-empty JSON Schema input documentation through `GET /v1/tools`.
Stable tools have the highest-quality examples and compatibility guarantees. Experimental tools are best-effort and may evolve.

## Stability Levels
- `stable`: supported integration surface with backward-compatible intent.
- `experimental`: available for evaluation; behavior may change.
- `deprecated`: kept for compatibility and scheduled for removal.

## Stable Tool Set
- `echo_json`
- `write_text_artifact`

## Tool Naming Conventions
- Prefer lower snake_case IDs (`echo_json`).
- Prefixes are encouraged for new tools (`mesh_`, `pde_`, `em_`, `io_`, `util_`).
- Existing compatibility IDs with dots (for example `circuits.simulate`) remain valid.
- Do not rename shipped IDs; deprecate and introduce a new ID instead.

## `/v1/tools` Contract
`GET /v1/tools` returns a deterministic, lexicographically sorted list.

Optional filters:
- `?stability=stable|experimental|deprecated`
- `?tags=tag_a,tag_b` (match any tag)

Example descriptor:

```json
{
  "name": "echo_json",
  "version": "1",
  "stability": "stable",
  "tags": ["deterministic", "util"],
  "examples": [
    {
      "title": "Echo message twice",
      "input": {
        "message": "hello",
        "n": 2
      },
      "notes": "Copy input into POST /v1/tools/execute with tool=echo_json."
    }
  ],
  "description": "Echoes a message deterministically and optionally repeats it n times.",
  "input_schema": {
    "type": "object",
    "description": "Input parameters for echo_json.",
    "properties": {
      "message": { "type": "string", "description": "Message to echo." },
      "n": { "type": "integer", "minimum": 1, "maximum": 64, "description": "Optional repeat count." }
    },
    "required": ["message"],
    "additionalProperties": false
  }
}
```

## ToolResult Contract
`POST /v1/tools/execute` always returns a ToolResult-shaped JSON body, including errors:

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
- Tool execution limits are applied from `ToolExecutionLimits`.
- If `stdout`/`stderr` are truncated, metrics include `stdout_truncated_bytes` and `stderr_truncated_bytes`.
- The summary is size-bounded and includes a `limits:` note when truncation/removal occurred.

## Artifact URL Rules
- Artifact URLs are job-scoped: `/v1/jobs/<job_id>/artifacts/<artifact_name>`.
- `artifact_name` is URL-encoded when needed.
- Paths are deterministic for a given `job_id` and artifact name.
