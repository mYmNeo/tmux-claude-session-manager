#!/usr/bin/env bash
# Open the session picker in a popup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

# The client that pressed the key, and the session it is currently attached to.
# Looked up by exact client_name match rather than "first client anywhere that
# looks nested" — with more than one client attached (e.g. a stray popup left
# open in another window), a global scan can grab an unrelated client's session
# and detach it instead of the one this invocation actually cares about.
me="${1:-}"            # client name, expanded at bind time via #{q:client_name}
opener_pane="${2:-}"   # pane that pressed the key, expanded at bind time via #{q:pane_id}.
                       # tmux FORMAT EXPANSION, not an env var — so it survives run-shell and
                       # display-popup (unlike $TMUX_PANE, which is empty in run-shell and is
                       # the POPUP pane inside it).
my_session="$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
  awk -v me="$me" '$1 == me { print $2; exit }')"
# Defensive fallback: resolve the opener pane from the client when the binding
# did not pass it (e.g. a direct manual invocation).
if [ -z "$opener_pane" ]; then
  opener_pane="$(tmux list-clients -F '#{client_name} #{pane_id}' 2>/dev/null |
    awk -v me="$me" '$1 == me { print $2; exit }')"
fi
# The pane omp itself lives in. The extension records it (from omp's own
# $TMUX_PANE) into a tmux global option, because it is NOT reliably available
# via env once we are inside run-shell / a popup. Detaching or killing this
# pane's session would tear down omp.
omp_pane="$(tmux show-options -gqv @claude_omp_pane 2>/dev/null)"
omp_session="$( [ -n "$omp_pane" ] && tmux display -p -t "$omp_pane" '#{session_name}' 2>/dev/null )"

# open_picker <host>  — show the picker popup on <host>, or on the default client
# when <host> is empty. Returns display-popup's own exit status.
#
# Thread the opener pane id into the popup as OMP_HOST_PANE so agents.sh never
# offers to kill the Claude you navigated from. omp's own pane is read separately
# by agents.sh from the @claude_omp_pane tmux option (recorded by the extension).
open_picker() {
  if [ -n "$1" ]; then
    tmux display-popup -c "$1" -w "$w" -h "$h" -E "OMP_HOST_PANE='$opener_pane' $DIR/picker.sh"
  else
    tmux display-popup -w "$w" -h "$h" -E "OMP_HOST_PANE='$opener_pane' $DIR/picker.sh"
  fi
}

case "$my_session" in
"$prefix"*)
  # Inside a session popup: close it, then reopen the picker on the outer client.
  #
  # display-popup returns to its caller *before* tmux finishes destroying the
  # closing overlay, and a popup opened during that window never receives keyboard
  # input (it hangs). So wait for the popup's client to leave, settle past the
  # teardown, then reopen — retrying a reopen that is rejected mid-teardown (it
  # returns almost instantly, whereas a popup that opened blocks while in use).
  # Safety: never detach the session that contains the pane that opened the
  # picker (host_pane) — that IS the host's own session. Detaching it would tear
  # down omp (omp may itself be nested inside a Claude). Fall through to the
  # normal path instead: open the picker on the current client.
  if [ -n "$omp_session" ] && [ "$my_session" = "$omp_session" ]; then
    host="$me"
    tmux set-option -g @claude_parent "$host"
    open_picker "$host"
    exit 0
  fi
  tmux detach-client -s "$my_session"
  for _ in $(seq 1 100); do
    tmux list-clients -F '#{session_name}' 2>/dev/null | grep -qx "$my_session" || break
    sleep 0.05
  done
  host="$(tmux show-options -gqv @claude_parent 2>/dev/null)"
  # A stale parent would make every retry fail; fall back to the default client.
  if [ -n "$host" ] && ! tmux list-clients -F '#{client_name}' 2>/dev/null | grep -qx "$host"; then
    host=''
  fi

  sleep 0.1
  rc=0
  for _ in $(seq 1 40); do
    before=$SECONDS
    open_picker "$host"
    rc=$?
    { [ "$rc" -eq 0 ] || [ $((SECONDS - before)) -ge 1 ]; } && break
    sleep 0.1
  done
  exit "$rc"
  ;;
*)
  # Normal case: this client is already the host, with no overlay to race.
  host="$me"
  tmux set-option -g @claude_parent "$host"
  ;;
esac

open_picker "$host"
