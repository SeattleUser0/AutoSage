# AutoSage Frontend Workbench

This frontend connects to the AutoSage backend session APIs and streaming chat endpoint:

- `POST /v1/sessions`
- `GET /v1/sessions/{session_id}`
- `POST /v1/sessions/{session_id}/chat?stream=true`
- `GET /v1/sessions/{session_id}/assets/{asset_path...}`

## Run

```bash
python3 -m http.server 5173 --directory frontend
```

Open `http://127.0.0.1:5173` and keep AutoSageServer running on `http://127.0.0.1:8080`.

## Stream events

The UI reducer handles canonical event types:

- `text_delta`
- `tool_call_start`
- `tool_call_complete`
- `state_update`
- `error`
- `agent_done`

It also supports current backend aliases for compatibility:

- `message` -> `text_delta`
- `tool_planned` -> `tool_call_start`
- `state` -> `state_update`
- `done` -> `agent_done`
