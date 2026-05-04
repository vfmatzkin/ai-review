#!/usr/bin/env bash
# Audit-mode terminal stage: concat stage-1 reviewer outputs into a
# single markdown report at <repo>/.ai-review/audits/YYYY-MM-DD-HHMM.md.
# Registers the file path as the run's review_url so --status links it.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

AUDIT_DIR="$REPO_ROOT/.ai-review/audits"
mkdir -p "$AUDIT_DIR"

STAMP="$(date +%Y-%m-%d-%H%M)"
OUT="$AUDIT_DIR/$STAMP.md"

HEAD_SHORT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")"
BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "(detached)")"

{
  echo "# Audit report — $REPO_OWNER/$REPO_NAME"
  echo
  echo "- Generated: $(date '+%Y-%m-%d %H:%M %Z')"
  echo "- HEAD: \`$HEAD_SHORT\` on \`$BRANCH\`"
  echo "- Profile: \`$AI_CMD\` (\`$AI_PROFILE_DIR\`)"
  [ -n "${AI_MODEL:-}" ] && echo "- Model: \`$AI_MODEL\`"
  echo
  echo "---"
  echo

  empty=true
  for f in "$RUN_DIR/stage1"/*.md; do
    [ -s "$f" ] || continue
    name="$(basename "$f" .md)"
    content="$(cat "$f")"
    if [ "$content" = "NONE" ]; then
      printf '## %s\n\n_No findings._\n\n' "$name"
    else
      printf '## %s\n\n%s\n\n' "$name" "$content"
      empty=false
    fi
  done

  if $empty; then
    echo "_All reviewers reported NONE. Repo is clean for the audited focus areas._"
  fi
} > "$OUT"

echo "▸ audit report: $OUT" >&2
update_run_field review_url "$OUT"
update_run_field kind audit
