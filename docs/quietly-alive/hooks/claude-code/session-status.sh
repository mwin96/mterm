#!/usr/bin/env bash
# session-status.sh - reflect the Claude Code session label + turn state in the
# terminal/tab title and play a sound at meaningful transitions. Ported from
# the Quietly Alive Copilot adapter: reads Claude Code hook payloads (see the
# hooks section of ~/.claude/settings.json) but emits the same generic WezTerm
# contract (COPILOT_STATE / COPILOT_LABEL / WEZTERM_ACTIVITY user vars plus the
# " · doing:" title fallback). Arg $1: working | done | ready | input | notification
set -u
state="${1:-}"
requested_state="$state"

# Read the event JSON on stdin. Claude Code passes session context here for
# every hook type (session_id, cwd, hook_event_name, ...). We use it to drain
# the pipe cleanly, gate the "input" state on attention-worthy notifications,
# and derive a stable per-session label.
payload="$(cat 2>/dev/null || true)"

sid=""
evcwd=""
tool_name=""
tool_context=""
event_prompt=""
session_title=""
start_source=""
notification_kind=""
notification_message=""
if command -v jq >/dev/null 2>&1; then
  sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
  evcwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
  tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)"
  tool_context="$(
    printf '%s' "$payload" |
      jq -r '
        .tool_input // {}
        | [
            .description?,
            .command?,
            .pattern?,
            .query?,
            .url?,
            .file_path?,
            .path?,
            .skill?,
            .args?,
            .subagent_type?,
            .prompt?
          ]
        | map(select(type == "string" and length > 0))
        | join(" ")
      ' 2>/dev/null || true
  )"
  event_prompt="$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null || true)"
  session_title="$(printf '%s' "$payload" | jq -r '.session_title // empty' 2>/dev/null || true)"
  start_source="$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null || true)"
  notification_kind="$(printf '%s' "$payload" | jq -r '.type // empty' 2>/dev/null || true)"
  notification_message="$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null || true)"
else
  sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  evcwd="$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

# SessionStart fires with source startup/resume/clear/compact. Auto-compact
# happens mid-turn, so do not flip a working session back to idle for it.
if [ "$state" = "ready" ]; then
  case "$start_source" in
    compact) exit 0 ;;
  esac
  state="idle"
fi

if [ "$state" = "notification" ]; then
  case "$notification_kind" in
    permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog) state="input" ;;
    agent_completed) state="done" ;;
    "")
      notification_text="$(printf '%s' "$notification_message" | tr '[:upper:]' '[:lower:]')"
      case "$notification_text" in
        *permission*|*approval*|*confirm*|*waiting*|*input*) state="input" ;;
        *) exit 0 ;;
      esac
      ;;
    *) exit 0 ;;
  esac
fi

# Resolve the controlling TTY of the Claude Code process (our ancestor) so the
# title escape lands on the pane WezTerm/tmux is actually displaying.
tty="$(ps -o tty= -p "${PPID:-0}" 2>/dev/null | tr -d '[:space:]')"
case "$tty" in
  *[0-9]*) tty="/dev/${tty#/dev/}" ;;
  *)       tty="/dev/tty" ;;
esac

# Per-session label/activity caches (Claude Code has no workspace.yaml, so the
# label comes from the session title, the first prompt line, or the repo name).
state_home="$HOME/.claude/wezterm-state"
case "$sid" in
  ""|*[!0-9A-Za-z-]*) sid="" ;;   # only trust a plain id; blocks path traversal
esac

is_meaningful_label() {
  local normalized
  normalized="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$normalized" =~ ^[\|\>][0-9]*[-+]?$ ]]; then
    return 1
  fi
  case "$normalized" in
    ""|"|"|"|-"|"|+"|">"|">-"|">+"|"repos"|"claude"|"claude code"|"claude session"|"shell"|"continue")
      return 1
      ;;
  esac
  return 0
}

