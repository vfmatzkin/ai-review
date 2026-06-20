#!/usr/bin/env bash
# Fetch the last few merged PRs that touched any of the files in the
# current diff. Reviewers reading $RUN_DIR/related-prs.md can spot
# rewrite cycles, recurring drift, and scope-creep patterns that
# wouldn't be visible from the current PR alone.
#
# Outputs (always created — empty case is its own valid state):
#   $RUN_DIR/related-prs.json   — machine: per-file, list of related PRs
#   $RUN_DIR/related-prs.md     — prose: condensed for model consumption
#
# Heuristic:
#   - First N unique changed files from the diff (lexicographic; capped
#     to keep the `gh` budget bounded).
#   - For each, query merged PRs via the GitHub search API using the file
#     path as a text query — this is a heuristic: it matches PRs whose
#     title/body/comments mention the path, NOT a reliable "touched file"
#     lookup. Results may include false positives and miss some real PRs.
#   - Dedupe across files; keep the K most recent unique PRs.
#   - For each kept PR: title, body (truncated), final review summary
#     (most recent non-bot review), accepted / rejected hints.
#
# Soft-fails on any GH API issue: writes a stub and exits 0.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

REL_JSON="$RUN_DIR/related-prs.json"
REL_MD="$RUN_DIR/related-prs.md"
TMP="$RUN_DIR/.related-tmp"
mkdir -p "$TMP"

# Caps. `gh` is free but slow; keep budget tight.
TOP_FILES="${AI_REVIEW_RELATED_TOP_FILES:-5}"      # files to query
PRS_PER_FILE="${AI_REVIEW_RELATED_PRS_PER_FILE:-5}" # PRs per file
KEEP_TOTAL="${AI_REVIEW_RELATED_KEEP:-8}"          # final unique count
BODY_CHARS="${AI_REVIEW_RELATED_BODY_CHARS:-400}"  # body truncation

write_stub() {
  local reason="$1"
  echo '{"files":[],"prs":[]}' > "$REL_JSON"
  cat > "$REL_MD" <<EOF
# Related PRs

_${reason}_
EOF
  rm -rf "$TMP"
  echo "  • no related PRs ($reason)" >&2
  exit 0
}

if [ ! -s "$RUN_DIR/pr.diff" ]; then
  write_stub "no diff (audit mode or empty PR)"
fi

# 1. Extract changed file paths from pr.diff. `+++ b/<path>` lines.
grep -E '^\+\+\+ b/' "$RUN_DIR/pr.diff" \
  | sed 's|^+++ b/||' \
  | sort -u > "$TMP/changed-files.txt"

if [ ! -s "$TMP/changed-files.txt" ]; then
  write_stub "diff has no file additions/changes"
fi

# 2. For each changed file, find merged PRs that touched it.
# We use the `gh search prs` API which supports `path:` qualifier on
# code-search syntax via `gh api search/issues`. Falling back to per-file
# `gh pr list --search "is:merged path:<file>"` keeps it simple.
> "$TMP/all-pr-numbers.txt"
head -n "$TOP_FILES" "$TMP/changed-files.txt" | while IFS= read -r path; do
  # Skip if the path looks pathological (defensive — gh quoting can choke).
  case "$path" in
    *' '*|*'"'*|*"'"*) continue ;;
  esac
  # Use the search API: "repo:O/R is:pr is:merged" + path filter.
  # `gh api -X GET search/issues -f q=...` returns issues; PRs are issues.
  # Sort=updated keeps recent activity at the top.
  q="repo:$REPO_OWNER/$REPO_NAME is:pr is:merged \"$path\""
  if gh_api -X GET "search/issues" \
      -f "q=$q" \
      -f "sort=updated" -f "order=desc" \
      -F "per_page=$PRS_PER_FILE" \
      > "$TMP/file-results.json" 2>/dev/null; then
    python3 -c "
import json, sys
items = json.load(open(sys.argv[1])).get('items', [])
for it in items:
    print(it['number'])
" "$TMP/file-results.json" >> "$TMP/all-pr-numbers.txt"
  fi
done

# Dedupe + cap.
sort -u "$TMP/all-pr-numbers.txt" > "$TMP/unique-pr-numbers.txt"

# Exclude the current PR (if we're in PR mode).
if [ -n "${PR_NUM:-}" ]; then
  grep -vx "$PR_NUM" "$TMP/unique-pr-numbers.txt" > "$TMP/keep.txt" || true
else
  cp "$TMP/unique-pr-numbers.txt" "$TMP/keep.txt"
fi

if [ ! -s "$TMP/keep.txt" ]; then
  write_stub "no merged PRs found touching the changed files"
fi

