#!/usr/bin/env bash
# Fetch the most recent GitHub Actions runs for HEAD_SHA so reviewers
# can read what CI saw. Runs BEFORE stage 1 so every reviewer can
# reference $RUN_DIR/ci-status.md without re-querying the API.
#
# Outputs (always created — empty/no-runs case is its own valid state):
#   $RUN_DIR/ci-status.json   — machine: array of runs with conclusions
#   $RUN_DIR/ci-status.md     — prose: per-run summary; failed-step logs
#                                inlined for any non-success conclusion
#                                (truncated to keep model context tight)
#   $RUN_DIR/ci-logs/<run-id>-<job-name>.log   — full failed-step logs
#                                                for reviewers that want
#                                                more than the truncated
#                                                inline excerpts
#
# Soft-fails: if `gh run list` errors (no Actions on this repo, or auth
# issue), writes a "no CI data" stub and exits 0. CI absence is not an
# ai-review failure mode.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

CI_JSON="$RUN_DIR/ci-status.json"
CI_MD="$RUN_DIR/ci-status.md"
LOGS_DIR="$RUN_DIR/ci-logs"
mkdir -p "$LOGS_DIR"

# Per-job failed-log excerpt cap, lines. Full logs always go to
# $LOGS_DIR/*.log; the inline copy in ci-status.md is bounded so the
# model isn't drowned in compiler verbosity.
INLINE_LOG_LINES="${AI_REVIEW_CI_INLINE_LINES:-80}"

write_stub() {
  local reason="$1"
  echo '[]' > "$CI_JSON"
  cat > "$CI_MD" <<EOF
# CI status

_${reason}_
EOF
  echo "  • no CI data ($reason)" >&2
  exit 0
}

if [ -z "${HEAD_SHA:-}" ]; then
  write_stub "HEAD_SHA not set (orchestrator did not export it)"
fi

TMP="$RUN_DIR/.ci-tmp"
mkdir -p "$TMP"

# 1. List runs for HEAD_SHA. `gh run list --commit` filters server-side.
#    We pull a few and let the renderer pick the most recent per workflow.
if ! gh_api -X GET "repos/$REPO_OWNER/$REPO_NAME/actions/runs" \
    -F "head_sha=$HEAD_SHA" -F "per_page=20" > "$TMP/runs.json" 2>/dev/null; then
  write_stub "GitHub Actions API request failed (no Actions or auth issue)"
fi

# 2. Pick the most recent run per workflow_id; gather metadata.
python3 - "$TMP/runs.json" "$CI_JSON" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    try:
        data = json.load(f)
    except Exception:
        data = {}

runs = (data or {}).get("workflow_runs") or []
# Most recent run per workflow_id.
latest_per_wf = {}
for r in runs:
    wf = r.get("workflow_id")
    if wf is None:
        continue
    cur = latest_per_wf.get(wf)
    if not cur or (r.get("created_at", "") > cur.get("created_at", "")):
        latest_per_wf[wf] = r

out = []
for r in sorted(latest_per_wf.values(), key=lambda x: x.get("created_at", ""), reverse=True):
    out.append({
        "id": r.get("id"),
        "name": r.get("name"),
        "workflow_name": r.get("name"),
        "status": r.get("status"),         # queued | in_progress | completed
        "conclusion": r.get("conclusion"), # success | failure | cancelled | skipped | timed_out | null
        "html_url": r.get("html_url"),
        "head_sha": r.get("head_sha"),
        "head_branch": r.get("head_branch"),
        "event": r.get("event"),
        "created_at": r.get("created_at"),
        "updated_at": r.get("updated_at"),
    })

json.dump(out, open(sys.argv[2], "w"), indent=2)
print(len(out))
PY
COUNT="$(wc -l < "$CI_JSON" 2>/dev/null)"
N_RUNS="$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$CI_JSON")"

if [ "$N_RUNS" = "0" ]; then
  rm -rf "$TMP"
  write_stub "no Actions runs found for HEAD_SHA $HEAD_SHA"
fi

