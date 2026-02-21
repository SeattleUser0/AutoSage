# AutoSage

[![AutoSage CI](https://github.com/SeattleUser0/AutoSage/actions/workflows/ci.yml/badge.svg)](https://github.com/SeattleUser0/AutoSage/actions/workflows/ci.yml)

AutoSage is a Swift HTTP backend that exposes OpenAI-compatible routes plus a deterministic tool execution loop. The current stable integration surface is `echo_json` and `write_text_artifact`; other tools are available as experimental integrations.

- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Tool Contract](docs/TOOLS.md)
- [Dependency Modes](docs/DEPENDENCIES.md)

## Quickstart
```bash
git clone https://github.com/SeattleUser0/AutoSage.git
cd AutoSage
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

Optional filters:
```bash
curl -s "http://127.0.0.1:8080/v1/tools?stability=stable"
curl -s "http://127.0.0.1:8080/v1/tools?tags=artifact,pde"
```

### `POST /v1/tools/execute` (stable example: `echo_json`)
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

### `POST /v1/tools/execute` (stable example: `write_text_artifact`)
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

## OpenAPI
Source of truth: `openapi/openapi.yaml`.
The server serves both `/openapi.yaml` and `/openapi.json`.

### `GET /openapi.yaml`
```bash
curl -s http://127.0.0.1:8080/openapi.yaml
```

### `GET /openapi.json`
```bash
curl -s http://127.0.0.1:8080/openapi.json
```

## What works on a clean machine
With only Swift installed:
- server startup
- `/healthz`
- `/openapi.yaml` and `/openapi.json`
- `/v1/tools`
- stable tool execution (`echo_json`, `write_text_artifact`)

Some tools require native dependencies (MFEM, ngspice, FFI bridge libraries). See `docs/DEPENDENCIES.md`.

## Testing
```bash
swift test
```
