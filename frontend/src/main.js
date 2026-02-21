import { createStore, initialState, reducer } from "./state.js";
import { streamSessionChat } from "./streamClient.js";
import {
  GeometryViewport,
  findBestRenderableAsset,
  flattenManifestAssets,
  isImageAsset,
} from "./viewport.js";

const elements = {
  apiBaseInput: document.querySelector("#api-base"),
  uploadForm: document.querySelector("#upload-form"),
  uploadInput: document.querySelector("#upload-input"),
  sessionInput: document.querySelector("#session-id"),
  loadSessionButton: document.querySelector("#load-session"),
  chatForm: document.querySelector("#chat-form"),
  chatInput: document.querySelector("#chat-input"),
  sendButton: document.querySelector("#send-button"),
  messages: document.querySelector("#message-feed"),
  activity: document.querySelector("#activity"),
  errorBanner: document.querySelector("#error-banner"),
  manifestSummary: document.querySelector("#manifest-summary"),
  assetList: document.querySelector("#asset-list"),
  metadataList: document.querySelector("#metadata-list"),
  manifestRaw: document.querySelector("#manifest-raw"),
  renderGallery: document.querySelector("#render-gallery"),
  viewportHost: document.querySelector("#viewport-host"),
};

const store = createStore(reducer, initialState);
const viewport = new GeometryViewport(elements.viewportHost);

let activeStreamAbort = null;
let currentViewportAssetPath = null;

function encodeAssetPath(path) {
  return path
    .split("/")
    .filter((segment) => segment.length > 0)
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}

function assetURL(state, assetPath) {
  const base = state.apiBase.replace(/\/$/, "");
  const sessionPart = encodeURIComponent(state.sessionId);
  return `${base}/v1/sessions/${sessionPart}/assets/${encodeAssetPath(assetPath)}`;
}

function applyManifest(manifest, sessionID) {
  const normalizedSession = typeof sessionID === "string" && sessionID ? sessionID : "";
  store.dispatch({ type: "SET_SESSION", sessionId: normalizedSession, manifest });

  const chat = Array.isArray(manifest?.messages)
    ? manifest.messages.map((item) => ({
        id: `${item.created_at || item.createdAt || Date.now()}_${Math.random().toString(36).slice(2)}`,
        role: item.role || "assistant",
        content: String(item.content || ""),
        streaming: false,
        createdAt: item.created_at || item.createdAt || new Date().toISOString(),
      }))
    : [];

  store.dispatch({ type: "SET_CHAT_HISTORY", chat });
}

function renderMessageFeed(state) {
  elements.messages.innerHTML = "";
  for (const message of state.chat) {
    const item = document.createElement("article");
    item.className = `message message-${message.role}`;

    const header = document.createElement("header");
    header.textContent = message.role === "user" ? "User" : "Agent";

    const content = document.createElement("pre");
    content.textContent = message.content || "";

    item.append(header, content);
    elements.messages.appendChild(item);
  }
  elements.messages.scrollTop = elements.messages.scrollHeight;
}

function renderActivity(state) {
  elements.activity.innerHTML = "";

  if (state.activeTool) {
    const spinner = document.createElement("span");
    spinner.className = "spinner";

    const label = document.createElement("span");
    label.className = "activity-label";
    label.textContent = `Running ${state.activeTool.name}...`;

    const row = document.createElement("div");
    row.className = "activity-row active";
    row.append(spinner, label);
    elements.activity.appendChild(row);
    return;
  }

  if (state.completedTools.length > 0) {
    const completed = state.completedTools[0];
    const row = document.createElement("div");
    row.className = "activity-row complete";
    row.textContent = `✓ ${completed.name} completed in ${completed.durationMS} ms`;
    elements.activity.appendChild(row);
    return;
  }

  const idle = document.createElement("div");
  idle.className = "activity-row idle";
  idle.textContent = state.streamActive ? "Waiting for events..." : "Idle";
  elements.activity.appendChild(idle);
}

