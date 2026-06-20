// cmux.js — inject prompts / approval keys into LIVE cmux agent surfaces.
//
// Why this exists:
//   The stock bridge, for an external (cmux-owned) session, falls back to a
//   DETACHED `claude -p ... --continue` run — a separate headless process, NOT
//   the interactive agent you are watching. With cmux we instead type straight
//   into the live Claude/Codex TUI surface, so a prompt sent from the phone
//   lands in the exact session on screen.
//
// Mapping strategy (no Claude/Codex change needed):
//   1. `cmux top --all --processes --format tsv` lists every surface and the
//      agent process running under it  ->  (pid, surface-ref, name).
//   2. `lsof -a -p <pid> -d cwd` gives that process's working directory.
//   3. Match the bridge session's cwd (from hooks) to find the surface ref.
//   4. `cmux send --surface <ref> -- "<text>"` + `cmux send-key <ref> enter`.
//
// All cmux/lsof calls use execFileSync (no shell) so prompt text can never be
// shell-injected. Every function is best-effort: on any failure it throws and
// the caller falls back to the original detached behaviour.

import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";

function findCmuxBin() {
  const envBin = process.env.CMUX_BIN;
  if (envBin) {
    try { fs.accessSync(envBin, fs.constants.X_OK); return envBin; } catch { /* ignore */ }
  }
  const candidates = [
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
    "/Applications/cmux 2.app/Contents/Resources/bin/cmux",
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* continue */ }
  }
  try {
    const which = execFileSync("/usr/bin/which", ["cmux"], { encoding: "utf-8" }).trim();
    if (which) return which;
  } catch { /* fall through */ }
  return null;
}

const CMUX_BIN = findCmuxBin();
const LSOF_BIN = "/usr/sbin/lsof";

// Socket password (cmux socketControlMode=password). Lets the launchd bridge —
// which runs OUTSIDE cmux — authenticate to the cmux control socket.
const CMUX_PASSWORD = (() => {
  try {
    return fs.readFileSync(`${process.env.HOME}/.config/claude-watch/cmux-password`, "utf-8").trim() || null;
  } catch { return null; }
})();

function withAuth(args) {
  return CMUX_PASSWORD ? ["--password", CMUX_PASSWORD, ...args] : args;
}

function cmux(args) {
  if (!CMUX_BIN) throw new Error("cmux binary not found");
  return execFileSync(CMUX_BIN, withAuth(args), { encoding: "utf-8", timeout: 8000 });
}

export function cmuxAvailable() {
  return CMUX_BIN !== null;
}

function processCwd(pid) {
  try {
    const out = execFileSync(LSOF_BIN, ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], {
      encoding: "utf-8",
      timeout: 5000,
    });
    const line = out.split("\n").find((l) => l.startsWith("n"));
    return line ? line.slice(1) : null;
  } catch {
    return null;
  }
}

const norm = (p) => (typeof p === "string" ? p.replace(/\/+$/, "") : p);

// Resolve a session's cwd + agent to a cmux surface ref (e.g. "surface:16").
// Returns null if cmux is unavailable or no matching live surface is found.
export function resolveSurface(cwd, agent = "claude") {
  if (!CMUX_BIN) return null;
  let tsv;
  try {
    tsv = cmux(["top", "--all", "--processes", "--format", "tsv"]);
  } catch {
    return null;
  }
  const needle = agent === "codex" ? "codex" : "claude";
  const target = norm(cwd);

  // Collect one entry per live surface running this agent, with its cwd.
  const candidates = [];
  const seen = new Set();
  for (const row of tsv.split("\n")) {
    // TSV columns: cpu  mem  count  type  id  parent  name
    const cols = row.split("\t");
    if (cols[3] !== "process") continue;
    const name = (cols[6] || "").toLowerCase();
    const parent = cols[5] || "";
    if (!name.includes(needle)) continue;
    if (!parent.startsWith("surface:")) continue;
    if (seen.has(parent)) continue; // one entry per surface
    seen.add(parent);
    candidates.push({ surface: parent, cwd: norm(processCwd(cols[4])) });
  }

  if (candidates.length === 0) return null;

  // 1) Exact cwd match — most precise.
  if (target) {
    const exact = candidates.find((c) => c.cwd === target);
    if (exact) return exact.surface;

    // 2) Path-relationship match — the session's cwd is a sub/parent directory
    //    of a pane's cwd (hooks sometimes report a subdir of the launch dir).
    const rel = candidates.find(
      (c) => c.cwd && (target.startsWith(c.cwd + "/") || c.cwd.startsWith(target + "/"))
    );
    if (rel) return rel.surface;
  }

  // 3) Exactly one live pane for this agent — unambiguous, use it even if the
  //    cwd didn't line up (common: a single Claude/Codex pane on screen).
  if (candidates.length === 1) return candidates[0].surface;

  return null;
}