classify_tool_activity() {
  local tool text combined
  tool="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  text="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  combined="$tool $text"

  case "$combined" in
    *"rollout status"*|*"deployment status"*|*"monitor deployment"*|*"monitoring deployment"*|\
    *"watch deployment"*|*"kubectl logs"*|*"kubectl get "*|*"kubectl describe "*|\
    *"tail "*log*|*"poll "*deploy*)
      printf '%s' "monitoring deployment"
      return
      ;;
    *pytest*|*rspec*|*jest*|*nextest*|*"cargo test"*|*"go test"*|*"gradle"*test*|\
    *"npm test"*|*"test suite"*|*"run tests"*)
      printf '%s' "testing"
      return
      ;;
    *build*|*compile*|*checkstyle*|*spotbugs*|*lint*|*typecheck*|*"type check"*|\
    *validate*|*verify*)
      printf '%s' "validating"
      return
      ;;
    *deploy*|*rollout*|*"publish artifact"*|*"publish package"*|*"ship to "*)
      printf '%s' "deploying"
      return
      ;;
    *code-review*|*"code review"*|*"review diff"*|*"review pr"*|*"pull request review"*)
      printf '%s' "reviewing"
      return
      ;;
  esac

  case "$tool" in
    edit|write|multiedit|notebookedit)
      printf '%s' "coding"
      ;;
    read|glob|grep|toolsearch|webfetch|websearch|lsp)
      printf '%s' "researching"
      ;;
    task|agent)
      case "$text" in
        *research*|*explore*) printf '%s' "researching" ;;
        *review*) printf '%s' "reviewing" ;;
        *test*|*build*) printf '%s' "validating" ;;
        *) printf '%s' "coordinating agents" ;;
      esac
      ;;
    bash)
      case "$text" in
        *"git diff"*|*"git log"*|*"git status"*|*"git show"*) printf '%s' "reviewing" ;;
        *"gh pr"*|*"pull request"*) printf '%s' "preparing pull request" ;;
        *inspect*|*research*|*search*|*"read "*|*"find "*) printf '%s' "researching" ;;
        *) printf '%s' "running command" ;;
      esac
      ;;
    exitplanmode|enterplanmode|todowrite|taskcreate|taskupdate|tasklist|taskget)
      printf '%s' "planning"
      ;;
    askuserquestion)
      printf '%s' "waiting for input"
      ;;
    *)
      printf '%s' "working"
      ;;
  esac
}

label=""
session_dir=""
label_cache=""
activity_cache=""
if [ -n "$sid" ]; then
  session_dir="$state_home/$sid"
  label_cache="$session_dir/.wezterm-label"
  activity_cache="$session_dir/.wezterm-activity"
fi

# Prefer the Claude Code session title (present on resume) so each tab is
# identifiable instead of every tab showing the same directory.
if [ -n "$session_title" ] && is_meaningful_label "$session_title"; then
  label="$session_title"
fi

if [ -n "$label" ] && [ -n "$label_cache" ]; then
  mkdir -p "$session_dir" 2>/dev/null || true
  printf '%s\n' "$label" >"$label_cache" 2>/dev/null || true
elif [ -n "$label_cache" ] && [ -f "$label_cache" ]; then
  label="$(head -1 "$label_cache" 2>/dev/null)"
  if ! is_meaningful_label "$label"; then
    label=""
    rm -f "$label_cache"
  fi
fi

if [ -z "$label" ] && [ -n "$event_prompt" ]; then
  prompt="$(printf '%s\n' "$event_prompt" | sed -E 's/\[image:[^]]+\]//g' | awk 'NF {sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit}')"
  is_meaningful_label "$prompt" || prompt=""
  if [ -n "$prompt" ]; then
    label="$prompt"
    if [ -n "$label_cache" ]; then
      mkdir -p "$session_dir" 2>/dev/null || true
      printf '%s\n' "$label" >"$label_cache" 2>/dev/null || true
    fi
  fi
fi

if [ -z "$label" ]; then
  repo_root="$(git -C "${evcwd:-${PWD:-$HOME}}" rev-parse --show-toplevel 2>/dev/null || true)"
  repository_label="${repo_root##*/}"
  if [ -n "$repository_label" ] && is_meaningful_label "$repository_label"; then
    label="$repository_label"
  fi
fi

if [ -z "$label" ]; then
  cwd_label="$(basename "${evcwd:-${PWD:-claude}}")"
  if is_meaningful_label "$cwd_label"; then
    label="$cwd_label"
  else
    label="Claude session"
  fi
