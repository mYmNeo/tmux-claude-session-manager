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
# pid -> tty -> pane so several agents in one project (same cwd, different
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

OMP_DIR="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
REGISTRY="$OMP_DIR/claude-session-manager/registry.json"

# registry_recs
# One rec per registry entry. The session id and last-activity time come from
# the newest JSONL in the cwd's session bucket; an empty seen-at renders as '-'.
#
#   Rec: pid \t status \t session-id \t cwd \t seen-at
registry_recs() {
  [ -f "$REGISTRY" ] || return 1
  jq -r '.[] | [.pid, .status, .cwd] | @tsv' "$REGISTRY" 2>/dev/null |
    while IFS=$'\t' read -r pid status cwd; do
      enc="-${cwd#"$HOME/"}"
      enc="${enc//\//-}"
      sid="unknown"
      seen=""
      newest="$(ls -t "$OMP_DIR/sessions/$enc"/*.jsonl 2>/dev/null | head -1)"
      if [ -n "$newest" ]; then
        sid="$(basename "$newest" .jsonl)"
        seen="$(file_mtime "$newest")"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$status" "$sid" "$cwd" "$seen"
    done
}

# render <recs>
# Tagged streams into one awk: pid->tty, tty->pane, and the agents. A dead pid
# has no `ps` line, so its stale registry entry drops out at the tty join.
#
# The pane that opened the picker (OMP_HOST_PANE, threaded in by list.sh) and
# omp's own pane (@claude_omp_pane, recorded by the extension) are kind "host":
# they sink to the bottom and carry no pid, so ctrl-x can never kill them.
render() {
  {
    ps -o pid=,tty= -p "$(printf '%s\n' "$1" | cut -f1 | paste -sd, -)" 2>/dev/null |
      awk '{ print "P\t" $1 "\t" $2 }'
    tmux list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}' 2>/dev/null
    printf '%s\n' "$1" | sed $'s/^/A\t/'
  } | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" \
    -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
    -v self_pane="${OMP_HOST_PANE:-${TMUX_PANE:-}}" -v omp_pane="$(tmux show-options -gqv @claude_omp_pane 2>/dev/null)" '
    $1 == "P" { tty_of[$2] = $3; next }
    $1 == "T" { sub(/^\/dev\//, "", $2); pane[$2] = $3; sess[$2] = $4; loc[$2] = $5; pane_pid[$2] = $6; next }
    $1 == "A" && $2 != "" {
      tty = tty_of[$2]
      if (tty == "" || !(tty in pane)) next   # dead, or not running inside tmux
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

      secs = ($6 != "") ? now - $6 : 1e12   # unknown activity sorts last
      mins = int(secs / 60)
      if      ($6 == "")    age = "-"
      else if (mins < 60)   age = mins "m"
      else if (mins < 2880) age = int(mins / 60) "h"
      else                  age = int(mins / 1440) "d"
      kind = (index(sess[tty], prefix) == 1) ? "dedicated" : "loose"
      if (is_host) { kind = "host"; rank = 4 }   # host entries sink to the bottom

      path = $5
      if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

      pid = (is_host) ? "-" : pane_pid[tty]
      printf "%d\t%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\n",
        secs, rank, pane_id, pid, kind, icon, age, loc[tty], path
    }
  ' | sort -t$'\t' $sort_keys | cut -f2-
  # The age column mixes units ("5m", "3h", "2d"), so the sort runs on a leading
  # seconds column, cut off once it has served.
}

# status: rank asc (what needs you floats up), then age asc so whatever just went
# idle sits at the top of its group. recent: age asc alone.
if [ "$(get_tmux_option @claude_sort 'status')" = recent ]; then
  sort_keys='-k1,1n'
else
  sort_keys='-k2,2n -k1,1n'
fi

recs="$(registry_recs)" && [ -n "$recs" ] || exit 0
out="$(render "$recs")"
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
