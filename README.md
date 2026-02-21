# AutoSage

AutoSage is a Swift backend that exposes OpenAI-compatible HTTP endpoints for CAD/CAE orchestration.  
It provides a tool-calling surface for native solver/modeling bridges (MFEM, ngspice, Open3D, VTK, and others) while keeping orchestration deterministic and workspace-based.

## Project Layout
- `Sources/AutoSageCore`: shared server types, router, tool registry, job/session systems.
- `Sources/AutoSageServer`: executable HTTP server with CLI options.
- `Sources/AutoSageControl`: macOS SwiftUI control panel.
- `Native/`: C/C++/Rust FFI bridge code.
- `.github/workflows/`: CI and release workflows.

## Prerequisites
- macOS or Debian/Ubuntu Linux.
- Swift toolchain (macOS via Xcode CLT; Linux via your Swift install process).
- Build dependencies installed by `setup.sh`.

## Setup
Run platform dependency installation:

```bash
chmod +x setup.sh
./setup.sh
```

## Build
Build the Swift package:

```bash
swift build
```

Build native bridge artifacts:

```bash
make clean-native
make install-native-libs
```

## Run Server
Start with defaults (`127.0.0.1:8080`):

```bash
swift run AutoSageServer
```

See CLI options:

```bash
swift run AutoSageServer --help
```

Common examples:

```bash
swift run AutoSageServer --host 0.0.0.0 --port 8080 --log-level info
swift run AutoSageServer --host 127.0.0.1 --port 9000 --verbose
```

## Test
Run all Swift tests:

```bash
swift test
```

Run integration tests only:

```bash
swift test --filter AutoSageIntegrationTests
```

## API Quick Start
- Health: `GET /healthz`
- Responses API: `POST /v1/responses`
- Chat Completions API: `POST /v1/chat/completions`
- Agent bootstrap config: `GET /v1/agent/config`
- Sessions create: `POST /v1/sessions`
- Sessions get: `GET /v1/sessions/{session_id}`
- Sessions chat: `POST /v1/sessions/{session_id}/chat` (supports SSE)
- Sessions assets: `GET /v1/sessions/{session_id}/assets/{asset_path...}`
- Admin dashboard: `GET /admin`
- Admin logs: `GET /v1/admin/logs`
- Admin clear jobs: `POST /v1/admin/clear-jobs`

Example:

```bash
curl -s http://127.0.0.1:8080/healthz
```

## macOS Control Panel vs Web Admin
- `AutoSageControl` (macOS app): native SwiftUI desktop control for start/stop/reset and log viewing.
- `AutoSageControl` cleanup path: calls backend `POST /v1/admin/clear-jobs`.
- `AutoSageControl` run command: `swift run AutoSageControl`.
- `/admin` Web Admin: browser dashboard served by `AutoSageServer`.
- `/admin` platform support: macOS and Linux.
- `/admin` capabilities: status, log polling, and "Clear Jobs".
- `/admin` URL: `http://127.0.0.1:8080/admin`.

## License
- Project license: MIT (`LICENSE`).
- Third-party notice file: `THIRD_PARTY_NOTICES.md`.
