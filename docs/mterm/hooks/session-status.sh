#!/usr/bin/env bash
# session-status.sh - reflect the Copilot CLI session name + turn state in the
# terminal/tab title and play a sound at meaningful transitions. The label is
# the Copilot session name (what /rename sets, shown at the top of the UI) so
# tabs stay identifiable instead of all reading the same directory. Driven by
# Copilot hooks (see session-status.json). Arg $1: working | done | ready | input
set -u
state="${1:-}"
requested_state="$state"

# Read the event JSON on stdin. Copilot passes session context here for every
# hook type (sessionId, cwd, ...). We use it to drain the pipe cleanly, gate the
# "input" state on attention-worthy notifications, and map the sessionId to its
# workspace.yaml so the title tracks the Copilot session name instead of $PWD.
payload="$(cat 2>/dev/null || true)"

# On a resumed session, Copilot can fire sessionStart after userPromptSubmitted.
# Do not let that later event overwrite "working" with a premature checkmark.
# A session start without a prompt is idle, while one carrying an initial prompt
# is already working.
if [ "$state" = "ready" ]; then
  initial_prompt=""
  if command -v jq >/dev/null 2>&1; then
    initial_prompt="$(printf '%s' "$payload" | jq -r '.initialPrompt // .initial_prompt // empty' 2>/dev/null || true)"
  fi
  if [ -n "$initial_prompt" ]; then
    state="working"
  else
    state="idle"
  fi
fi

# Pull sessionId and cwd out of the payload without needing jq.
sid="$(printf '%s' "$payload" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
evcwd="$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
tool_name=""
tool_args="{}"
tool_context=""
event_prompt=""
if command -v jq >/dev/null 2>&1; then
  tool_name="$(printf '%s' "$payload" | jq -r '.toolName // empty' 2>/dev/null || true)"
  tool_args="$(
    printf '%s' "$payload" |
      jq -c '
        .toolArgs
        | if type == "string" then (fromjson? // {})
          elif type == "object" then .
          else {}
          end
      ' 2>/dev/null || printf '{}'
  )"
  tool_context="$(
    printf '%s' "$tool_args" |
      jq -r '
        [
          .description?,
          .command?,
          .pattern?,
          .query?,
          .url?,
          .path?,
          .skill?,
          .agent_type?,
          .prompt?
        ]
        | map(select(type == "string" and length > 0))
        | join(" ")
      ' 2>/dev/null || true
  )"
  event_prompt="$(
    printf '%s' "$payload" |
      jq -r '.prompt // .initialPrompt // .initial_prompt // empty' 2>/dev/null || true
  )"
fi

if [ "$state" = "notification" ]; then
  notification_kind=""
  if command -v jq >/dev/null 2>&1; then
    notification_kind="$(
      printf '%s' "$payload" |
        jq -r '.kind.type // .notificationType // .notification_type // empty' 2>/dev/null ||
        true
    )"
  fi
  notification_text="$(printf '%s %s' "$notification_kind" "$payload" | tr '[:upper:]' '[:lower:]')"
  case "$notification_text" in
    *shell*complet*|*command*complet*) state="done" ;;
    *) state="input" ;;
  esac
fi

# Resolve the controlling TTY of the Copilot process (our parent) so the title
# escape lands on the pane WezTerm/tmux is actually displaying.
tty="$(ps -o tty= -p "${PPID:-0}" 2>/dev/null | tr -d '[:space:]')"
case "$tty" in
  *[0-9]*) tty="/dev/${tty#/dev/}" ;;
  *)       tty="/dev/tty" ;;
esac

# Prefer the Copilot session name (set by /rename, otherwise auto-generated) so
# each tab is identifiable instead of every tab showing the same directory.
copilot_home="${COPILOT_HOME:-$HOME/.copilot}"
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
    ""|"|"|"|-"|"|+"|">"|">-"|">+"|"repos"|"copilot"|"copilot session"|"shell"|"continue")
      return 1
      ;;
    workspace\ boundary*|you\ have\ not\ yet\ marked*)
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
    apply_patch|edit|create)
      printf '%s' "coding"
      ;;
    rg|grep|glob|view|web_fetch|fetch)
      printf '%s' "researching"
      ;;
    task)
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
    sql)
      printf '%s' "planning"
      ;;
    ask_user)
      printf '%s' "waiting for input"
      ;;
    *)
      printf '%s' "working"
      ;;
  esac
}

