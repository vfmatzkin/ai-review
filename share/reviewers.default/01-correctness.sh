#!/usr/bin/env bash
# Reviewer: correctness under failure. Skips on docs-only PRs.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=correctness

# Common code-file extensions. Project overrides are expected to narrow
# this to whatever the project actually uses.
applies() {
  diff_touches '.*\.(rs|ts|tsx|js|jsx|mjs|cjs|py|go|rb|java|kt|swift|c|h|cc|cpp|hpp|cs|php|scala|ex|exs|hs|ml|clj|sh|bash)$'
}

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: CORRECTNESS UNDER FAILURE.

- Error-path correctness (unhandled errors, swallowed exceptions,
  ignored return codes, mishandled Results/Either/Maybe)
- Race conditions, lost wakeups, ordering issues across threads/tasks
- Resource cleanup on exit, signal handling, graceful-shutdown paths
- Concurrency primitives left in unrecoverable terminal states
- Cancellation / timeout safety; what happens when a future / promise
  is dropped mid-flight
- Panic / crash propagation across thread / task / process boundaries

Reference cross-file behavior with grep / read tools when the bug isn't
visible in a single file. Do not flag style nits — that's a linter's job."

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" 600
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
