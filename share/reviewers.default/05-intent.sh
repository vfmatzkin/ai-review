#!/usr/bin/env bash
# Reviewer: intent / alignment. Diff vs PR description vs project
# documentation vs cross-PR drift.
#
# This is the 'is the project building the right thing, in scope?'
# check. Distinct from architecture (HOW the code is shaped) and
# dryness (INTERNAL consistency). This one cross-checks the change
# against external promises:
#   - PR description (what the contributor said this PR does)
#   - Project docs (what the team committed to do)
#   - Recent PRs on related surfaces (drift over time)
#
# Always applies — even docs-only PRs can contradict a locked rule.
#
# Global default — language-agnostic, references whatever spec
# locations a project happens to have. Project overrides typically
# add the precise paths (e.g. an ADR directory, an internal RFC
# folder, a 'specs/' tree).

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=intent

applies() { ! diff_is_empty; }

run() {
  local sys; sys="$(stage1_header)"
  local user
  if [ "${AI_REVIEW_MODE:-pr}" = "audit" ]; then
    user="Focus area: INTENT / ALIGNMENT (whole-repo audit).

Cross-check the working tree at HEAD against any of the following
the repo actually has (skip silently if missing — most repos don't
have all):
- AGENTS.md
- CONTRIBUTING.md
- README.md and the project's stated goals
- A docs/ tree with architecture decisions, RFCs, or design specs
- Any .github/*-instructions.md the project has

Flag:
- Code that contradicts a locked design document.
- README / docs claims that aren't backed by current behavior.
- Stale documentation (e.g. flag / CLI options renamed in code, not
  in docs).
- Spec / AGENTS.md guidance not followed by current code.
- Coverage gaps for stated requirements (e.g. spec lists a method,
  no test exists for it).

What NOT to flag:
- Architectural / SOLID / DRY concerns — those have dedicated reviewers.
- Runtime / CI failures — that's runtime-truth.
- Adversarial / security / failure-mode concerns — that's risk.
- Legitimate amendments where the doc was updated alongside the code."
  else
    user="Focus area: INTENT / ALIGNMENT.

Cross-check the diff against the surrounding promises the project has
made about what it's doing.

INPUTS to read (as available — skip silently if missing):
- AGENTS.md
- CONTRIBUTING.md
- README.md (stated goals)
- The PR description at \$RUN_DIR/pr-meta.md
- Any docs/ files the project has (ADRs, RFCs, design specs)
- Any .github/*-instructions.md
- Cross-PR drift signal at \$RUN_DIR/related-prs.md (last few merged
  PRs that touched these files — read this to see whether the
  current PR contradicts decisions earlier PRs settled, or re-opens
  the same scope-creep pattern that recurs every few PRs.)

What to flag:
- Diff that contradicts a locked design document. Quote the doc line
  and the diff line side by side.
- PR description claims that aren't backed by the diff. (Description
  says 'adds X'; diff doesn't add X. Description says 'fixes Y'; the
  fix isn't visible.)
- Out-of-scope changes for the PR's stated goal — even improvements,
  if they aren't in scope of the documented unit of work, are a
  finding (the maintainer can't review what isn't tracked).
- Missing or stale documentation that should accompany this change
  (docs that referenced the old behavior still do; new public
  surface with no doc reference).
- Coverage gaps for promised behavior — if the PR description or a
  spec states a behavior, find the test that exercises it. If none,
  flag.
- Cross-PR drift: this PR changes something that an earlier PR (in
  related-prs.md) explicitly decided. Cite the earlier PR number.
- Recurring scope-creep: if related-prs.md shows the same kind of
  scope-creep pattern in 2+ recent PRs, surface that pattern as one
  finding so the maintainer can decide whether the unit-of-work
  boundaries themselves need re-drawing.

What NOT to flag:
- Architectural / layer issues — that's 02-architecture.
- Duplication / dead code — that's 03-dryness.
- Failure-mode / security — that's 04-risk.
- A diff that updates BOTH code and the documentation describing it
  (legitimate amendment; not drift)."
  fi

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" 600
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
