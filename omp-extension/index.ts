// tmux-claude-session-manager — omp extension
//
// Bridges the tmux plugin into omp's lifecycle hooks. It does NOT install a
// declarative config (omp has none for hooks); instead it is a JS/TS extension
// module that default-exports a factory, exactly like any other omp extension.
//
// What it does:
//   - on `session_start` (when omp itself runs inside tmux): installs the
//     plugin's tmux key bindings (`prefix`+`y`, `prefix`+`u`) by sourcing the
//     plugin entry. Idempotent — tmux rebinds.
//   - exposes two slash commands that open the plugin's tmux popups:
//       /claude-list    — open the agent picker
//       /claude-launch  — launch / re-attach a Claude session for the cwd
//
// Safety ("don't kill yourself session"):
//   Every popup is launched with a DETACHED spawn (`stdio: ignore`, unref'd) so
//   omp's event loop never blocks waiting on an interactive fzf popup. The
//   destructive side of the plugin (detach-client / kill {pid}) is guarded in
//   the bash layer. The extension records omp's own pane (from its reliable
//   $TMUX_PANE) into the tmux global @claude_omp_pane; list.sh refuses to detach
//   THAT session, and agents.sh never offers to kill it. The keybinding also
//   passes the opener pane id via tmux FORMAT EXPANSION (`#{pane_id}`) into the
//   picker as OMP_HOST_PANE so agents.sh skips the pane you navigated from too.
//   A spawn failure (e.g. tmux missing) is swallowed via an 'error' listener so
//   the in-process extension host never crashes. Nothing targets the running
//   session on session_shutdown — there is no cleanup to do, and adding one
//   would only introduce a self-harm vector.
//
// Install:
//   Copy this `omp-extension/` dir into ~/.omp/agent/extensions/claude-session-manager/
//   (or add the repo's `omp-extension` path to `extensions:` in
//   ~/.omp/agent/config.yml) and restart omp. Or load once:
//   `omp --extension /path/to/omp-extension`.

import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as path from "node:path";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";

// Resolve the plugin repo root. The extension is loaded from different layouts,
// so we locate the plugin entry rather than assuming scripts/ lives one level
// up:
//   - in-repo:  <plugin>/omp-extension/index.ts  (scripts/ at <plugin>)
//   - bare copy of just omp-extension/ under the omp extensions dir (no sibling
//     plugin files at all)
//   - full-repo copy installed under the omp extensions dir
// A naive `path.resolve(HERE, "..")` only works for the in-repo shape; for the
// others every run-shell the extension fires points at a nonexistent file and is
// silently swallowed by tmuxDetached, so the key bindings never install.
// Resolution order:
//   1. CLAUDE_SESSION_MANAGER_DIR (explicit override) if it holds the entry.
//   2. Walk up from HERE (5 levels) for the plugin entry.
//   3. The tpm install at ~/.tmux/plugins/tmux-claude-session-manager.
//   4. path.resolve(HERE, "..") — legacy fallback.
let HERE: string;
try {
  HERE = path.dirname(fileURLToPath(import.meta.url));
} catch {
  HERE = __dirname;
}

const PLUGIN_ENTRY = "claude_session_manager.tmux";

function resolvePluginDir(): string {
  const candidates: string[] = [];
  const envDir = process.env.CLAUDE_SESSION_MANAGER_DIR;
  if (envDir) candidates.push(envDir);
  let dir = HERE;
  for (let i = 0; i < 5 && dir !== path.dirname(dir); i++) {
    candidates.push(dir);
    dir = path.dirname(dir);
  }
  candidates.push(path.join(homedir(), ".tmux", "plugins", "tmux-claude-session-manager"));
  candidates.push(path.resolve(HERE, ".."));
  for (const c of candidates) {
    try {
      if (existsSync(path.join(c, PLUGIN_ENTRY))) return c;
    } catch {
      /* ignore unstatable candidate */
    }
  }
  return path.resolve(HERE, "..");
}
const PLUGIN_DIR = resolvePluginDir();

const inTmux = (): boolean => !!process.env.TMUX;

