#!/usr/bin/env bash
# Reviewer: security. Always applies — catches secret leaks in any file type.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=security

applies() { ! diff_is_empty; }

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: SECURITY.

- Untrusted input passed to shell, SQL, exec, or template engines
- Env-var-based config that violates the no-env-vars-for-user-config rule
- Secret-shape literals leaking into source/tests/logs
- Path traversal or symlink attacks in file handling
- Auth-token handling, scope leaks, command injection
- Phone-home behavior (none allowed)

Be concrete: name the input source and the sink it can reach."

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" 600
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