fi

# Preserve enough of the session name for a resized vertical tab rail.
if [ "${#label}" -gt 160 ]; then
  label="$(printf '%s' "$label" | cut -c1-159)…"
fi

last_activity=""
if [ -n "$activity_cache" ] && [ -f "$activity_cache" ]; then
  last_activity="$(head -1 "$activity_cache" 2>/dev/null || true)"
fi

case "$state" in
  working)
    if [ -n "$tool_name" ]; then
      activity="$(classify_tool_activity "$tool_name" "$tool_context")"
    elif [ -n "$event_prompt" ]; then
      activity="planning"
    elif [ -n "$last_activity" ]; then
      activity="$last_activity"
    else
      activity="working"
    fi
    ;;
  input) activity="waiting for input" ;;
  done|idle) activity="ready" ;;
  *) activity="" ;;
esac

activity="$(printf '%s' "$activity" | tr '\r\n' '  ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-48)"
if [ -n "$activity" ] && [ -n "$activity_cache" ]; then
  mkdir -p "$session_dir" 2>/dev/null || true
  printf '%s\n' "$activity" >"$activity_cache" 2>/dev/null || true
fi
activity_suffix=""
if [ -n "$activity" ]; then
  activity_suffix=" · doing: ${activity}"
fi

case "$state" in
  working) title="⏳ ${label} · working…${activity_suffix}" ;;
  done)    title="✅ ${label} · done${activity_suffix}" ;;
  idle)    title="○ ${label} · ready${activity_suffix}" ;;
  input)   title="🔔 ${label} · needs input${activity_suffix}" ;;
  *) exit 0 ;;
esac

# Set the pane/window title. tmux captures OSC 2 as the pane title and, with
# set-titles on, forwards it to the outer terminal (WezTerm tab).
( printf '\033]2;%s\007' "$title" > "$tty" ) 2>/dev/null || true

# Expose structured state to WezTerm when direct escape passthrough is available.
# The title remains the fallback for tmux setups that intentionally disable it.
emit_wezterm_user_var() {
  [ "${TERM_PROGRAM:-}" = "WezTerm" ] || return 0
  command -v base64 >/dev/null 2>&1 || return 0
  if [ -n "${TMUX:-}" ] &&
     [ "$(tmux show-options -gqv allow-passthrough 2>/dev/null || true)" != "on" ]; then
    return 0
  fi

  encoded="$(printf '%s' "$2" | base64 | tr -d '\r\n')"
  if [ -n "${TMUX:-}" ]; then
    ( printf '\033Ptmux;\033\033]1337;SetUserVar=%s=%s\007\033\\' "$1" "$encoded" > "$tty" ) 2>/dev/null || true
  else
    ( printf '\033]1337;SetUserVar=%s=%s\007' "$1" "$encoded" > "$tty" ) 2>/dev/null || true
  fi
}

emit_wezterm_user_var "COPILOT_STATE" "$state"
emit_wezterm_user_var "COPILOT_LABEL" "$label"
emit_wezterm_user_var "WEZTERM_ACTIVITY" "$activity"

# Record the state as a tmux window option so a sidebar/status script can show
# "what this terminal is doing" (thinking / done / input) next to the window name.
if [ -n "${TMUX:-}" ]; then
  pane="${TMUX_PANE:-}"
  if [ -z "$pane" ]; then
    pane=$(tmux list-panes -a -F '#{pane_id} #{pane_tty}' 2>/dev/null | awk -v t="$tty" '$2==t{print $1; exit}')
  fi
  if [ -n "$pane" ]; then
    tmux set-option -w -t "$pane" @fm_state "$state" 2>/dev/null || true
    tmux set-option -w -t "$pane" @fm_activity "$activity" 2>/dev/null || true
  fi
fi

# Sounds (macOS afplay), non-blocking so the hook returns immediately.
case "$state" in
  done)
    command -v afplay >/dev/null 2>&1 && ( afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 & )
    ;;
  input)
    command -v afplay >/dev/null 2>&1 && ( afplay /System/Library/Sounds/Funk.aiff >/dev/null 2>&1 & )
    ;;
esac

exit 0
