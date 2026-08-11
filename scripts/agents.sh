#!/usr/bin/env bash
# Emit one picker row per running omp agent that lives in a tmux pane.
#
# Reads the session registry maintained live by the omp extension — written at
# session_start with status "busy", then updated through lifecycle hooks
# (agent_end → idle, tool_call ask → waiting) so the picker always sees
# the current state.
# The session id is derived from cwd by finding the most recent JSONL in the omp
# session storage directory. That file's mtime is used for the age column — no
# transcript daemon needed.
#
# Identity is the tmux pane, not a nested worker. Registry pids are joined
# pid -> tty -> pane so several Claudes in one project (same cwd, different
# windows) each get a row; duplicate registry entries from subagent
# session_start are collapsed to one row per pane. The pid column is
# #{pane_pid} (main pane process) so ctrl-x kills the agent, not a subagent.
#
#   Row: rank \t pane_id \t pid \t kind \t icon \t age \t loc \t path
#   rank/pane_id/pid/kind are hidden from the display via fzf's --with-nth.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

REGISTRY="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/claude-session-manager/registry.json"
[ -f "$REGISTRY" ] || exit 0
rows="$(jq -r '.[] | [.pid, .status, .cwd] | @tsv' "$REGISTRY" 2>/dev/null)"
[ -n "$rows" ] || exit 0

# Derive sessionId from cwd: encode cwd -> session dir name, find newest JSONL.
rows="$(printf '%s\n' "$rows" | while IFS=$'\t' read pid status cwd; do
  enc="-${cwd#"$HOME/"}"
  enc="${enc//\//-}"
  session_dir="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/sessions/$enc"
  sid="unknown"
  if [ -d "$session_dir" ]; then
    newest="$(ls -t "$session_dir"/*.jsonl 2>/dev/null | head -1)"
    [ -n "$newest" ] && sid="$(basename "$newest" .jsonl)"
  fi
  printf '%s\t%s\t%s\t%s\n' "$pid" "$status" "$sid" "$cwd"
done)"

# Resolved out here because only `stat`, outside awk, can read an mtime.
mtimes="$(printf '%s\n' "$rows" | cut -f3 | while IFS= read -r sid; do
  printf 'M\t%s\t%s\n' "$sid" "$(omp_session_mtime "$sid")"
done)"

# Three tagged streams into one awk: pid->tty, tty->pane, session->last-activity.
# Total cost is 3 subprocesses regardless of how many sessions or panes exist.
#
# Subagent session_start hooks re-register under the same pane (often the same
# pid), which would otherwise multiply picker rows. Deduplicate by pane_id and
# always expose #{pane_pid} — the main process of that pane — never a nested
# worker/subagent pid from the registry. Status comes from the first matching
# registry entry for that pane (the one registryUpdateStatus mutates).
{
  ps -Ao pid=,tty= 2>/dev/null | awk '{ print "P\t" $1 "\t" $2 }'
  tmux list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}' 2>/dev/null
  printf '%s\n' "$mtimes"
  printf '%s\n' "$rows" | sed $'s/^/A\t/'
} | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
  -v self_pane="${OMP_HOST_PANE:-${TMUX_PANE:-}}" -v omp_pane="$(tmux show-options -gqv @claude_omp_pane 2>/dev/null)" '
  $1 == "P" { tty_of[$2] = $3; next }
  $1 == "T" { sub(/^\/dev\//, "", $2); pane[$2] = $3; sess[$2] = $4; loc[$2] = $5; pane_pid[$2] = $6; next }
  $1 == "M" { seen_at[$2] = $3; next }
  $1 == "A" {
    tty = tty_of[$2]
    if (tty == "" || !(tty in pane)) next   # this Claude is not running inside tmux
    pane_id = pane[tty]
    if (pane_id in listed) next             # already emitted this pane (skip subagent dupes)
    listed[pane_id] = 1

    is_host = 0
    if (self_pane != "" && pane_id == self_pane) is_host = 1
    if (omp_pane != "" && pane_id == omp_pane) is_host = 1

    if      ($3 == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }  # yellow - needs input
    else if ($3 == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }  # green  - done, your turn
    else if ($3 == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }  # red    - busy, leave it
    else                      { icon = "\033[90m●\033[0m   ?    "; rank = 2 }  # grey   - unrecognised status

    age = (seen_at[$4] != "") ? int((now - seen_at[$4]) / 60) "m" : "-"
    kind = (index(sess[tty], prefix) == 1) ? "dedicated" : "loose"
    if (is_host) kind = "host"
    if (is_host) rank = 4  # host entries sink to the bottom

    path = $5
    if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

    pid = (is_host) ? "-" : pane_pid[tty]
    printf "%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\n",
      rank, pane_id, pid, kind, icon, age, loc[tty], path
  }
' | sort -t$'\t' -k1,1n -k6,6n
# rank asc (what needs you floats up), then age asc so whatever just went idle
# sits at the top of its group. -k6,6n reads the leading number of the age field
# ("5m" -> 5; "-" -> 0).
