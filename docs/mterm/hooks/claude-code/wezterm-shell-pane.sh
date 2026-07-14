#!/bin/bash
# wezterm-shell-pane.sh - focus-safe compact panel for long foreground commands.
# Ported from the MTerm Copilot adapter to Claude Code: --hook reads a
# PreToolUse payload (tool_input object) and rewrites the Bash tool command via
# hookSpecificOutput.updatedInput; --run streams the wrapped command into a
# bottom WezTerm pane when it outlives the 2s threshold.

# wezterm cli must be reachable even when the hook runs outside a login shell.
PATH="/Applications/MTerm.app/Contents/MacOS:/Applications/WezTerm.app/Contents/MacOS:$PATH"

hook_mode() {
  local input tool_input command description command_b64 description_b64 modified_input runner

  input=$(cat) || return 0
  [[ -n "${WEZTERM_PANE:-}" && -S "${WEZTERM_UNIX_SOCKET:-}" ]] || return 0

  tool_input=$(
    jq -c '
      .tool_input
      | if type == "string" then (fromjson? // {}) else (. // {}) end
    ' <<<"$input" 2>/dev/null
  ) || return 0

  # Background commands never create a panel; leave them untouched.
  [[ "$(jq -r '.run_in_background // false' <<<"$tool_input" 2>/dev/null)" != "true" ]] || return 0

  command=$(jq -r '.command // empty' <<<"$tool_input" 2>/dev/null) || return 0
  [[ -n "$command" && "$command" != *"wezterm-shell-pane.sh --run"* ]] || return 0

  description=$(jq -r '.description // empty' <<<"$tool_input" 2>/dev/null)
  if [[ -z "$description" ]]; then
    description=${command%%$'\n'*}
  fi
  description=${description:0:100}

  command_b64=$(printf '%s' "$command" | /usr/bin/base64 | tr -d '\n')
  description_b64=$(printf '%s' "$description" | /usr/bin/base64 | tr -d '\n')
  runner="$HOME/.claude/hooks/wezterm-shell-pane.sh"

  modified_input=$(
    jq -c \
      --arg command "$runner --run '$command_b64' '$description_b64'" \
      '.command = $command' <<<"$tool_input" 2>/dev/null
  ) || return 0

  jq -cn --argjson updatedInput "$modified_input" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: $updatedInput}}'
}