# agentStop ends the main agent's turn, not necessarily its async shells. Keep
# the session working until every started async shell has a completion notice.
events="$copilot_home/session-state/$sid/events.jsonl"
pending_async=""
if [ "$state" = "done" ] && [ -n "$sid" ] && [ -f "$events" ] && command -v jq >/dev/null 2>&1; then
  pending_async="$(
    jq -r '
      if .type == "user.message"
      then
        "turn"
      elif .type == "tool.execution_complete"
        and .data.toolTelemetry.properties.executionMode == "async"
      then
        (.data.result.content // "")
        | try capture("^<command started in (?:detached )?background with shellId: (?<id>[^>]+)>$").id
        | "start\t\(.)"
      elif .type == "system.notification"
        and .data.kind.type == "shell_completed"
      then
        "done\t\(.data.kind.shellId)"
      else
        empty
      end
    ' "$events" 2>/dev/null |
      awk -F '	' '
        $1 == "turn" {
          for (id in pending) {
            delete pending[id]
          }
          next
        }
        $1 == "start" { pending[$2] = 1 }
        $1 == "done"  { delete pending[$2] }
        END {
          for (id in pending) {
            print id
            exit
          }
        }
      '
  )"
  [ -z "$pending_async" ] || state="working"
fi

label=""
session_dir=""
ws=""
label_cache=""
activity_cache=""
if [ -n "$sid" ]; then
  session_dir="$copilot_home/session-state/$sid"
  ws="$session_dir/workspace.yaml"
  label_cache="$session_dir/.wezterm-label"
  activity_cache="$session_dir/.wezterm-activity"
fi

if [ -n "$ws" ] && [ ! -f "$ws" ]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.05
    [ ! -f "$ws" ] || break
  done
fi

repository=""
if [ -n "$sid" ] && [ -f "$ws" ]; then
  label="$(sed -n 's/^name:[[:space:]]*//p' "$ws" | head -1)"
  repository="$(sed -n 's/^repository:[[:space:]]*//p' "$ws" | head -1)"
  label="${label%$'\r'}"                       # strip trailing CR
  label="${label%\"}"; label="${label#\"}"     # strip surrounding double quotes
  label="${label%\'}"; label="${label#\'}"     # strip surrounding single quotes
  label="${label%"${label##*[![:space:]]}"}"   # trim trailing whitespace
  repository="${repository%$'\r'}"
  repository="${repository%\"}"; repository="${repository#\"}"
  repository="${repository%\'}"; repository="${repository#\'}"
  repository="${repository%"${repository##*[![:space:]]}"}"
  is_meaningful_label "$label" || label=""
fi

if [ -n "$label" ] && [ -n "$label_cache" ]; then
  printf '%s\n' "$label" >"$label_cache" 2>/dev/null || true
elif [ -n "$label_cache" ] && [ -f "$label_cache" ]; then
  label="$(head -1 "$label_cache" 2>/dev/null)"
  if ! is_meaningful_label "$label"; then
    label=""
    rm -f "$label_cache"
  fi
fi

if [ -z "$label" ] && command -v jq >/dev/null 2>&1; then
  prompt="$event_prompt"
  prompt="$(printf '%s\n' "$prompt" | sed -E 's/\[image:[^]]+\]//g' | awk 'NF {sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit}')"
  is_meaningful_label "$prompt" || prompt=""
  if [ -n "$prompt" ]; then
    label="$prompt"
    [ -n "$label_cache" ] && [ -d "$session_dir" ] &&
      printf '%s\n' "$label" >"$label_cache" 2>/dev/null || true
  fi
fi

if [ -z "$label" ] && [ -n "$repository" ]; then
  repository_label="${repository##*/}"
  if is_meaningful_label "$repository_label"; then
    label="$repository_label"
  fi
fi

if [ -z "$label" ]; then
  cwd_label="$(basename "${evcwd:-${PWD:-copilot}}")"
  if is_meaningful_label "$cwd_label"; then
    label="$cwd_label"
  else
    label="Copilot session"
  fi
fi

# Preserve enough of the session name for a resized vertical tab rail.
if [ "${#label}" -gt 160 ]; then
  label="$(printf '%s' "$label" | cut -c1-159)…"
fi

if [ "$state" = "input" ]; then
  case "$payload" in
    *permission*|*elicitation*|*approval*|*confirm*|*input*) ;;
    *) exit 0 ;;
  esac
fi

last_activity=""
if [ -n "$activity_cache" ] && [ -f "$activity_cache" ]; then
  last_activity="$(head -1 "$activity_cache" 2>/dev/null || true)"
fi

case "$state" in
  working)
    if [ -n "$tool_name" ]; then
      activity="$(classify_tool_activity "$tool_name" "$tool_context")"
    elif [ "$requested_state" = "done" ] && [ -n "$pending_async" ]; then
      if [ "$last_activity" = "deploying" ]; then
        activity="waiting on deployment"
      elif [ -n "$last_activity" ]; then
        activity="$last_activity"
      else
        activity="working"
      fi
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
if [ -n "$activity" ] && [ -n "$activity_cache" ] && [ -d "$session_dir" ]; then
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
printf '\033]2;%s\007' "$title" > "$tty" 2>/dev/null || true

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
    printf '\033Ptmux;\033\033]1337;SetUserVar=%s=%s\007\033\\' "$1" "$encoded" > "$tty" 2>/dev/null || true
  else
    printf '\033]1337;SetUserVar=%s=%s\007' "$1" "$encoded" > "$tty" 2>/dev/null || true
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
