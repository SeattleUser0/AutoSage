# AutoSage — Agent Instructions

AutoSage is a backend toolkit that exposes an OpenAI-compatible HTTP interface so an AI agent (e.g., Open Claw) can run science/engineering solvers (FEA/CFD/circuits) through tool calls.

## Non-negotiables
- Repository license: **MIT**.
- Only allow **permissive** third-party licenses in-tree: **MIT, BSD-2/3, Apache-2.0, ISC, zlib**.
- Do **not** add GPL/LGPL/AGPL dependencies or code.
- Must build cleanly via **Swift Package Manager** and open/build in **Xcode**.

## Architecture
- Swift Package with these targets:
  - `AutoSageCore` (library): shared types and tool system.
  - `AutoSageServer` (executable): HTTP server.
- Keep solver implementations behind a narrow interface so they can be swapped/refactored later.
- All externally visible behavior must be deterministic and size-bounded.

## HTTP API (compatibility surface)
Implement and keep stable:
- `GET /healthz` → 200 with minimal JSON (status/version)
- `POST /v1/responses` → OpenAI Responses-like JSON
- `POST /v1/chat/completions` → Chat Completions-like JSON

Defaults:
- Bind to `127.0.0.1:8080` unless configured otherwise.
- Content-Type `application/json`.

## Tool system
AutoSage supports tool calls. Provide a registry that maps tool name → implementation.

Initial tools (stubs are OK):
- `fea.solve`
- `cfd.solve`
- `circuits.simulate`

Tool contract:
- Each tool has: `name`, `description`, `jsonSchema` (parameters), `run(input) -> output`.
- Tool outputs must include:
  - `status` (e.g., "ok" / "error")
  - `solver` (string identifier)
  - `summary` (short human-readable)
  - Optional arrays must be capped/truncated (never return huge payloads).

## Testing requirements
- Add unit tests for JSON decoding/encoding of request/response types.
- Add at least one handler smoke test per endpoint (request in → response shape out).
- `swift test` must pass.

## Docs and notices
- Add `README.md` with:
  - how to build/run the server
  - curl examples for `/healthz`, `/v1/responses`, `/v1/chat/completions`
  - tool-call example for one tool
- Add `THIRD_PARTY_NOTICES.md` (even if empty initially).
- If any third-party code is added later, its license text must be included and referenced.

## Development workflow
- Make small, reviewable changes.
- Keep commits cohesive and descriptive.
- Prefer minimal dependencies and simplest working implementation first.
- If anything is ambiguous, choose the simplest implementation that preserves the above constraints.
