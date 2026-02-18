# AutoSage

AutoSage is a backend toolkit that exposes an OpenAI-compatible HTTP interface for running science/engineering solvers through tool calls.

## Build and Run

```bash
cd ~/Documents/CodeX\ Projects/AutoSage
swift build
swift test
swift run AutoSageServer
```

Server defaults to `127.0.0.1:8080`.

## Endpoints

### Health

```bash
curl -s http://127.0.0.1:8080/healthz
```

### Responses API

```bash
curl -s http://127.0.0.1:8080/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "autosage-0.1",
    "input": [{"role": "user", "content": "Run a quick solve"}]
  }'
```

### Chat Completions API

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "autosage-0.1",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

## Tool Call Example

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "autosage-0.1",
    "messages": [{"role": "user", "content": "Solve with FEA"}],
    "tool_choice": "fea.solve"
  }'
```

## Jobs API

Create a job:

```bash
curl -s http://127.0.0.1:8080/v1/jobs \
  -H 'Content-Type: application/json' \
  -d '{
    "tool_name": "fea.solve",
    "input": {"mesh": "beam.msh"}
  }'
```

Fetch job status/result:

```bash
curl -s http://127.0.0.1:8080/v1/jobs/job_0001
```

Job artifacts are written under `./runs/<job_id>/summary.json`.

## Error Response Example

Invalid request payloads (invalid JSON, missing required fields) and unknown tool names return structured errors.

```json
{
  "error": {
    "code": "invalid_request",
    "message": "Missing required field: model.",
    "details": {
      "field": "model"
    }
  }
}
```
