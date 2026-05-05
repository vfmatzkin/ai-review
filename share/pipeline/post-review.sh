#!/usr/bin/env bash
# Pipeline stage: build the PR Review payload from stage-3 (body) and
# stage-2 (inline comments validated against diff-lines), POST it.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

REVIEW_PAYLOAD="$RUN_DIR/review-payload.json"

# Banner prepended to the review body. Override per-project by setting
# AI_REVIEW_BANNER in <repo>/.ai-review/config. Set to empty string to disable.
DEFAULT_BANNER='> **Automated review** from the `ai-review` pipeline.
> Findings are LLM-generated — apply judgment before acting on them.'
BANNER="${AI_REVIEW_BANNER-$DEFAULT_BANNER}"
export AI_REVIEW_BANNER_RESOLVED="$BANNER"

python3 - "$RUN_DIR/stage3.md" "$RUN_DIR/stage2.json" "$RUN_DIR/diff-lines.json" "$HEAD_SHA" \
  > "$REVIEW_PAYLOAD" <<'PY'
import json, os, sys
summary_path, findings_path, valid_path, head_sha = sys.argv[1:5]
summary = open(summary_path).read().strip()
banner = os.environ.get("AI_REVIEW_BANNER_RESOLVED", "").strip()
if banner:
    summary = banner + "\n\n" + summary
findings = json.load(open(findings_path)).get("findings", [])
valid = json.load(open(valid_path))
sev = {
    "blocker": "**Blocker.** ",
    "suggestion": "**Suggestion.** ",
    "note": "**Note.** ",
}
comments = []
for f in findings:
    path = f.get("path", "")
    line = f.get("line")
    if not isinstance(line, int): continue
    if path not in valid or line not in valid[path]: continue
    body = sev.get(f.get("severity", "note"), "")
    body += (f.get("title", "") + " " + f.get("body", "")).strip()
    comments.append({"path": path, "line": line, "side": "RIGHT", "body": body})
print(json.dumps({
    "commit_id": head_sha,
    "event": "COMMENT",
    "body": summary,
    "comments": comments,
}))
PY

INLINE_COUNT=$(python3 - "$REVIEW_PAYLOAD" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1]))['comments']))
PY
)
echo "  • $INLINE_COUNT inline finding(s) validated against diff" >&2

# Skip the post if there's nothing new since a prior bot review.
# The run still appears in --status; the user gets the receipt + the
# prior URL via the registry.
if [ "$INLINE_COUNT" -eq 0 ] && [ -f "$RUN_DIR/past-reviews.json" ]; then
  # Stderr is intentionally NOT suppressed — a malformed past-reviews.json
  # or unexpected schema should surface as a warning rather than silently
  # turn into an empty PRIOR_URL (which would proceed to post a no-op
  # review built on partial assumptions).
  PRIOR_URL=$(python3 - "$RUN_DIR/past-reviews.json" <<'PY'
import json, sys
rs = json.load(open(sys.argv[1])).get('reviews', [])
print(rs[0]['url'] if rs else '')
PY
)
  if [ -n "$PRIOR_URL" ]; then
    echo "▸ no new findings since prior review: $PRIOR_URL — skipping post" >&2
    update_run_field skipped_reason "no new findings since $PRIOR_URL"
    update_run_field review_url "$PRIOR_URL"
    exit 0
  fi
fi

if [ -n "${APP_TOKEN:-}" ]; then
  RESP=$(curl -sS -X POST \
    -H "Authorization: Bearer $APP_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data-binary @"$REVIEW_PAYLOAD" \
    "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUM/reviews")
else
  RESP=$(gh api -X POST "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUM/reviews" \
    --input "$REVIEW_PAYLOAD")
fi

REVIEW_URL=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || true)
if [ -n "$REVIEW_URL" ]; then
  echo "▸ posted review: $REVIEW_URL" >&2
  # Persist the URL into the run registry so --status can link the
  # actual review (not just the PR).
  update_run_field review_url "$REVIEW_URL"
else
  echo "▸ post may have failed; response head:" >&2
  echo "$RESP" | head -10 >&2
  exit 1
fi