# 3. Fetch full PR record for each kept PR (cap at KEEP_TOTAL).
# Sort by PR number desc as a cheap "most-recent first" proxy.
sort -nr "$TMP/keep.txt" | head -n "$KEEP_TOTAL" > "$TMP/final-numbers.txt"

> "$TMP/prs.json"
echo "[" >> "$TMP/prs.json"
first=1
while IFS= read -r num; do
  pr_data=$(gh_api "repos/$REPO_OWNER/$REPO_NAME/pulls/$num" 2>/dev/null || echo "{}")
  reviews=$(gh_api "repos/$REPO_OWNER/$REPO_NAME/pulls/$num/reviews" 2>/dev/null || echo "[]")
  if [ "$first" = "1" ]; then first=0; else echo "," >> "$TMP/prs.json"; fi
  python3 - "$pr_data" "$reviews" >> "$TMP/prs.json" <<'PY'
import json, sys
pr = json.loads(sys.argv[1] or "{}")
reviews = json.loads(sys.argv[2] or "[]")
out = {
    "number": pr.get("number"),
    "title": pr.get("title"),
    "body": pr.get("body") or "",
    "html_url": pr.get("html_url"),
    "merged_at": pr.get("merged_at"),
    "user": (pr.get("user") or {}).get("login"),
    "merged_by": (pr.get("merged_by") or {}).get("login"),
    "labels": [l.get("name") for l in (pr.get("labels") or []) if l.get("name")],
    "reviews": [],
}
# Keep only non-bot, non-empty reviews. Most recent first.
for rv in sorted(reviews, key=lambda r: r.get("submitted_at",""), reverse=True):
    user = rv.get("user") or {}
    if user.get("type") == "Bot":
        continue
    body = (rv.get("body") or "").strip()
    state = rv.get("state")
    if not body and state not in ("APPROVED", "CHANGES_REQUESTED"):
        continue
    out["reviews"].append({
        "user": user.get("login"),
        "state": state,
        "submitted_at": rv.get("submitted_at"),
        "body": body[:400],
    })
print(json.dumps(out))
PY
done < "$TMP/final-numbers.txt"
echo "]" >> "$TMP/prs.json"

# 4. Render related-prs.{json,md}.
python3 - "$TMP/prs.json" "$TMP/changed-files.txt" "$REL_JSON" "$REL_MD" "$BODY_CHARS" <<'PY'
import json, sys
prs_path, files_path, json_out, md_out, body_chars = sys.argv[1:6]
body_chars = int(body_chars)

prs = json.load(open(prs_path))
with open(files_path) as f:
    files = [ln.strip() for ln in f if ln.strip()]

json.dump({"files": files, "prs": prs}, open(json_out, "w"), indent=2)

with open(md_out, "w") as f:
    f.write(f"# Related PRs ({len(prs)} found)\n\n")
    f.write("These merged PRs matched a heuristic text search (title/body/comments) for "
            "the file paths in the current diff — not a guaranteed 'touched this file' lookup. ")
    f.write("Use them to spot recurring drift, rewrite cycles, or whether the current ")
    f.write("change re-treads ground that an earlier PR already settled.\n\n")
    f.write("**Files queried:**\n\n")
    for p in files[:10]:
        f.write(f"- `{p}`\n")
    if len(files) > 10:
        f.write(f"- _and {len(files) - 10} more…_\n")
    f.write("\n---\n\n")
    for pr in prs:
        if not pr.get("number"):
            continue
        f.write(f"## #{pr['number']} — {pr.get('title','(no title)')}\n\n")
        f.write(f"- Merged: {pr.get('merged_at','?')}  by `{pr.get('merged_by','?')}`\n")
        f.write(f"- Author: `{pr.get('user','?')}`  Labels: {', '.join(pr.get('labels') or []) or '_none_'}\n")
        f.write(f"- Link: {pr.get('html_url','')}\n\n")
        body = (pr.get("body") or "").strip()
        if body:
            f.write("### Description\n\n")
            f.write(body[:body_chars])
            if len(body) > body_chars:
                f.write(f" _…(+{len(body) - body_chars} chars)_")
            f.write("\n\n")
        if pr.get("reviews"):
            f.write("### Reviews\n\n")
            for rv in pr["reviews"][:3]:
                state = rv.get("state","")
                snippet = (rv.get("body") or "").replace("\n", " ")[:200]
                f.write(f"- `{rv.get('user','?')}` ({state}, {rv.get('submitted_at','?')[:10]}): {snippet}\n")
            f.write("\n")
        f.write("---\n\n")
PY

rm -rf "$TMP"
N=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('prs',[])))" "$REL_JSON")
echo "  • related-prs.md ($N PR(s))" >&2
