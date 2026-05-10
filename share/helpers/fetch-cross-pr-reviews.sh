#!/usr/bin/env bash
# Fetch the last N reviews this bot posted across the repo (NOT just
# this PR). Stage 3 reads the result to spot recurring drift —
# patterns the bot has flagged on other PRs that the maintainer
# hasn't addressed yet, or that keep recurring slice after slice.
#
# Outputs (always created — empty case is its own valid state):
#   $RUN_DIR/cross-pr-reviews.json
#   $RUN_DIR/cross-pr-reviews.md
#
# Soft-fails: any GH API issue writes a stub and exits 0.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

CROSS_JSON="$RUN_DIR/cross-pr-reviews.json"
CROSS_MD="$RUN_DIR/cross-pr-reviews.md"
TMP="$RUN_DIR/.cross-tmp"
mkdir -p "$TMP"

KEEP_REVIEWS="${AI_REVIEW_CROSS_PR_KEEP:-5}"
SCAN_PRS="${AI_REVIEW_CROSS_PR_SCAN:-15}"
BODY_CHARS="${AI_REVIEW_CROSS_PR_BODY_CHARS:-600}"

write_stub() {
  local reason="$1"
  echo '{"reviews":[]}' > "$CROSS_JSON"
  cat > "$CROSS_MD" <<EOF
# Cross-PR review history

_$reason_
EOF
  rm -rf "$TMP"
  echo "  • no cross-PR review data ($reason)" >&2
  exit 0
}

# Determine the bot's identity. App-token path: query /user. Fallback:
# parse \`gh auth status\` for the gh-user login.
BOT_LOGIN=""
if [ -n "${APP_TOKEN:-}" ]; then
  BOT_LOGIN="$(gh_api user 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('login') or '')" 2>/dev/null || true)"
fi
if [ -z "$BOT_LOGIN" ]; then
  BOT_LOGIN="$(gh auth status 2>&1 | grep -oE 'Logged in to github\.com (account|as) [A-Za-z0-9_-]+' | awk '{print $NF}' | head -1)"
fi
if [ -z "$BOT_LOGIN" ]; then
  write_stub "could not determine bot identity"
fi

# 1. Find recently-active PRs in the repo.
if ! gh_api -X GET "repos/$REPO_OWNER/$REPO_NAME/pulls" \
    -F "state=all" -F "sort=updated" -F "direction=desc" -F "per_page=$SCAN_PRS" \
    > "$TMP/recent-prs.json" 2>/dev/null; then
  write_stub "GitHub API request failed"
fi

PR_NUMS=$(python3 -c "
import json,sys
prs = json.load(open(sys.argv[1]))
for p in prs:
    n = p.get('number')
    if n: print(n)
" "$TMP/recent-prs.json")

# 2. For each, pull its reviews; keep the ones authored by BOT_LOGIN.
> "$TMP/all-reviews.jsonl"
for num in $PR_NUMS; do
  # Skip current PR — that's covered by past-reviews.md already.
  [ "$num" = "${PR_NUM:-}" ] && continue
  if ! gh_api "repos/$REPO_OWNER/$REPO_NAME/pulls/$num/reviews" > "$TMP/reviews-$num.json" 2>/dev/null; then
    continue
  fi
  python3 - "$TMP/reviews-$num.json" "$num" "$BOT_LOGIN" >> "$TMP/all-reviews.jsonl" <<'PY'
import json, sys
reviews_path, pr_num, bot_login = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    rs = json.load(open(reviews_path))
except Exception:
    rs = []
for r in rs:
    user = r.get("user") or {}
    if user.get("login") != bot_login:
        continue
    body = (r.get("body") or "").strip()
    if not body:
        continue
    print(json.dumps({
        "pr_number": pr_num,
        "id": r.get("id"),
        "url": r.get("html_url"),
        "submitted_at": r.get("submitted_at"),
        "state": r.get("state"),
        "body": body,
    }))
PY
done

if [ ! -s "$TMP/all-reviews.jsonl" ]; then
  write_stub "no reviews authored by '$BOT_LOGIN' on recent PRs"
fi

# 3. Sort by submitted_at desc, keep top KEEP_REVIEWS.
python3 - "$TMP/all-reviews.jsonl" "$CROSS_JSON" "$CROSS_MD" "$KEEP_REVIEWS" "$BODY_CHARS" "$BOT_LOGIN" <<'PY'
import json, sys
src, json_out, md_out, keep, body_chars, bot = sys.argv[1:7]
keep = int(keep); body_chars = int(body_chars)
items = []
with open(src) as f:
    for ln in f:
        ln = ln.strip()
        if ln:
            try: items.append(json.loads(ln))
            except Exception: pass
items.sort(key=lambda x: x.get("submitted_at",""), reverse=True)
items = items[:keep]
json.dump({"bot": bot, "reviews": items}, open(json_out, "w"), indent=2)

with open(md_out, "w") as f:
    f.write(f"# Cross-PR review history — `{bot}` on this repo\n\n")
    f.write(f"Last {len(items)} review(s) this bot posted on OTHER PRs in this repo. ")
    f.write("Stage 3 uses this to surface RECURRING patterns — issues the bot ")
    f.write("has flagged on multiple PRs but the project hasn't addressed at root.\n\n")
    f.write("---\n\n")
    for r in items:
        f.write(f"## PR #{r.get('pr_number')} — {r.get('state','?')} on {r.get('submitted_at','?')[:10]}\n\n")
        f.write(f"Link: {r.get('url','')}\n\n")
        body = r.get("body","")
        f.write(body[:body_chars])
        if len(body) > body_chars:
            f.write(f"\n\n_…(+{len(body) - body_chars} chars)_")
        f.write("\n\n---\n\n")
PY

rm -rf "$TMP"
N=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('reviews',[])))" "$CROSS_JSON")
echo "  • cross-pr-reviews.md ($N review(s) by $BOT_LOGIN)" >&2
