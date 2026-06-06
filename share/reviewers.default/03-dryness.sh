#!/usr/bin/env bash
# Reviewer: DRY / SOLID / dead-code / rewrite-cycle detection.
#
# Where 02-architecture asks 'is this in the right layer?', this
# reviewer asks 'has this already been written?'. It looks for
# duplication across files (the candidate-for-extraction case),
# dead / unreachable code, and the 'this file has been rewritten 3
# times this quarter' signal.
#
# Uses code_archaeology heavily: when a file in the diff has a
# substantial history of competing rewrites, that's itself a finding.
#
# Global default — language-agnostic with Python concrete examples.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=dryness

applies() {
  diff_touches '.*\.(py|pyi|rs|ts|tsx|js|jsx|mjs|cjs|go|rb|java|kt|swift|c|h|cc|cpp|hpp|cs|php|scala|ex|exs|hs|ml|clj)$'
}

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: DRY / SOLID / DEAD CODE / REWRITE CYCLES.

Cross-cutting redundancy review. The maintainer cares about codebase
HEALTH over time, not just this PR in isolation.

DRY (duplication):
- A new function / class / type / pattern in the diff that duplicates
  one already in the codebase. Use mcp__claude-review__find_examples_of
  to confirm. Cite both sites: 'duplicated at <path>:<line>'.
- The diff introduces N>=2 sites that should clearly share a helper
  but each have their own copy.
- Same string / number / regex / SQL fragment repeated across files
  where a named constant in a shared module would be cleaner.
  (Python: think 'should this be a module-level constant or a
  shared util'.)

SOLID (single-responsibility / open-closed / liskov / interface-segregation /
dependency-inversion):
- A function / class / module taking on a second unrelated
  responsibility (the 'and' smell — class named UserService that
  also formats invoice PDFs).
- A switch / if-chain / Python isinstance-chain on a kind / type
  field that should be polymorphism (Open-Closed: every new variant
  requires editing the chain).
- A subtype / subclass that violates its supertype's contract (Liskov:
  raises an exception the parent doesn't, narrows accepted inputs).
- An interface / ABC / protocol with so many methods that no impl
  uses them all (Interface-Segregation: split into focused protocols).
- A high-level module reaching into a low-level module's concrete
  implementation rather than its abstract interface (Dependency-
  Inversion).

DEAD / UNREACHABLE:
- New code paths that no caller exercises in the diff. If the only
  call is from a test, flag it as 'fixture-only' so the maintainer
  can decide whether to keep.
- Existing functions / classes whose ONLY caller is removed in this
  diff — they become dead and should be removed in the same PR.
- Obvious 'will-never-fire' branches: impossible conditions, dead
  Python \`elif\`, code after \`return\` in a non-trivial way,
  unreachable \`raise\`.
- Imports that are introduced but no longer referenced after the
  diff's edits.

REWRITE CYCLES:
- Use mcp__claude-review__code_archaeology on EACH non-trivial file
  in the diff to see how many distinct rewrites it's gone through.
  If a file has been substantially rewritten >=2 times in recent
  history (different commits, different approach), the diff entering
  rewrite #3 is a yellow flag — the module's design hasn't stabilized.
- Check \$RUN_DIR/related-prs.md: are there prior PRs whose diffs
  touched the same hunks the current PR touches? If so, the project
  is paying repeated cost for an unsettled API. Surface this as ONE
  finding referencing the relevant PR numbers.

Test gaps for new shared modules:
- If you flag duplication that should be extracted, also flag whether
  the proposed common module would have testable seams. (No need to
  flag missing tests for inline duplication — that's not actionable
  until extraction happens.)

What NOT to flag:
- 2-3 lines of similar-looking code that aren't the same logical
  concern (false-positive DRY).
- Boilerplate the language requires (Python \`__init__\` / \`__repr__\`,
  Rust trait impl bodies, Go receiver methods).
- Dead code in vendored / generated directories (anything that
  matches typical generator output: \`vendor/\`, \`node_modules/\`,
  \`.venv/\`, generated protobuf / openapi stubs, etc.).
- Style nits — linter's job.
- Architectural / layer violations — that's 02-architecture.

Be conservative on duplication: a finding here should be
\`extract-this\`-actionable, with both sites and a sketch of the
common shape."

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" "${AI_TIMEOUT:-1200}"
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