// Fire-and-forget tmux invocation. Interactive popups (fzf via display-popup)
// must NOT block omp's event loop, so we spawn detached + unref: omp never
// waits for the popup to close. A missing or rejected tmux is ignored.
function tmuxDetached(args: string[]): void {
  try {
    const child = spawn("tmux", args, { stdio: "ignore", detached: true });
    // A missing/rejected tmux emits 'error' asynchronously. Without a listener
    // that becomes an uncaught exception in the in-process extension host and
    // can tear down omp's session. Swallow it — popups are best-effort.
    child.on("error", () => {});
    child.unref();
  } catch {
    /* best-effort: tmux absent or invocation rejected */
  }
}
export default function claudeSessionManager(pi: ExtensionAPI): void {
  pi.setLabel("tmux-claude-session-manager");

  const REGISTRY_DIR = path.join(homedir(), ".omp", "agent", "claude-session-manager");
  const REGISTRY_FILE = path.join(REGISTRY_DIR, "registry.json");

  // Atomically commit a registry entry. Filters dead PIDs on read so stale
  // entries don't accumulate across omp launches that crash without shutdown.
  function registryAdd(entry: Record<string, unknown>): void {
    try {
      mkdirSync(REGISTRY_DIR, { recursive: true });
      let entries: unknown[] = [];
      if (existsSync(REGISTRY_FILE)) {
        try { entries = JSON.parse(readFileSync(REGISTRY_FILE, "utf-8")); } catch { /* corrupt */ }
      }
      // Drop dead PIDs (process exited without shutdown cleanup).
      if (Array.isArray(entries)) {
        const alive: unknown[] = [];
        for (const e of entries) {
          if (e && typeof e === "object" && "pid" in e) {
            const pid = (e as Record<string, unknown>).pid;
            if (typeof pid === "number") {
              try { process.kill(pid, 0); alive.push(e); } catch { /* dead, skip */ }
              continue;
            }
          }
          alive.push(e);
        }
        entries = alive;
      }
      entries.push(entry);
      // Compact write — atomic-ish on most filesystems.
      const tmp = REGISTRY_FILE + ".tmp";
      writeFileSync(tmp, JSON.stringify(entries) + "\n");
      renameSync(tmp, REGISTRY_FILE);
    } catch { /* best-effort; never crash the extension host */ }
  }

  // Update the status field for the current session's registry entry.
  // Only touches the entry with our PID; leaves other entries intact.
  function registryUpdateStatus(status: string): void {
    try {
      if (!existsSync(REGISTRY_FILE)) return;
      let entries: unknown[];
      try { entries = JSON.parse(readFileSync(REGISTRY_FILE, "utf-8")); } catch { return; }
      if (!Array.isArray(entries)) return;
      const myPid = process.pid;
      let found = false;
      for (const e of entries) {
        if (e && typeof e === "object" && (e as Record<string, unknown>).pid === myPid) {
          (e as Record<string, unknown>).status = status;
          found = true;
          break;
        }
      }
      if (!found) return;
      const tmp = REGISTRY_FILE + ".tmp";
      writeFileSync(tmp, JSON.stringify(entries) + "\n");
      renameSync(tmp, REGISTRY_FILE);
    } catch { /* best-effort; never crash the extension host */ }
  }

  // Install key bindings and record the session when omp starts inside tmux.
  pi.on("session_start", () => {
    if (!inTmux()) return;
    // Record the pane omp itself lives in. omp's own $TMUX_PANE is reliable here
    // (omp runs inside a tmux pane); downstream run-shell / popup subprocesses
    // lose it, so we persist it as a tmux global the bash layer reads back.
    const ompPane = process.env.TMUX_PANE || "";
    if (ompPane) tmuxDetached(["set-option", "-g", "@claude_omp_pane", ompPane]);
    tmuxDetached(["run-shell", path.join(PLUGIN_DIR, "claude_session_manager.tmux")]);

    // Register this session so agents.sh can list it. sessionId is derived at
    // read time by agents.sh from the cwd (scanning the session storage dir), so
    // we only store the fields that are available synchronously here.
    registryAdd({
      pid: process.pid,
      cwd: process.cwd(),
      pane: ompPane,
      status: "busy",
    });
  });

  // Track agent state transitions for live status in the picker.
  // agent_start → busy (working), agent_end → idle (done).
  pi.on("agent_start", () => registryUpdateStatus("busy"));
  pi.on("agent_end", () => registryUpdateStatus("idle"));

  // When the agent calls ask, it's waiting for user input.
  pi.on("tool_call", (event: { toolName: string }) => {
    if (event.toolName === "ask") registryUpdateStatus("waiting");
  });
  // When the ask resolves, the agent resumes processing.
  pi.on("tool_result", (event: { toolName: string }) => {
    if (event.toolName === "ask") registryUpdateStatus("busy");
  });

  // /claude-list — open the agent picker popup.
  pi.registerCommand("claude-list", {
    description: "Open the tmux Claude agent picker",
    handler: async (_args, ctx) => {
      if (!inTmux()) {
        if (ctx && ctx.hasUI) ctx.ui.notify("Not inside tmux — picker unavailable", "info");
        return;
      }
      tmuxDetached([
        "run-shell",
        `${path.join(PLUGIN_DIR, "scripts", "list.sh")} '#{q:client_name}' '#{pane_id}'`,
      ]);
    },
  });

  // /claude-launch — launch or re-attach a Claude session for the current dir.
  pi.registerCommand("claude-launch", {
    description: "Launch or re-attach a Claude session for the current directory",
    handler: async (_args, ctx) => {
      if (!inTmux()) {
        if (ctx && ctx.hasUI) ctx.ui.notify("Not inside tmux — launch unavailable", "info");
        return;
      }
      tmuxDetached([
        "run-shell",
        `${path.join(PLUGIN_DIR, "scripts", "launch.sh")} '#{q:pane_current_path}' '#{q:window_id}'`,
      ]);
    },
  });
}
