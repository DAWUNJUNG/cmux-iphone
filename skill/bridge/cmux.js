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

import { execFileSync } from "node:child_process";
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

function cmux(args) {
  if (!CMUX_BIN) throw new Error("cmux binary not found");
  return execFileSync(CMUX_BIN, args, { encoding: "utf-8", timeout: 8000 });
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
  if (!CMUX_BIN || !cwd) return null;
  let tsv;
  try {
    tsv = cmux(["top", "--all", "--processes", "--format", "tsv"]);
  } catch {
    return null;
  }
  const needle = agent === "codex" ? "codex" : "claude";
  const target = norm(cwd);

  for (const row of tsv.split("\n")) {
    // TSV columns: cpu  mem  count  type  id  parent  name
    const cols = row.split("\t");
    if (cols[3] !== "process") continue;
    const name = (cols[6] || "").toLowerCase();
    const parent = cols[5] || "";
    if (!name.includes(needle)) continue;
    if (!parent.startsWith("surface:")) continue;
    const pid = cols[4];
    if (norm(processCwd(pid)) === target) return parent;
  }
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
