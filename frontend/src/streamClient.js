function parseSSEEventBlock(block) {
  let eventName = "message";
  const dataLines = [];

  for (const rawLine of block.split("\n")) {
    const line = rawLine.trimEnd();
    if (!line || line.startsWith(":")) {
      continue;
    }
    if (line.startsWith("event:")) {
      eventName = line.slice("event:".length).trim();
      continue;
    }
    if (line.startsWith("data:")) {
      dataLines.push(line.slice("data:".length).trim());
    }
  }

  const dataText = dataLines.join("\n").trim();
  let payload = {};
  if (dataText) {
    try {
      payload = JSON.parse(dataText);
    } catch {
      payload = { raw: dataText };
    }
  }

  return { event: eventName, payload };
}

export function normalizeServerEvent(eventName, payload) {
  const name = (eventName || "").toLowerCase();
  const data = payload && typeof payload === "object" ? payload : {};

  if (name === "text_delta") {
    return { type: "TEXT_DELTA", delta: String(data.delta ?? data.text ?? data.content ?? "") };
  }
  if (name === "message") {
    return { type: "TEXT_DELTA", delta: String(data.content ?? data.text ?? "") };
  }
  if (name === "tool_call_start" || name === "tool_planned") {
    return { type: "TOOL_CALL_START", toolName: String(data.tool_name ?? data.name ?? "") };
  }
  if (name === "tool_call_complete") {
    return {
      type: "TOOL_CALL_COMPLETE",
      durationMS: typeof data.duration_ms === "number" ? data.duration_ms : undefined,
    };
  }
  if (name === "state_update" || name === "state") {
    return {
      type: "STATE_UPDATE",
      manifest: data.state && typeof data.state === "object" ? data.state : data,
    };
  }
  if (name === "error") {
    return {
      type: "STREAM_ERROR",
      code: String(data.code ?? "stream_error"),
      message: String(data.message ?? "Unknown error"),
    };
  }
  if (name === "agent_done" || name === "done") {
    return { type: "AGENT_DONE" };
  }

  return null;
}

function parseEventStreamChunk(buffer, onRawEvent) {
  let workingBuffer = buffer;
  while (true) {
    const separatorIndex = workingBuffer.indexOf("\n\n");
    if (separatorIndex < 0) {
      break;
    }

    const block = workingBuffer.slice(0, separatorIndex);
    workingBuffer = workingBuffer.slice(separatorIndex + 2);

    if (!block.trim()) {
      continue;
    }

    onRawEvent(parseSSEEventBlock(block));
  }

  return workingBuffer;
}

function mapHTTPErrorCode(status) {
  if (status === 404) {
    return "ERR_SESSION_NOT_FOUND";
  }
  if (status >= 500) {
    return "ERR_BACKEND_UNAVAILABLE";
  }
  return "ERR_STREAM_REJECTED";
}

export async function streamSessionChat({ apiBase, sessionId, prompt, onEvent, signal }) {
  const url = `${apiBase.replace(/\/$/, "")}/v1/sessions/${encodeURIComponent(sessionId)}/chat?stream=true`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "text/event-stream",
    },
    body: JSON.stringify({ prompt, stream: true }),
    signal,
  });

  if (!response.ok) {
    let message = `Stream request failed with HTTP ${response.status}`;
    try {
      const details = await response.json();
      if (details?.error?.message) {
        message = String(details.error.message);
      }
    } catch {
      // Keep fallback message.
    }
    const error = new Error(message);
    error.code = mapHTTPErrorCode(response.status);
    throw error;
  }

  if (!response.body) {
    const error = new Error("Backend did not provide a response stream");
    error.code = "ERR_NO_STREAM";
    throw error;
  }

  const decoder = new TextDecoder("utf-8");
  const reader = response.body.getReader();
  let buffer = "";

  while (true) {
    const { value, done } = await reader.read();
    if (done) {
      break;
    }

    buffer += decoder.decode(value, { stream: true });
    buffer = parseEventStreamChunk(buffer, (rawEvent) => {
      const normalized = normalizeServerEvent(rawEvent.event, rawEvent.payload);
      if (normalized) {
        onEvent(normalized);
      }
    });
  }

  if (buffer.trim()) {
    const trailingEvent = parseSSEEventBlock(buffer);
    const normalized = normalizeServerEvent(trailingEvent.event, trailingEvent.payload);
    if (normalized) {
      onEvent(normalized);
    }
  }
}
