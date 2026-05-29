#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PANE_FILE="$PROJECT_ROOT/.omx-pane"
LEGACY_PANE_FILE="$PROJECT_ROOT/.codex-pane"
EXPECTED_CMD_PATTERN='(^|[ /])(omx(\.js)?|codex)([[:space:]]|$)'

if [ ! -f "$PANE_FILE" ] && [ -f "$LEGACY_PANE_FILE" ]; then
  PANE_FILE="$LEGACY_PANE_FILE"
fi

if [ ! -f "$PANE_FILE" ]; then
  echo "OMX pane id file not found: $PANE_FILE"
  echo "Run this command from the OMX tmux pane:"
  echo "tmux display-message -p '#{pane_id}' > $PROJECT_ROOT/.omx-pane"
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
  echo "Usage: ./scripts/ask-codex.sh [--done] \"your prompt\""
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

# Auto-inject 'work' keyword for review markers to trigger persistent mode
case "$PROMPT" in
  AUTO_FIX_FROM_AGY_REVIEW*|AUTO_FIX_FROM_GEMINI_REVIEW*)
    if [[ ! "$PROMPT" =~ ^work[[:space:]] ]]; then
      PROMPT="work $PROMPT"
    fi
    ;;
esac

# Append done phrase if flag is set
if [ "$DONE_MODE" -eq 1 ]; then
  if [ -n "$PROMPT" ]; then
    PROMPT="$PROMPT ($DONE_PHRASE)"
  else
    PROMPT="$DONE_PHRASE"
  fi
fi

STATE_FILE="$PROJECT_ROOT/.ask-omx-last"
DEDUPE_SECONDS="${ASK_DEDUPE_SECONDS:-30}"

PANE_PID="$(tmux display-message -p -t "$PANE_ID" '#{pane_pid}' 2>/dev/null || true)"
PANE_COMMAND="$(tmux display-message -p -t "$PANE_ID" '#{pane_current_command}' 2>/dev/null || true)"
PANE_CHILDREN="$(pgrep -a -P "$PANE_PID" 2>/dev/null || true)"

if [ -z "$PANE_PID" ] || ! printf '%s\n' "$PANE_CHILDREN" | grep -Eq "$EXPECTED_CMD_PATTERN"; then
  echo "Refusing to send prompt: target pane $PANE_ID is running '${PANE_COMMAND:-unknown}', not OMX/Codex."
  echo "Start OMX in that pane, then refresh the pane id if needed:"
  echo "tmux display-message -p '#{pane_id}' > .omx-pane"
  exit 1
fi

PROMPT_HASH="$(printf '%s' "$PROMPT" | sha256sum | awk '{print $1}')"
PROMPT_KEY="$PROMPT_HASH"

case "$PROMPT" in
  *AUTO_FIX_FROM_AGY_REVIEW*|*AUTO_FIX_FROM_GEMINI_REVIEW*)
    PROMPT_KEY="AUTO_FIX_FROM_REVIEW_${PROMPT_HASH}"
    ;;
esac

NOW="$(date +%s)"

ALLOW_DUPLICATE="${ASK_OMX_ALLOW_DUPLICATE:-${ASK_CODEX_ALLOW_DUPLICATE:-0}}"

if [ "$ALLOW_DUPLICATE" != "1" ] && [ -f "$STATE_FILE" ]; then
  read -r LAST_KEY LAST_TIME < "$STATE_FILE" || true
  if [ "${LAST_KEY:-}" = "$PROMPT_KEY" ] && [[ "${LAST_TIME:-}" =~ ^[0-9]+$ ]]; then
    AGE="$((NOW - LAST_TIME))"
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$DEDUPE_SECONDS" ]; then
      echo "Skipped duplicate OMX prompt sent ${AGE}s ago: $PANE_ID"
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

echo "Sent to OMX pane: $PANE_ID"
