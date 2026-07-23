#!/usr/bin/env bash
# Reviewer: build-intent from the Claude Code conversation. Checks the diff
# against what the human ACTUALLY asked for and what the assistant decided in
# the session(s) that produced it — intent signal that lives in neither the
# diff nor the PR description.
#
# Distinct from 05-intent (diff vs PR description / docs / cross-PR): this one
# reads $RUN_DIR/claude-chats.md — a digest of the building conversation
# (human asks verbatim + assistant decisions, tool I/O stripped) produced by
# the fetch-claude-chats pre-stage. It catches the gap between "what was asked"
# and "what shipped" that a polished PR description papers over.
#
# Global default. A project override can point at a specific transcript dir or
# tune the privacy/scope knobs (AI_REVIEW_CHATS_DAYS, AI_REVIEW_CHATS_SESSIONS).

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=intent-chat

# Only worth running when there's a diff AND the digest actually found chats.
applies() {
  diff_is_empty && return 1
  local f="$RUN_DIR/claude-chats.md"
  [ -s "$f" ] || return 1
  # Stub digests say "No ... transcripts" / "Disabled" / "failed" — skip those.
  grep -qiE "no (matching )?.*transcripts|disabled via|digest failed|not installed" "$f" && return 1
  return 0
}

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: BUILD INTENT (from the Claude Code conversation).

READ FIRST: \$RUN_DIR/claude-chats.md — a digest of the session(s) that
produced this branch: the human's asks verbatim, plus the assistant's
stated decisions. Tool calls and file dumps are stripped. Also read
\$RUN_DIR/pr.diff and \$RUN_DIR/pr-meta.md.

Treat the chat as INTENT EVIDENCE, not ground truth — a conversation can
be wrong, exploratory, or superseded by a later message. Weigh accordingly.

What to flag (cite the chat line and the diff line side by side):
- Unmet ask: the human explicitly requested something the diff does not
  deliver (a behavior, a constraint, an edge case, a file).
- Reversed/ignored decision: the assistant stated a decision or the human
  set a constraint ('must NOT import X', 'don't touch Y', 'keep it under
  N'), and the diff violates it.
- Silent scope drift: the diff does substantial work the conversation
  never asked for and the PR description doesn't mention (the maintainer
  can't review intent that was never stated).
- Half-done intent: the chat shows a plan with N parts; only some shipped,
  with no note that the rest is deferred.
- Stated-but-unverified: the human asked for something to be verified
  ('make sure tests pass', 'check the endpoint'); the diff adds the code
  but no test/evidence backs the claim.
- Known-gap left implicit: the conversation acknowledged a caveat/risk
  that should be surfaced in the PR or a code comment but isn't.

What NOT to flag:
- Architecture / layering — that's 02-architecture.
- Duplication / dead code — that's 03-dryness.
- Failure-mode / security — that's 04-risk.
- Drift vs the PR description or project docs alone — that's 05-intent.
- Exploratory chat ideas the human later dropped: if a later ask
  overrides an earlier one, the latest intent wins. Don't flag the
  abandoned path.
- Anything you cannot anchor to a concrete diff hunk.

If the digest has no usable intent signal, return no findings rather than
inventing concerns."

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" "${AI_TIMEOUT:-1200}"
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
