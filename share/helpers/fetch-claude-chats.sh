#!/usr/bin/env bash
# Pre-stage fetch: mine the Claude Code conversation transcripts that built
# this branch into $RUN_DIR/claude-chats.md, so the 06-intent-chat reviewer
# (and any reviewer that Reads it) can check the diff against real intent.
#
# Output (always created — the empty case is its own valid state):
#   $RUN_DIR/claude-chats.md
#
# Soft-fails: any error writes a stub and exits 0, so reviewers always see a
# consistent file shape. Opt out with AI_REVIEW_CHATS=0.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || true

OUT="$RUN_DIR/claude-chats.md"
SHARE_DIR="${SHARE:-$HOME/.local/share/ai-review}"
EXPLORER="$SHARE_DIR/helpers/claude-chats.sh"

write_stub() {
  printf '# Claude Code build intent\n\n_%s_\n' "$1" > "$OUT"
  exit 0
}

[ "${AI_REVIEW_CHATS:-1}" = "0" ] && write_stub "Disabled via AI_REVIEW_CHATS=0."
[ -f "$EXPLORER" ] || write_stub "Explorer not installed (claude-chats.sh missing)."

# Tunables (bounded for token + privacy budget; override in env/config).
MAX_SESSIONS="${AI_REVIEW_CHATS_SESSIONS:-4}"
DAYS="${AI_REVIEW_CHATS_DAYS:-30}"

if ! REPO_ROOT="$REPO_ROOT" bash "$EXPLORER" digest \
      --repo "$REPO_ROOT" --max-sessions "$MAX_SESSIONS" --days "$DAYS" \
      --out "$OUT" >/dev/null 2>&1; then
  write_stub "Transcript digest failed (no transcripts, or parse error)."
fi

[ -s "$OUT" ] || write_stub "No Claude Code transcripts found for this repo."
