#!/usr/bin/env bash
# Reviewer: spec / intent / description-vs-diff. Always applies.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=spec

applies() { ! diff_is_empty; }

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: SPEC AND INTENT MISMATCH.

Cross-check the diff against:
- AGENTS.md
- docs/superpowers/specs/<latest>.md (active slice spec)
- docs/north-star.md if present
- The PR's own description (intent vs implementation)

Flag:
- Diff that contradicts a locked design document
- PR description claims that aren't backed by the diff
- Out-of-scope changes for the PR's stated goal
- Missing or stale documentation that should accompany this change"

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" 600
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
