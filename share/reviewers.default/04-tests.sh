#!/usr/bin/env bash
# Reviewer: test quality and coverage. Skips on docs-only PRs.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=tests

# Common code-file extensions. Project overrides are expected to narrow
# this to whatever the project actually uses.
applies() {
  diff_touches '.*\.(rs|ts|tsx|js|jsx|mjs|cjs|py|go|rb|java|kt|swift|c|h|cc|cpp|hpp|cs|php|scala|ex|exs|hs|ml|clj|sh|bash)$'
}

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: TEST QUALITY AND COVERAGE.

- New code paths added without corresponding test coverage
- Untested failure modes (errors, exceptions, partial state, timeouts)
- Tests that mock the very seams under test, leaving real behavior unverified
- Happy-path-only tests with no edge or error cases
- Tests asserting structure/internals rather than observable behavior
- Integration gaps where unit tests exist but the wiring between them isn't covered

Reference specific test file paths and the cases that are missing.
Do not flag style nits — those are a linter's job."

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" 600
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