run_mode() {
  local command command_preview label source_pane output_file done_file pane_file stream_fifo focus_lock
  local command_pid tee_pid pane_id status watcher_pid

  command=$(printf '%s' "${1:-}" | /usr/bin/base64 -D 2>/dev/null) || return 1
  label=$(printf '%s' "${2:-}" | /usr/bin/base64 -D 2>/dev/null)
  command_preview=${command%%$'\n'*}
  command_preview=${command_preview:0:140}

  if [[ -z "${WEZTERM_PANE:-}" || ! -S "${WEZTERM_UNIX_SOCKET:-}" ]]; then
    /bin/bash -c "$command"
    return $?
  fi
  source_pane=$WEZTERM_PANE
  output_file=$(mktemp "${TMPDIR:-/tmp}/claude-wezterm-shell.XXXXXX") || {
    /bin/bash -c "$command"
    return $?
  }
  done_file="${output_file}.done"
  pane_file="${output_file}.pane"
  stream_fifo="${output_file}.stream"
  focus_lock="${TMPDIR:-/tmp}/claude-wezterm-focus-${UID}.lock"
  if ! mkfifo "$stream_fifo"; then
    rm -f "$output_file"
    /bin/bash -c "$command"
    return $?
  fi

  focused_pane_id() {
    wezterm cli list-clients --format json 2>/dev/null |
      jq -r 'sort_by([.idle_time.secs, .idle_time.nanos]) | .[0].focused_pane_id // empty'
  }

  cleanup() {
    local child pid tree focused_before_close cleanup_lock_held attempt
    if [[ -n "${watcher_pid:-}" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
      kill "$watcher_pid" 2>/dev/null || true
      wait "$watcher_pid" 2>/dev/null || true
    fi
    if [[ -n "${command_pid:-}" ]] && kill -0 "$command_pid" 2>/dev/null; then
      collect_process_tree() {
        for child in $(pgrep -P "$1" 2>/dev/null); do
          collect_process_tree "$child"
        done
        printf '%s\n' "$1"
      }
      tree="$(collect_process_tree "$command_pid")"
      for pid in $tree; do
        kill -TERM "$pid" 2>/dev/null || true
      done
      sleep 0.1
      for pid in $tree; do
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      done
    fi
    if [[ -n "${tee_pid:-}" ]] && kill -0 "$tee_pid" 2>/dev/null; then
      kill "$tee_pid" 2>/dev/null || true
      wait "$tee_pid" 2>/dev/null || true
    fi
    if [[ -z "${pane_id:-}" && -s "$pane_file" ]]; then
      read -r pane_id <"$pane_file"
    fi
    if [[ -n "${pane_id:-}" ]]; then
      cleanup_lock_held=
      for ((attempt = 0; attempt < 50; attempt++)); do
        if shlock -f "$focus_lock" -p "${BASHPID:-$$}"; then
          cleanup_lock_held=1
          break
        fi
        sleep 0.01
      done
      if [[ -n "$cleanup_lock_held" ]]; then
        focused_before_close="$(focused_pane_id)"
      else
        focused_before_close=
      fi
      wezterm cli kill-pane --pane-id "$pane_id" >/dev/null 2>&1 || true
      if [[ -n "$cleanup_lock_held" &&
            "$focused_before_close" == "$pane_id" &&
            "$source_pane" =~ ^[0-9]+$ ]]; then
        wezterm cli activate-pane --pane-id "$source_pane" >/dev/null 2>&1 || true
      fi
      if [[ -n "$cleanup_lock_held" ]]; then
        rm -f "$focus_lock"
      fi
    fi
    rm -f "$output_file" "$done_file" "$pane_file" "$stream_fifo"
  }
  handle_signal() {
    local exit_code=$1
    cleanup
    trap - EXIT INT TERM HUP
    exit "$exit_code"
  }
  trap cleanup EXIT
  trap 'handle_signal 130' INT
  trap 'handle_signal 143' TERM
  trap 'handle_signal 129' HUP

  (
    attempt=0
    focused_before=
    focus_lock_held=
    created_pane=

    release_focus_lock() {
      if [[ -n "$focus_lock_held" ]]; then
        rm -f "$focus_lock"
        focus_lock_held=
      fi
    }
    trap release_focus_lock EXIT INT TERM HUP

    for ((attempt = 0; attempt < 40; attempt++)); do
      [[ ! -e "$done_file" ]] || exit 0
      sleep 0.05
    done
    [[ ! -e "$done_file" ]] || exit 0

    for ((attempt = 0; attempt < 100; attempt++)); do
      if shlock -f "$focus_lock" -p "${BASHPID:-$$}"; then
        focus_lock_held=1
        break
      fi
      sleep 0.02
    done
    [[ -n "$focus_lock_held" ]] || exit 0

    focused_before="$(focused_pane_id)"
    [[ "$focused_before" == "$source_pane" ]] || exit 0

    created_pane=$(
      wezterm cli split-pane \
        --pane-id "$source_pane" \
        --bottom \
        --percent 18 \
        --cwd "$PWD" \
        -- /bin/bash --noprofile --norc -c '
          printf "\033]2;Running: %s\007" "$2"
          printf "\n\033[1;36m● %s\033[0m\n" "$2"
          printf "\033[2mLong-running command (2s+)\033[0m\n"
          printf "\033[2m%s\033[0m\n\n" "$3"
          tail -n +1 -F "$1"
        ' _ "$output_file" "$label" "$command_preview" 2>/dev/null
    )
    [[ "$created_pane" =~ ^[0-9]+$ ]] || exit 0
    printf '%s\n' "$created_pane" >"$pane_file"

    wezterm cli activate-pane --pane-id "$source_pane" >/dev/null 2>&1 || true
  ) &
  watcher_pid=$!

  tee "$output_file" <"$stream_fifo" &
  tee_pid=$!
  /bin/bash -c "$command" >"$stream_fifo" 2>&1 &
  command_pid=$!
  wait "$command_pid"
  status=$?
  command_pid=
  wait "$tee_pid" 2>/dev/null || true
  tee_pid=
  : >"$done_file"
  wait "$watcher_pid" 2>/dev/null || true
  watcher_pid=
  if [[ -s "$pane_file" ]]; then
    read -r pane_id <"$pane_file"
  fi

  [[ -z "${pane_id:-}" ]] || sleep 0.35
  cleanup
  pane_id=
  trap - EXIT INT TERM HUP
  return "$status"
}

case "${1:-}" in
  --hook)
    hook_mode
    ;;
  --run)
    shift
    run_mode "$@"
    ;;
esac
