#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PANE_FILE="$PROJECT_ROOT/.gemini-pane"
EXPECTED_CMD_PATTERN='(^|[ /])(gemini|omx(\.js)?|codex)([[:space:]]|$)'

if [ ! -f "$PANE_FILE" ]; then
  echo "Gemini pane id file not found: $PANE_FILE"
  echo "Run this command from the Gemini tmux pane:"
  echo "tmux display-message -p '#{pane_id}' > $PANE_FILE"
  exit 1
fi

PANE_ID="$(cat "$PANE_FILE")"
PROMPT=""
DONE_MODE=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --done)
      DONE_MODE=1
      shift
      ;;
    *)
      if [ -z "$PROMPT" ]; then
        PROMPT="$1"
      else
        PROMPT="$PROMPT $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$PROMPT" ] && [ "$DONE_MODE" -eq 0 ]; then
  echo "Usage: ./scripts/ask-gemini.sh [--done] \"your prompt\""
  exit 1
fi

# Detect language from oma-config.yaml
LANG_SETTING=$(grep "^language:" "$PROJECT_ROOT/.agents/oma-config.yaml" 2>/dev/null | awk '{print $2}' || echo "en")
case "$LANG_SETTING" in
  ko) DONE_PHRASE="워크플로우 종료" ;;
  ja) DONE_PHRASE="ワークフロー終了" ;;
  zh) DONE_PHRASE="工作流结束" ;;
  *)  DONE_PHRASE="workflow done" ;;
esac

# Append done phrase if flag is set
if [ "$DONE_MODE" -eq 1 ]; then
  if [ -n "$PROMPT" ]; then
    PROMPT="$PROMPT ($DONE_PHRASE)"
  else
    PROMPT="$DONE_PHRASE"
  fi
fi

# Auto-inject '$code-reviewer' prefix to restrict agent to read-only review sandbox
if [ -n "$PROMPT" ] && [[ ! "$PROMPT" =~ ^\$ ]]; then
  PROMPT="\$code-reviewer $PROMPT"
fi

STATE_FILE="$PROJECT_ROOT/.ask-gemini-last"
DEDUPE_SECONDS="${ASK_DEDUPE_SECONDS:-30}"

PANE_PID="$(tmux display-message -p -t "$PANE_ID" '#{pane_pid}' 2>/dev/null || true)"
PANE_COMMAND="$(tmux display-message -p -t "$PANE_ID" '#{pane_current_command}' 2>/dev/null || true)"

if [ -z "$PANE_PID" ]; then
  echo "Error: Could not find PID for pane $PANE_ID. Is tmux running?"
  exit 1
fi

if ! pgrep -a -P "$PANE_PID" | grep -Eq "$EXPECTED_CMD_PATTERN"; then
  ACTUAL_CMD="$(pgrep -a -P "$PANE_PID" | head -n 1 | awk '{print $2}' || echo "none")"
  echo "Refusing to send prompt: target pane $PANE_ID is running '$ACTUAL_CMD' (shell reported '$PANE_COMMAND'), not gemini/omx/codex."
  echo "If it is running, please ensure it is a direct child of the shell in pane $PANE_ID."
  exit 1
fi

PROMPT_HASH="$(printf '%s' "$PROMPT" | sha256sum | awk '{print $1}')"
PROMPT_KEY="$PROMPT_HASH"

case "$PROMPT" in
  AUTO_FIX_FROM_GEMINI_REVIEW*|AUTO_FIX_FROM_CODEX_REVIEW*|AUTO_FIX_FROM_OMX_REVIEW*)
    PROMPT_KEY="AUTO_FIX_FROM_OMX_REVIEW_${PROMPT_HASH}"
    ;;
esac

NOW="$(date +%s)"

if [ "${ASK_GEMINI_ALLOW_DUPLICATE:-0}" != "1" ] && [ -f "$STATE_FILE" ]; then
  read -r LAST_KEY LAST_TIME < "$STATE_FILE" || true
  if [ "${LAST_KEY:-}" = "$PROMPT_KEY" ] && [[ "${LAST_TIME:-}" =~ ^[0-9]+$ ]]; then
    AGE="$((NOW - LAST_TIME))"
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$DEDUPE_SECONDS" ]; then
      echo "Skipped duplicate Gemini prompt sent ${AGE}s ago: $PANE_ID"
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

echo "Sent to Gemini pane: $PANE_ID"