// Type a prompt into a surface and submit it (text, then Enter).
export function sendPrompt(surface, text) {
  const body = String(text).replace(/[\r\n]+$/, "");
  cmux(["send", "--surface", surface, "--", body]);
  cmux(["send-key", "--surface", surface, "enter"]);
}

// Send raw characters (no Enter) — used for single-key TUI answers like "y".
export function sendChars(surface, chars) {
  cmux(["send", "--surface", surface, "--", String(chars)]);
}

// Send a named key event — e.g. "enter", "escape", "ctrl+c".
export function sendKey(surface, key) {
  cmux(["send-key", "--surface", surface, key]);
}

// ---------------------------------------------------------------------------
// Mobile mirror API (cmux rpc) — drives the phone's live cmux view.
// ---------------------------------------------------------------------------

function rpc(method, params) {
  if (!CMUX_BIN) throw new Error("cmux binary not found");
  const args = ["rpc", method];
  if (params !== undefined) args.push(JSON.stringify(params));
  const out = execFileSync(CMUX_BIN, withAuth(args), { encoding: "utf-8", timeout: 8000 });
  return out && out.trim() ? JSON.parse(out) : null;
}

// Full workspace → terminal tree for the mobile mirror.
// Returns the raw mobile.workspace.list payload (workspaces[].terminals[]).
export function mobileWorkspaces() {
  if (!CMUX_BIN) return null;
  try {
    return rpc("mobile.workspace.list");
  } catch {
    return null;
  }
}

// Plain-text rendering of a terminal/surface (accepts a UUID or surface ref).
export function readTerminalText(id) {
  if (!CMUX_BIN || !id) return null;
  try {
    const r = rpc("surface.read_text", { surface: id });
    return r && typeof r.text === "string" ? r.text : null;
  } catch {
    return null;
  }
}

// Send text to a terminal by id, then submit with Enter (so prompts from the
// phone land in the live agent surface exactly as if typed).
export function sendInput(terminalId, text, submit = true) {
  if (!CMUX_BIN || !terminalId) throw new Error("missing terminal id");
  rpc("mobile.terminal.input", { terminal_id: terminalId, text: String(text) });
  if (submit) {
    try {
      cmux(["send-key", "--surface", terminalId, "enter"]);
    } catch {
      rpc("mobile.terminal.input", { terminal_id: terminalId, text: "\r" });
    }
  }
}

// Stream cmux events (newline-delimited JSON). Calls onEvent(obj) per frame.
// Auto-reconnects (cmux --reconnect); the caller should respawn if the child
// exits (e.g. before the socket is reachable). Returns the child process.
export function streamEvents(onEvent) {
  if (!CMUX_BIN) return null;
  const child = spawn(CMUX_BIN, withAuth(["events", "--reconnect", "--no-heartbeat", "--no-ack"]), {
    stdio: ["ignore", "pipe", "ignore"],
  });
  let buf = "";
  child.stdout.on("data", (d) => {
    buf += d.toString();
    let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line) continue;
      try { onEvent(JSON.parse(line)); } catch { /* ignore non-JSON */ }
    }
  });
  return child;
}
