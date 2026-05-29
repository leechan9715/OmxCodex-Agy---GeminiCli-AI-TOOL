#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PANE_FILE="$PROJECT_ROOT/.agy-pane"
EXPECTED_CMD="agy"

if [ ! -f "$PANE_FILE" ]; then
  echo "agy pane id file not found: $PANE_FILE"
  echo "Run this command from the agy tmux pane:"
  echo "tmux display-message -p '#{pane_id}' > $PANE_FILE"
  exit 1
fi

PANE_ID="$(cat "$PANE_FILE")"
PROMPT="$*"

# Auto-inject code-reviewer prompts and rules from .codex/prompts/code-reviewer.md
SYSTEM_PROMPT_FILE="$PROJECT_ROOT/.codex/prompts/code-reviewer.md"
if [ -n "$PROMPT" ] && [ -f "$SYSTEM_PROMPT_FILE" ] && [[ ! "$PROMPT" =~ ^\[SYSTEM_RULES\] ]]; then
  # Read the core identity and scope constraints (first 35 lines)
  SYSTEM_RULES="$(head -n 35 "$SYSTEM_PROMPT_FILE" 2>/dev/null || echo "")"
  PROMPT="[SYSTEM_RULES: Act strictly under these constraints:
$SYSTEM_RULES
]

USER_REQUEST: $PROMPT"
fi

STATE_FILE="$PROJECT_ROOT/.ask-agy-last"
DEDUPE_SECONDS="${ASK_DEDUPE_SECONDS:-30}"

if [ -z "$PROMPT" ]; then
  echo "Usage: ./scripts/ask-agy.sh \"your prompt\""
  exit 1
fi

PANE_PID="$(tmux display-message -p -t "$PANE_ID" '#{pane_pid}' 2>/dev/null || true)"
PANE_COMMAND="$(tmux display-message -p -t "$PANE_ID" '#{pane_current_command}' 2>/dev/null || true)"

if [ -z "$PANE_PID" ]; then
  echo "Error: Could not find PID for pane $PANE_ID. Is tmux running?"
  exit 1
fi

# More flexible process check
if ! pgrep -a -P "$PANE_PID" | grep -Eq "(^|[ /])${EXPECTED_CMD}([[:space:]]|$)"; then
  ACTUAL_CMD="$(pgrep -a -P "$PANE_PID" | head -n 1 | awk '{print $2}' || echo "none")"
  echo "Refusing to send prompt: target pane $PANE_ID is running '$ACTUAL_CMD' (shell reported '$PANE_COMMAND'), not $EXPECTED_CMD."
  echo "If $EXPECTED_CMD is running, please ensure it is a direct child of the shell in pane $PANE_ID."
  exit 1
fi

PROMPT_HASH="$(printf '%s' "$PROMPT" | sha256sum | awk '{print $1}')"
PROMPT_KEY="$PROMPT_HASH"

# Add symmetry with ask-codex.sh/OMX pane for auto-fix markers
case "$PROMPT" in
  AUTO_FIX_FROM_AGY_REVIEW*|AUTO_FIX_FROM_CODEX_REVIEW*|AUTO_FIX_FROM_OMX_REVIEW*)
    PROMPT_KEY="AUTO_FIX_FROM_OMX_REVIEW_${PROMPT_HASH}"
    ;;
esac

NOW="$(date +%s)"

if [ "${ASK_AGY_ALLOW_DUPLICATE:-0}" != "1" ] && [ -f "$STATE_FILE" ]; then
  read -r LAST_KEY LAST_TIME < "$STATE_FILE" || true
  if [ "${LAST_KEY:-}" = "$PROMPT_KEY" ] && [[ "${LAST_TIME:-}" =~ ^[0-9]+$ ]]; then
    AGE="$((NOW - LAST_TIME))"
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$DEDUPE_SECONDS" ]; then
      echo "Skipped duplicate agy prompt sent ${AGE}s ago: $PANE_ID"
      exit 0
    fi
  fi
fi

printf '%s %s\n' "$PROMPT_KEY" "$NOW" > "$STATE_FILE"

tmux set-buffer -- "$PROMPT"
tmux paste-buffer -t "$PANE_ID"
sleep 0.5
tmux send-keys -t "$PANE_ID" Enter
sleep 0.1
tmux send-keys -t "$PANE_ID" Enter

echo "Sent to agy pane: $PANE_ID"
