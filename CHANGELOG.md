# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-02-21
### Added
- Public HTTP contract endpoints: `GET /healthz`, `GET /v1/tools`, `POST /v1/tools/execute`.
- OpenAPI documents served at `GET /openapi.yaml` and `GET /openapi.json`.
- Stable deterministic tools: `echo_json` and `write_text_artifact`.
- Tool stability/version/tag metadata and filtering (`stability`, `tags`) on `GET /v1/tools`.
- Tool metadata contract tests for descriptions, schemas, and OpenAPI invariants.

### Changed
- `/v1/tools/execute` now applies execution caps to stdout/stderr/summary/artifacts via `ToolExecutionLimits`.
- `/v1/tools/execute` now always returns ToolResult-shaped JSON on errors.
- Request hardening: request ID echo/generation (`X-Request-Id`), body-size limit, and concurrency cap.

### Fixed
- Resource loading for OpenAPI and fixture resolution is tolerant to SwiftPM bundle layouts.
- CI and formatting guardrails were tightened with deterministic tests.
