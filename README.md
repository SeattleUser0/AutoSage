# AutoSage

AutoSage is a Swift HTTP server that exposes OpenAI-compatible routes and a minimal tool execution API. Today it supports health checks, OpenAI-style `responses` and `chat/completions` stubs, tool discovery, and deterministic tool execution through `echo_json` and `write_text_artifact`.

## Quickstart
```bash
cd "/Users/jeremiahconner/Documents/CodeX Projects/AutoSage"
swift build
swift run AutoSageServer --host 127.0.0.1 --port 8080
```

## API
All examples assume the server is running on `127.0.0.1:8080`.

### `GET /healthz`
```bash
curl -s http://127.0.0.1:8080/healthz
```

### `GET /v1/tools`
```bash
curl -s http://127.0.0.1:8080/v1/tools
```

### `POST /v1/tools/execute` (success path)
```bash
curl -s http://127.0.0.1:8080/v1/tools/execute \
  -H 'Content-Type: application/json' \
  -d '{
    "tool": "echo_json",
    "input": {
      "message": "hello",
      "n": 2
    }
  }'
```

### `POST /v1/tools/execute` (artifact path)
```bash
curl -s http://127.0.0.1:8080/v1/tools/execute \
  -H 'Content-Type: application/json' \
  -d '{
    "tool": "write_text_artifact",
    "input": {
      "filename": "note.txt",
      "text": "artifact demo"
    }
  }'
```

### `POST /v1/tools/execute` (error path still returns ToolResult)
```bash
curl -s -i http://127.0.0.1:8080/v1/tools/execute \
  -H 'Content-Type: application/json' \
  -d '{
    "tool": "does.not.exist",
    "input": {}
  }'
```

### `POST /v1/responses`
```bash
curl -s http://127.0.0.1:8080/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "autosage-0.1",
    "input": [
      { "role": "user", "content": "hello" }
    ]
  }'
```

### `POST /v1/chat/completions`
```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "autosage-0.1",
    "messages": [
      { "role": "user", "content": "hello" }
    ]
  }'
```

## Tooling
Tool stability and the normalized ToolResult contract are documented in `/Users/jeremiahconner/Documents/CodeX Projects/AutoSage/docs/TOOLS.md`.

## Roadmap
- Expand stable tool set beyond `echo_json` and `write_text_artifact`.
- Add more end-to-end HTTP server process tests for additional routes.
- Tighten per-tool schema validation coverage.

## Test
```bash
swift test
```