function renderError(state) {
  if (!state.error) {
    elements.errorBanner.hidden = true;
    elements.errorBanner.textContent = "";
    return;
  }
  elements.errorBanner.hidden = false;
  elements.errorBanner.textContent = `${state.error.code}: ${state.error.message}`;
}

function assetType(path) {
  const lower = path.toLowerCase();
  if (lower.endsWith(".glb") || lower.endsWith(".gltf") || lower.endsWith(".obj") || lower.endsWith(".stl")) {
    return "3d";
  }
  if (lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg")) {
    return "image";
  }
  return "file";
}

function renderManifestAndAssets(state) {
  const manifest = state.manifest;

  elements.manifestSummary.innerHTML = "";
  elements.assetList.innerHTML = "";
  elements.metadataList.innerHTML = "";
  elements.renderGallery.innerHTML = "";

  if (!manifest || typeof manifest !== "object") {
    elements.manifestRaw.textContent = "No manifest loaded";
    return;
  }

  const summaryItems = [
    ["session_id", manifest.session_id || manifest.sessionID || state.sessionId || ""],
    ["status", manifest.status || ""],
    ["stage", manifest.stage || ""],
    ["planned_tool", manifest.planned_tool || manifest.plannedTool || ""],
    ["updated_at", manifest.updated_at || manifest.updatedAt || ""],
  ];

  for (const [label, value] of summaryItems) {
    const dt = document.createElement("dt");
    dt.textContent = label;
    const dd = document.createElement("dd");
    dd.textContent = String(value || "-");
    elements.manifestSummary.append(dt, dd);
  }

  const assets = flattenManifestAssets(manifest);
  for (const path of assets) {
    const row = document.createElement("li");

    const link = document.createElement("a");
    link.href = assetURL(state, path);
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = path;

    const badge = document.createElement("span");
    badge.className = "asset-badge";
    badge.textContent = assetType(path);

    row.append(link, badge);
    elements.assetList.appendChild(row);
  }

  const metadataEntries = Object.entries(state.metadata || {});
  for (const [key, value] of metadataEntries) {
    const row = document.createElement("li");
    row.textContent = `${key}: ${typeof value === "string" ? value : JSON.stringify(value)}`;
    elements.metadataList.appendChild(row);
  }

  const imageAssets = assets.filter(isImageAsset);
  for (const imagePath of imageAssets) {
    const figure = document.createElement("figure");
    const img = document.createElement("img");
    img.src = assetURL(state, imagePath);
    img.alt = imagePath;
    img.loading = "lazy";

    const caption = document.createElement("figcaption");
    caption.textContent = imagePath;

    figure.append(img, caption);
    elements.renderGallery.appendChild(figure);
  }

  elements.manifestRaw.textContent = JSON.stringify(manifest, null, 2);

  const renderableAsset = findBestRenderableAsset(manifest);
  if (renderableAsset && renderableAsset !== currentViewportAssetPath && state.sessionId) {
    currentViewportAssetPath = renderableAsset;
    viewport.loadAsset(assetURL(state, renderableAsset), renderableAsset);
  }
}

function renderControls(state) {
  elements.sendButton.disabled = state.streamActive || !state.sessionId;
  elements.chatInput.disabled = state.streamActive || !state.sessionId;
  elements.uploadInput.disabled = state.streamActive;
  elements.loadSessionButton.disabled = state.streamActive;
}

function render(state) {
  if (document.activeElement !== elements.apiBaseInput) {
    elements.apiBaseInput.value = state.apiBase;
  }
  if (document.activeElement !== elements.sessionInput) {
    elements.sessionInput.value = state.sessionId;
  }

  renderControls(state);
  renderMessageFeed(state);
  renderActivity(state);
  renderError(state);
  renderManifestAndAssets(state);
}

store.subscribe((state) => render(state));
render(store.getState());

