const MAX_TEXT_LENGTH = 10000;

export const initialState = {
  apiBase: "http://127.0.0.1:8080",
  sessionId: "",
  manifest: null,
  metadata: {},
  chat: [],
  activeTool: null,
  completedTools: [],
  streamActive: false,
  error: null,
};

function nextID() {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `id_${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
}

function truncateText(text) {
  if (typeof text !== "string") {
    return "";
  }
  if (text.length <= MAX_TEXT_LENGTH) {
    return text;
  }
  return text.slice(0, MAX_TEXT_LENGTH) + "…";
}

function appendAssistantDelta(chat, delta) {
  if (!delta) {
    return chat;
  }

  const next = [...chat];
  const last = next[next.length - 1];
  if (last && last.role === "assistant" && last.streaming === true) {
    next[next.length - 1] = {
      ...last,
      content: truncateText(last.content + delta),
    };
    return next;
  }

  next.push({
    id: nextID(),
    role: "assistant",
    content: truncateText(delta),
    streaming: true,
    createdAt: new Date().toISOString(),
  });
  return next;
}

function finishAssistantStreaming(chat) {
  return chat.map((entry) => {
    if (entry.role === "assistant" && entry.streaming === true) {
      return { ...entry, streaming: false };
    }
    return entry;
  });
}

function extractMetadata(manifest) {
  if (!manifest || typeof manifest !== "object") {
    return {};
  }
  const metadata = manifest.metadata;
  if (metadata && typeof metadata === "object" && !Array.isArray(metadata)) {
    return metadata;
  }
  return {};
}

export function reducer(state, action) {
  switch (action.type) {
    case "SET_API_BASE": {
      return { ...state, apiBase: action.apiBase || state.apiBase };
    }
    case "SET_SESSION": {
      const nextSessionID = action.sessionId || "";
      const changedSession = nextSessionID && nextSessionID !== state.sessionId;
      return {
        ...state,
        sessionId: nextSessionID,
        manifest: action.manifest ?? state.manifest,
        metadata: extractMetadata(action.manifest ?? state.manifest),
        activeTool: changedSession ? null : state.activeTool,
        completedTools: changedSession ? [] : state.completedTools,
        error: null,
      };
    }
    case "SET_MANIFEST": {
      return {
        ...state,
        manifest: action.manifest,
        metadata: extractMetadata(action.manifest),
      };
    }
    case "SET_CHAT_HISTORY": {
      return {
        ...state,
        chat: Array.isArray(action.chat) ? action.chat.slice(0, 500) : state.chat,
      };
    }
    case "APPEND_USER_MESSAGE": {
      const prompt = truncateText(action.prompt || "");
      if (!prompt) {
        return state;
      }
      return {
        ...state,
        chat: [
          ...finishAssistantStreaming(state.chat),
          {
            id: nextID(),
            role: "user",
            content: prompt,
            createdAt: new Date().toISOString(),
          },
        ],
        error: null,
      };
    }
    case "TEXT_DELTA": {
      return {
        ...state,
        chat: appendAssistantDelta(state.chat, action.delta || ""),
      };
    }
    case "STREAM_STARTED": {
      return {
        ...state,
        streamActive: true,
        error: null,
        chat: finishAssistantStreaming(state.chat),
      };
    }
    case "TOOL_CALL_START": {
      const toolName = action.toolName || "unknown_tool";
      return {
        ...state,
        activeTool: {
          name: toolName,
          startedAt: Date.now(),
        },
      };
    }
    case "TOOL_CALL_COMPLETE": {
      if (!state.activeTool) {
        return state;
      }
      const durationMS =
        typeof action.durationMS === "number"
          ? action.durationMS
          : Date.now() - state.activeTool.startedAt;

      const completed = {
        name: state.activeTool.name,
        durationMS,
        finishedAt: Date.now(),
      };

      return {
        ...state,
        activeTool: null,
        completedTools: [completed, ...state.completedTools].slice(0, 12),
      };
    }
    case "STATE_UPDATE": {
      return {
        ...state,
        manifest: action.manifest,
        metadata: extractMetadata(action.manifest),
      };
    }
    case "STREAM_ERROR": {
      return {
        ...state,
        streamActive: false,
        activeTool: null,
        error: {
          code: action.code || "unknown_error",
          message: action.message || "Unknown stream error",
        },
        chat: finishAssistantStreaming(state.chat),
      };
    }
    case "AGENT_DONE": {
      let nextState = {
        ...state,
        streamActive: false,
        chat: finishAssistantStreaming(state.chat),
      };

      if (state.activeTool) {
        nextState = reducer(nextState, {
          type: "TOOL_CALL_COMPLETE",
          durationMS: Date.now() - state.activeTool.startedAt,
        });
      }
      return nextState;
    }
    default:
      return state;
  }
}

export function createStore(reducerFn, preloadedState) {
  let state = preloadedState;
  const listeners = new Set();

  return {
    getState() {
      return state;
    },
    dispatch(action) {
      state = reducerFn(state, action);
      for (const listener of listeners) {
        listener(state, action);
      }
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}
