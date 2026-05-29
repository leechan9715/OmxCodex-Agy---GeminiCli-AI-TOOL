#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="ai"
REVIEWER="${1:-agy}"
OMX_LAUNCH_CMD="${OMX_LAUNCH_CMD:-omx --direct}"

case "$REVIEWER" in
  agy)
    REVIEWER_CMD="omx --direct"
    REVIEWER_PANE_FILE="$PROJECT/.agy-pane"
    STALE_PANE_FILE="$PROJECT/.gemini-pane"
    ;;
  gemini)
    REVIEWER_CMD="omx --direct"
    REVIEWER_PANE_FILE="$PROJECT/.gemini-pane"
    STALE_PANE_FILE="$PROJECT/.agy-pane"
    ;;
  -h|--help|help)
    echo "Usage: ./scripts/start-ai.sh [agy|gemini]"
    exit 0
    ;;
  *)
    echo "Unknown reviewer CLI: $REVIEWER"
    echo "Usage: ./scripts/start-ai.sh [agy|gemini]"
    exit 1
    ;;
esac

tmux kill-session -t "$SESSION" 2>/dev/null || true

OMX_PANE_ID=$(tmux new-session -d -s "$SESSION" -c "$PROJECT" -n main -P -F "#{pane_id}")
tmux send-keys -t "$OMX_PANE_ID" "$OMX_LAUNCH_CMD" C-m

REVIEWER_PANE_ID=$(tmux split-window -h -t "$OMX_PANE_ID" -c "$PROJECT" -P -F "#{pane_id}")
tmux send-keys -t "$REVIEWER_PANE_ID" "$REVIEWER_CMD" C-m

echo "$OMX_PANE_ID" > "$PROJECT/.omx-pane"
echo "$OMX_PANE_ID" > "$PROJECT/.codex-pane"
echo "$REVIEWER_PANE_ID" > "$REVIEWER_PANE_FILE"

rm -f "$STALE_PANE_FILE"

tmux select-pane -t "$OMX_PANE_ID"
tmux attach -t "$SESSION"