async function parseAPIError(response, fallbackCode = "ERR_REQUEST_FAILED") {
  let code = fallbackCode;
  let message = `Request failed with HTTP ${response.status}`;
  try {
    const body = await response.json();
    if (body?.error?.code) {
      code = String(body.error.code);
    }
    if (body?.error?.message) {
      message = String(body.error.message);
    }
  } catch {
    // keep fallback values
  }
  return { code, message };
}

async function createSessionFromUpload(file) {
  const state = store.getState();
  const url = `${state.apiBase.replace(/\/$/, "")}/v1/sessions`;

  const form = new FormData();
  form.append("file", file, file.name);

  const response = await fetch(url, { method: "POST", body: form });
  if (!response.ok) {
    throw await parseAPIError(response, "ERR_SESSION_CREATE_FAILED");
  }

  const payload = await response.json();
  const sessionId = payload.session_id || payload.sessionID;
  const manifest = payload.state || null;
  return { sessionId, manifest };
}

async function loadSession(sessionID) {
  const state = store.getState();
  const url = `${state.apiBase.replace(/\/$/, "")}/v1/sessions/${encodeURIComponent(sessionID)}`;

  const response = await fetch(url);
  if (!response.ok) {
    throw await parseAPIError(response, "ERR_SESSION_LOAD_FAILED");
  }

  return response.json();
}

async function handleSendPrompt(prompt) {
  const state = store.getState();
  if (!state.sessionId) {
    store.dispatch({
      type: "STREAM_ERROR",
      code: "ERR_SESSION_REQUIRED",
      message: "Create or load a session before sending chat prompts.",
    });
    return;
  }

  if (activeStreamAbort) {
    return;
  }

  store.dispatch({ type: "APPEND_USER_MESSAGE", prompt });
  store.dispatch({ type: "STREAM_STARTED" });

  const controller = new AbortController();
  activeStreamAbort = controller;

  try {
    await streamSessionChat({
      apiBase: state.apiBase,
      sessionId: state.sessionId,
      prompt,
      signal: controller.signal,
      onEvent: (event) => {
        store.dispatch(event);
      },
    });

    if (store.getState().streamActive) {
      store.dispatch({ type: "AGENT_DONE" });
    }
  } catch (error) {
    if (error.name !== "AbortError") {
      store.dispatch({
        type: "STREAM_ERROR",
        code: error.code || "ERR_STREAM_FAILED",
        message: error.message || "Streaming request failed",
      });
    }
  } finally {
    activeStreamAbort = null;
  }
}

elements.apiBaseInput.addEventListener("change", (event) => {
  store.dispatch({ type: "SET_API_BASE", apiBase: event.target.value.trim() });
});

elements.uploadForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const file = elements.uploadInput.files?.[0];
  if (!file) {
    store.dispatch({
      type: "STREAM_ERROR",
      code: "ERR_FILE_REQUIRED",
      message: "Choose an input file (.step or .json) before creating a session.",
    });
    return;
  }

  try {
    const { sessionId, manifest } = await createSessionFromUpload(file);
    applyManifest(manifest, sessionId);
  } catch (error) {
    store.dispatch({
      type: "STREAM_ERROR",
      code: error.code || "ERR_SESSION_CREATE_FAILED",
      message: error.message || "Failed to create session",
    });
  }
});

elements.loadSessionButton.addEventListener("click", async () => {
  const sessionID = elements.sessionInput.value.trim();
  if (!sessionID) {
    return;
  }

  try {
    const manifest = await loadSession(sessionID);
    applyManifest(manifest, sessionID);
  } catch (error) {
    store.dispatch({
      type: "STREAM_ERROR",
      code: error.code || "ERR_SESSION_LOAD_FAILED",
      message: error.message || "Failed to load session",
    });
  }
});

elements.chatForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const prompt = elements.chatInput.value.trim();
  if (!prompt) {
    return;
  }
  elements.chatInput.value = "";
  await handleSendPrompt(prompt);
});

window.addEventListener("beforeunload", () => {
  if (activeStreamAbort) {
    activeStreamAbort.abort();
  }
  viewport.dispose();
});
