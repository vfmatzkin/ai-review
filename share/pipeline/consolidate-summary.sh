#!/usr/bin/env bash
# Pipeline stage: write the prose summary that becomes the PR Review's
# body. Sees both stage-1 angle outputs and the stage-2 line findings
# so it doesn't restate inline comments.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

STAGE1_DIR="$RUN_DIR/stage1"
STAGE2_OUT="$RUN_DIR/stage2.json"
OUT="$RUN_DIR/stage3.md"

PAST_REVIEWS_BLOCK=""
PRIOR_OPENING_RULE=""
if [ -f "$RUN_DIR/past-reviews.md" ]; then
  PAST_REVIEWS_BLOCK="
- Prior bot reviews on this PR: $RUN_DIR/past-reviews.md (READ THIS)"
  PRIOR_OPENING_RULE="
- BUILDS-ON-PRIOR rule: prior reviews exist on this PR. Open with one
  sentence acknowledging them as a markdown link list (the URLs are in
  past-reviews.md), e.g.: 'Builds on [prior review](URL). New this round:
  …'. Do NOT re-summarize what those prior reviews already covered;
  focus the body on what's new since."
fi

CROSS_PR_BLOCK=""
PATTERNS_RULE=""
if [ -f "$RUN_DIR/cross-pr-reviews.json" ] \
    && python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get('reviews') else 1)
" "$RUN_DIR/cross-pr-reviews.json" 2>/dev/null; then
  # cross-pr-reviews.json has a non-empty reviews array (not a stub).
  CROSS_PR_BLOCK="
- Cross-PR review history (this bot, last few PRs): $RUN_DIR/cross-pr-reviews.md"
  PATTERNS_RULE="
- PATTERNS rule: if cross-pr-reviews.md shows the SAME concern flagged
  on 2+ recent PRs, surface that pattern in a '## Patterns' section.
  Cite the recurring PRs by number. Distinguish 'we keep flagging this
  but the project hasn't addressed it at root' from 'this single PR
  also has it'. The Patterns section ONLY appears when there's a
  genuine multi-PR pattern; never invent one. Drop the section
  entirely if no pattern emerges."
fi

USER="You are writing the SUMMARY body of a GitHub pull-request review
on PR #$PR_NUM of the $REPO_OWNER/$REPO_NAME repository. Inline line comments are posted
SEPARATELY (read $STAGE2_OUT to see what's already covered inline).

Inputs:
- Stage-1 angle reviews: every *.md in $STAGE1_DIR/
- Stage-2 line findings JSON: $STAGE2_OUT
- Diff: $RUN_DIR/pr.diff
- PR description: $RUN_DIR/pr-meta.md${PAST_REVIEWS_BLOCK}${CROSS_PR_BLOCK}

Write a serious-looking review summary. STRICT rules:

- Output begins with the first sentence of content. NO preamble.
  Forbidden first words: 'Now', 'Here', 'Based', 'I have', 'Let me'.
- No emoji headers. Use plain markdown headings:
  '## Risk', '## Architecture', '## Dryness', '## Intent', '## Patterns',
  '## Open questions'. Omit any section that has nothing to say.
- Lead with a 1-2 sentence overview of the PR's goal and net assessment.
- Prose-led: 1-3 short paragraphs per section. Lists only for genuinely
  list-shaped content. Don't restate inline findings — reference them
  implicitly. Add the meta-observations only the summary can carry.
- End with a one-line verdict.
- File:line references use markdown links of the form
  [\`path:line\`]($REPO_URL/blob/$HEAD_SHA/path#Lline)${PRIOR_OPENING_RULE}${PATTERNS_RULE}

Output the summary markdown now."

call_claude "stage3-summary" 'Read Glob Grep' \
  "Output begins with the first sentence of summary content. Forbidden openings: 'Now', 'Here', 'Based', 'I have', 'Let me'." \
  "$USER" \
  "$OUT" "$RUN_DIR/stage3.transcript" 600

python3 - "$OUT" <<'PY'
import re, sys
p = sys.argv[1]
text = open(p).read()
patterns = [
    r"^\s*Now [^\n]*\n+",
    r"^\s*Here [^\n]*\n+",
    r"^\s*Based on [^\n]*\n+",
    r"^\s*I have [^\n]*\n+",
    r"^\s*Let me [^\n]*\n+",
    r"^\s*```[a-z]*\n",
]
for pat in patterns:
    text = re.sub(pat, "", text, count=1, flags=re.IGNORECASE)
open(p, "w").write(text)
PY
