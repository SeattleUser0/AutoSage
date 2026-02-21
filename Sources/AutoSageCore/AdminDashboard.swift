import Foundation

enum AdminDashboard {
    static let html: String = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>AutoSage Admin</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f6f8;
      --panel: #ffffff;
      --text: #111827;
      --muted: #6b7280;
      --ok: #16a34a;
      --warn: #d97706;
      --err: #b91c1c;
      --line: #d1d5db;
    }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    .wrap {
      max-width: 980px;
      margin: 24px auto;
      padding: 0 16px;
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
      margin-bottom: 14px;
    }
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      flex-wrap: wrap;
    }
    .status {
      display: flex;
      align-items: center;
      gap: 8px;
      font-weight: 600;
    }
    .dot {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background: var(--warn);
      box-shadow: 0 0 0 2px rgba(0, 0, 0, 0.08);
    }
    button {
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #f9fafb;
      color: var(--text);
      font-size: 14px;
      padding: 8px 12px;
      cursor: pointer;
    }
    button:hover { background: #f3f4f6; }
    button:disabled { opacity: 0.6; cursor: not-allowed; }
    .result {
      margin-top: 10px;
      font-size: 13px;
      color: var(--muted);
      min-height: 18px;
    }
    .logs {
      height: 440px;
      overflow: auto;
      white-space: pre-wrap;
      background: #0b1020;
      color: #d1e6ff;
      border-radius: 6px;
      padding: 12px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      line-height: 1.4;
    }
    .meta {
      font-size: 12px;
      color: var(--muted);
      margin-top: 8px;
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="panel">
      <div class="header">
        <div class="status">
          <span class="dot" id="status-dot"></span>
          <span id="status-text">Checking server...</span>
        </div>
        <div>
          <button id="clear-jobs-btn">Clear Jobs</button>
        </div>
      </div>
      <div class="result" id="action-result"></div>
      <div class="meta">Endpoint: POST /v1/admin/clear-jobs</div>
    </div>
    <div class="panel">
      <div style="font-weight: 600; margin-bottom: 8px;">Admin Logs</div>
      <div class="logs" id="logs">Loading logs...</div>
      <div class="meta">Polling: GET /v1/admin/logs?limit=400</div>
    </div>
  </div>

  <script>
    const dot = document.getElementById("status-dot");
    const statusText = document.getElementById("status-text");
    const logsEl = document.getElementById("logs");
    const clearBtn = document.getElementById("clear-jobs-btn");
    const actionResult = document.getElementById("action-result");
    let lastLogPayload = "";

    function setStatus(ok, text) {
      dot.style.background = ok ? "var(--ok)" : "var(--err)";
      statusText.textContent = text;
    }

    async function refreshStatus() {
      try {
        const res = await fetch("/healthz", { cache: "no-store" });
        if (!res.ok) throw new Error("status " + res.status);
        const payload = await res.json();
        setStatus(true, "Running (" + (payload.version || "unknown") + ")");
      } catch (_) {
        setStatus(false, "Unavailable");
      }
    }

    async function refreshLogs() {
      try {
        const res = await fetch("/v1/admin/logs?limit=400", { cache: "no-store" });
        if (!res.ok) throw new Error("status " + res.status);
        const payload = await res.json();
        const text = (payload.lines || []).join("\\n");
        if (text !== lastLogPayload) {
          lastLogPayload = text;
          logsEl.textContent = text || "(no admin logs yet)";
          logsEl.scrollTop = logsEl.scrollHeight;
        }
      } catch (err) {
        logsEl.textContent = "Failed to load logs: " + err;
      }
    }

    async function clearJobs() {
      if (!confirm("Delete all session_* folders under the sessions root?")) {
        return;
      }
      clearBtn.disabled = true;
      actionResult.style.color = "var(--muted)";
      actionResult.textContent = "Clearing jobs...";
      try {
        const res = await fetch("/v1/admin/clear-jobs", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{}"
        });
        const payload = await res.json();
        if (!res.ok) {
          const msg = payload?.error?.message || ("HTTP " + res.status);
          throw new Error(msg);
        }
        actionResult.style.color = "var(--ok)";
        actionResult.textContent = payload.message || "Jobs cleared.";
        await refreshLogs();
      } catch (err) {
        actionResult.style.color = "var(--err)";
        actionResult.textContent = "Clear jobs failed: " + err;
      } finally {
        clearBtn.disabled = false;
      }
    }

    clearBtn.addEventListener("click", clearJobs);
    refreshStatus();
    refreshLogs();
    setInterval(refreshStatus, 5000);
    setInterval(refreshLogs, 2000);
  </script>
</body>
</html>
"""
}
