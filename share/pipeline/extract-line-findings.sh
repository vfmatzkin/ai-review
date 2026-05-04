#!/usr/bin/env bash
# Pipeline stage: read all stage-1 reviewer outputs + the diff, emit
# structured JSON of line-anchored findings. The orchestrator validates
# each entry against the new-side hunk lines before posting.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

# Compute (path, line) pairs that are postable as inline comments —
# i.e. lines added (or in surrounding context) on the new side.
python3 - "$RUN_DIR/pr.diff" > "$RUN_DIR/diff-lines.json" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
path = None
new_line = 0
valid = {}
for line in src.splitlines(keepends=True):
    if line.startswith("+++ b/"):
        path = line[6:].rstrip("\n")
        valid.setdefault(path, set())
    elif line.startswith("@@"):
        m = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if m:
            new_line = int(m.group(1)) - 1
    elif line.startswith("+") and not line.startswith("+++"):
        new_line += 1
        if path:
            valid[path].add(new_line)
    elif line.startswith(" "):
        new_line += 1
print(json.dumps({k: sorted(v) for k, v in valid.items()}))
PY

STAGE1_DIR="$RUN_DIR/stage1"
OUT="$RUN_DIR/stage2.json"

# List the angle outputs that actually have content
INPUTS=""
for f in "$STAGE1_DIR"/*.md; do
  [ -s "$f" ] || continue
  [ "$(cat "$f")" = "NONE" ] && continue
  INPUTS="$INPUTS$(basename "$f") "
done

if [ -z "$INPUTS" ]; then
  echo '{"findings": []}' > "$OUT"
  echo "  • no stage-1 findings to extract" >&2
  exit 0
fi

PAST_REVIEWS_HINT=""
if [ -f "$RUN_DIR/past-reviews.md" ]; then
  PAST_REVIEWS_HINT="
- Prior bot reviews on this PR: $RUN_DIR/past-reviews.md
  (READ THIS — used for dedupe; see rule 5)"
fi

USER="You are an expert reviewer that converts free-form review notes
into PRECISE per-line findings ready to post as GitHub pull-request review
comments. Output format is STRICT JSON, nothing else.

Inputs:
- Diff: $RUN_DIR/pr.diff
- Stage-1 angle reviews in: $STAGE1_DIR/ (read each *.md file)
- Postable lines (new side of hunks): $RUN_DIR/diff-lines.json
  (JSON object mapping path -> [valid lines])${PAST_REVIEWS_HINT}

Read every .md in $STAGE1_DIR. Synthesize findings into discrete
line-anchored entries. RULES:

1. Each entry MUST cite a (path, line) pair that exists in
   diff-lines.json. Drop findings that don't map to a postable line.
2. Severity is one of: blocker, suggestion, note. Be conservative.
3. Title is a short bold-able sentence. Body is one or two sentences
   plus an optional fenced code block.
4. Drop duplicates across angles — emit each finding ONCE.
5. PAST-REVIEW DEDUPE: if past-reviews.md exists, read its inline
   findings. DROP any new finding that substantively re-raises a past
   one (same file region, same concern). The goal is to avoid a
   near-identical re-post; the human will revisit the prior review.
   Keep findings only if they add genuinely new information (different
   line, different concern, or new since the prior review's commit).
6. Output ONLY valid JSON matching this shape — no preamble, no fences:

{\"findings\": [{\"severity\": \"...\", \"path\": \"...\", \"line\": N, \"title\": \"...\", \"body\": \"...\"}]}

Output the JSON now."

call_claude "stage2-extract" 'Read Glob Grep' \
  "Output valid JSON only. No preamble. No code fences around the JSON object." \
  "$USER" \
  "$OUT" "$RUN_DIR/stage2.transcript" 600

# Salvage if not parseable.
python3 - "$OUT" <<'PY'
import json, re, sys
p = sys.argv[1]
raw = open(p).read()
try:
    json.loads(raw)
except Exception:
    m = re.search(r'\{.*\}', raw, re.DOTALL)
    if m:
        try:
            json.loads(m.group(0))
            open(p, "w").write(m.group(0))
            sys.exit(0)
        except Exception:
            pass
    open(p, "w").write('{"findings": []}')
    print("warning: stage2 produced invalid JSON", file=sys.stderr)
PY