# 3. For each non-success run, pull failed-step logs.
RUN_IDS=$(python3 -c "
import json,sys
runs = json.load(open(sys.argv[1]))
for r in runs:
    if r.get('conclusion') and r['conclusion'] not in ('success','skipped'):
        print(r['id'])
" "$CI_JSON")

for rid in $RUN_IDS; do
  # `gh run view --log-failed` returns failed-step logs across all jobs
  # in the run, prefixed with job name. Cap server-side via head/tail.
  if gh_api -X GET "repos/$REPO_OWNER/$REPO_NAME/actions/runs/$rid/jobs" \
      > "$TMP/jobs-$rid.json" 2>/dev/null; then
    : # ok
  else
    echo '{"jobs":[]}' > "$TMP/jobs-$rid.json"
  fi

  # Per-job: if the job failed, fetch its log via the dedicated endpoint.
  python3 - "$TMP/jobs-$rid.json" "$rid" "$LOGS_DIR" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
rid = sys.argv[2]
logs_dir = sys.argv[3]
for job in (data.get("jobs") or []):
    if job.get("conclusion") in ("failure", "timed_out", "cancelled"):
        slug = "".join(c if c.isalnum() else "-" for c in (job.get("name") or "job"))[:60]
        marker = os.path.join(logs_dir, f"{rid}-{slug}.fetch")
        open(marker, "w").write(str(job["id"]))
PY

  for marker in "$LOGS_DIR/$rid"-*.fetch; do
    [ -e "$marker" ] || continue
    job_id=$(cat "$marker")
    log_path="${marker%.fetch}.log"
    if gh_api "repos/$REPO_OWNER/$REPO_NAME/actions/jobs/$job_id/logs" \
        > "$log_path" 2>/dev/null; then
      :
    else
      echo "(failed to fetch job log)" > "$log_path"
    fi
    rm -f "$marker"
  done
done

# 4. Render ci-status.md.
python3 - "$CI_JSON" "$LOGS_DIR" "$CI_MD" "$INLINE_LOG_LINES" <<'PY'
import json, os, sys

runs = json.load(open(sys.argv[1]))
logs_dir = sys.argv[2]
out_path = sys.argv[3]
inline_lines = int(sys.argv[4])

EMOJI = {
    "success": "✓",
    "failure": "✗",
    "cancelled": "⊘",
    "timed_out": "⏱",
    "skipped": "—",
    None: "…",
}

with open(out_path, "w") as f:
    f.write(f"# CI status — {len(runs)} workflow(s) for HEAD_SHA\n\n")
    for r in runs:
        e = EMOJI.get(r.get("conclusion"), r.get("status") or "?")
        title = r.get("workflow_name") or r.get("name") or f"run {r['id']}"
        concl = r.get("conclusion") or r.get("status") or "?"
        f.write(f"## {e} {title} — {concl}\n\n")
        f.write(f"- Run: {r.get('html_url','')}\n")
        f.write(f"- Event: `{r.get('event','')}`  Branch: `{r.get('head_branch','')}`\n")
        f.write(f"- Created: {r.get('created_at','')}  Updated: {r.get('updated_at','')}\n\n")

        if r.get("conclusion") and r["conclusion"] not in ("success", "skipped"):
            # Inline excerpts of any failed-job log files for this run.
            prefix = f"{r['id']}-"
            log_files = sorted(
                p for p in os.listdir(logs_dir)
                if p.startswith(prefix) and p.endswith(".log")
            )
            if not log_files:
                f.write("_(no failed-job logs available)_\n\n")
                continue
            for lf in log_files:
                lp = os.path.join(logs_dir, lf)
                try:
                    with open(lp, "r", errors="replace") as g:
                        body = g.read()
                except Exception as ex:
                    f.write(f"### `{lf}` — failed to read ({ex})\n\n")
                    continue
                lines = body.splitlines()
                # Keep the LAST inline_lines — failure tails matter more
                # than the boilerplate setup output at the top.
                tail = "\n".join(lines[-inline_lines:])
                f.write(f"### `{lf}` (last {min(len(lines), inline_lines)} lines of {len(lines)})\n\n")
                f.write("```\n")
                f.write(tail)
                if not tail.endswith("\n"):
                    f.write("\n")
                f.write("```\n\n")
                f.write(f"_Full log: `{lp}`_\n\n")
PY

rm -rf "$TMP"
echo "  • ci-status.md ($N_RUNS workflow(s))" >&2
