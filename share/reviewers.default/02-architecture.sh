#!/usr/bin/env bash
# Reviewer: architecture / layer discipline. Static-structure layer.
#
# Focus: dependency direction, public-API surface, layer boundaries,
# port/adapter discipline, type-system / module invariants. The "is
# this PR wiring things in the right direction?" check.
#
# Distinct from `03-dryness` (duplication / dead code) and `04-risk`
# (runtime adversarial). This one only cares about the SHAPE of the
# code — does the new code respect the layers the project chose?
#
# Global default — language-agnostic with Python concrete examples.
# Rust / Go / TS projects tend to want a project override at
# `<repo>/.ai-review/reviewers/02-architecture.sh` that names their
# crate / package layout invariants verbatim.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=architecture

# Common code-file extensions. Project overrides should narrow this to
# the languages actually in use.
applies() {
  diff_touches '.*\.(py|pyi|rs|ts|tsx|js|jsx|mjs|cjs|go|rb|java|kt|swift|c|h|cc|cpp|hpp|cs|php|scala|ex|exs|hs|ml|clj)$'
}

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: ARCHITECTURE / LAYER DISCIPLINE.

Cross-check the diff against the project's stated architecture. Read
AGENTS.md, CONTRIBUTING.md, README.md, and any architecture docs
the repo has at HEAD. Those are the source of truth — flag violations
of them.

Common architectural shapes (apply only the ones the project actually
uses; don't lecture the project on a shape it hasn't chosen):

- HEX / PORTS-AND-ADAPTERS: domain layer free of platform / IO /
  framework deps; ports defined as abstract interfaces (Python: ABC
  or Protocol; Rust: trait; TS: interface); one real impl + one fake
  per port; transport / serialization concerns kept out of the domain
  (e.g. Pydantic models leaking into pure-domain modules, or
  framework-specific decorators on domain types).
- LAYERED / N-TIER (controllers → services → domain → repositories):
  dep direction points inward. UI / framework / DB drivers must not
  be imported from domain or service modules.
- CLEAN / ONION: outer rings depend on inner rings, never the reverse.
- MODULAR MONOLITH: cross-module references go through the package
  public API (Python: \`__init__.py\` re-exports; Rust: \`pub use\`
  in \`lib.rs\`; TS: top-level \`index.ts\` exports), not through
  internal submodules.
- PROJECT-SPECIFIC INVARIANTS: anything AGENTS.md / CONTRIBUTING.md
  documents as a hard rule, including 'NEVER' lists. Verbatim-quote
  the rule in the finding so the contributor can find it.

Concrete things to flag:

- Platform / IO / network / framework deps reaching into the domain
  layer. Examples: \`requests\` / \`httpx\` / \`asyncio\` imports inside
  pure-domain Python modules; SQLAlchemy \`Session\` exposed in a
  service interface; FastAPI / Flask / Django request objects threaded
  through pure-business-logic functions.
- New port / interface introduced without a fake / conformance
  harness — interfaces that aren't testable in isolation tend to
  collapse the layering.
- New real implementation shipped without the abstraction it should
  sit behind (a concrete database client used from three sites
  instead of through a single repository class).
- Public-API widening without justification in the PR description.
  In Python: a name without leading underscore added to a module's
  top level; a re-export added to \`__init__.py\`. In Rust: a new
  \`pub\`. In TS: a new top-level \`export\`.
- Adapter that bypasses its own port and calls a sibling adapter
  directly.
- Test for a new architectural surface MISSING — if the diff adds a
  new port / interface / public type and there is no test exercising
  the new boundary, flag it. (Test-coverage gaps for the architectural
  change are this reviewer's responsibility; there is no separate
  'tests' reviewer.)
- Imports / dependencies that cross a documented layer boundary in
  the wrong direction (e.g. \`from app.api import ...\` inside a
  domain module).

What NOT to flag:
- Internal implementation choices that don't cross a layer boundary.
- Style nits — that's a linter's job.
- Duplication / dead code — that's the dryness reviewer.
- Race conditions / cleanup / cancellation — that's the risk reviewer.

Use mcp__claude-review__find_examples_of when checking whether a
pattern matches existing project conventions.

If \$RUN_DIR/related-prs.md is non-empty, scan it for prior PRs that
touched the same architectural boundaries — recurring violations of
the same rule are worth surfacing in one finding rather than each
separately."

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" "${AI_TIMEOUT:-1200}"
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
