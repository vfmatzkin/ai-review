#!/usr/bin/env bash
# Fetch prior bot reviews on the current PR (and their inline comments)
# so later pipeline stages can dedupe and cross-reference. Runs AFTER
# stage 1 so reviewers form their findings without bias from prior runs.
#
# Outputs (only created if there's at least one prior bot review):
#   $RUN_DIR/past-reviews.json   — machine: url, body, [(path,line,body)...]
#   $RUN_DIR/past-reviews.md     — prose: model-readable cross-ref context

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

PAST_JSON="$RUN_DIR/past-reviews.json"
PAST_MD="$RUN_DIR/past-reviews.md"
TMP="$RUN_DIR/.past-reviews-tmp"
mkdir -p "$TMP"

# 1. List reviews on this PR.
if ! gh_api "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUM/reviews" > "$TMP/reviews.json" 2>/dev/null; then
  echo '[]' > "$TMP/reviews.json"
fi

# 2. Pick bot review IDs (most-recent first, max 5).
BOT_REVIEW_IDS=$(python3 - "$TMP/reviews.json" <<'PY'
import json, sys
try:
    rs = json.load(open(sys.argv[1]))
    if not isinstance(rs, list): rs = []
except Exception:
    rs = []
bots = [r for r in rs if (r.get('user') or {}).get('type') == 'Bot' and (r.get('body') or '').strip()]
bots.sort(key=lambda x: x.get('submitted_at',''), reverse=True)
for r in bots[:5]:
    print(r['id'])
PY
)

# 3. For each bot review, fetch its inline comments.
for rid in $BOT_REVIEW_IDS; do
  gh_api "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUM/reviews/$rid/comments" \
    > "$TMP/comments-$rid.json" 2>/dev/null || echo '[]' > "$TMP/comments-$rid.json"
done

# 4. Render past-reviews.json + past-reviews.md.
python3 - "$TMP" "$PAST_JSON" "$PAST_MD" <<'PY'
import json, os, sys

tmp, json_out, md_out = sys.argv[1:4]
try:
    reviews = json.load(open(os.path.join(tmp, "reviews.json")))
    if not isinstance(reviews, list): reviews = []
except Exception:
    reviews = []

out = []
for r in sorted(reviews, key=lambda x: x.get("submitted_at",""), reverse=True):
    user = r.get("user") or {}
    if user.get("type") != "Bot":
        continue
    body = (r.get("body") or "").strip()
    if not body:
        continue
    rid = r["id"]
    cpath = os.path.join(tmp, f"comments-{rid}.json")
    comments = []
    if os.path.exists(cpath):
        try:
            for c in json.load(open(cpath)):
                line = c.get("line") or c.get("original_line")
                if not c.get("path") or not isinstance(line, int):
                    continue
                comments.append({
                    "path": c["path"],
                    "line": line,
                    "body": (c.get("body") or "").strip(),
                })
        except Exception:
            pass
    out.append({
        "id": rid,
        "url": r.get("html_url",""),
        "submitted_at": r.get("submitted_at",""),
        "user": user.get("login",""),
        "body": body,
        "comments": comments,
    })
    if len(out) >= 5:
        break

if not out:
    sys.exit(0)

json.dump({"reviews": out}, open(json_out, "w"), indent=2)

with open(md_out, "w") as f:
    f.write(f"# Prior reviews on this PR ({len(out)} found)\n\n")
    for r in out:
        f.write(f"## {r['user']} — {r['submitted_at']}\n")
        f.write(f"Link: {r['url']}\n\n")
        f.write("### Body\n\n")
        f.write(r["body"])
        f.write("\n\n")
        if r["comments"]:
            f.write("### Inline findings\n\n")
            for c in r["comments"]:
                snippet = c["body"][:240].replace("\n", " ")
                f.write(f"- `{c['path']}:{c['line']}` — {snippet}\n")
            f.write("\n")
PY

rm -rf "$TMP"

if [ -f "$PAST_JSON" ]; then
  COUNT=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('reviews',[])))" "$PAST_JSON")
  echo "  • found $COUNT prior bot review(s) on PR #$PR_NUM" >&2
else
  echo "  • no prior bot reviews on PR #$PR_NUM" >&2
fi
