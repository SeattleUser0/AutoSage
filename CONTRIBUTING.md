# Contributing to AutoSage

## Prerequisites
- Swift toolchain compatible with `swift-tools-version: 5.7`.
- macOS is the primary development environment (CI runs on `macos-latest`).

## Build
```bash
swift build
```

## Test
```bash
swift test
```

## Run the Server
```bash
swift run AutoSageServer --host 127.0.0.1 --port 8080
```

## Adding a Tool (Checklist)
1. Implement the tool in `Sources/AutoSageCore/Tools/`.
2. Register it in `ToolRegistry.default` with:
   - `name`
   - non-empty `description`
   - non-empty `jsonSchema`
   - `stability`, `version`, `tags`
   - examples for stable tools
3. Add/update tests:
   - tool behavior unit tests
   - schema/metadata contract tests
   - endpoint coverage if response shape changes
4. Verify the tool appears in `GET /v1/tools` and executes via `POST /v1/tools/execute`.

## Conventions
- Keep changes small and reviewable.
- Preserve deterministic, size-bounded outputs.
- Keep line lengths reasonable (guarded by tests for key files).
- Do not add non-permissive dependencies (allowed: MIT/BSD/Apache-2.0/ISC/zlib).

## CI Expectations
- GitHub Actions runs `swift --version` and `swift test` on `macos-latest`.
- Contributions should pass `swift test` locally before opening a PR.
