#!/usr/bin/env bash
# Reviewer: empirical truth. The "did the model imagine the code is
# correct?" check.
#
# This reviewer auto-detects the project's build system and runs build
# + test in a sandboxed git worktree. It also reads the orchestrator-
# fetched ci-status.md so its output stays in parity with whatever
# GitHub Actions saw on the same SHA.
#
# Detection (first match wins):
#   Cargo.toml          → cargo build / cargo test
#   package.json        → npm run build / npm test (only if scripts present)
#   pyproject.toml      → python -m pytest (only if pytest is in deps)
#   Makefile target `test` → make test
#
# If nothing detected, the reviewer skips local execution and reports
# only on CI status. This keeps the global default useful for any
# repo without making it Rust-only.
#
# Project overrides can replace this whole script if they want
# project-specific build commands (e.g. monorepos, custom test
# runners). The override pattern is: copy this file into
# `<repo>/.ai-review/reviewers/01-runtime-truth.sh` and tailor.
#
# Worktree isolation:
# - Worktree mounted at $RUN_DIR/wt (separate working copy of HEAD_SHA)
# - claudea's Bash allowlist restricted to read-only inspection
# - Anything claudea runs lives in the worktree dir; can't touch the
#   primary checkout or anything outside the worktree's tree
# - Worktree torn down on exit
# - NOTE: this is NOT an execution sandbox — build/test commands can still
#   access the network, user home, and credentials. Use --exclude runtime-truth
#   or project-specific sandboxing if that's a concern.
#
# This is the most expensive reviewer (build is multi-minute on Rust
# / Java / large monorepos); easy to opt out via --exclude runtime-truth.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=runtime-truth
WT_DIR="$RUN_DIR/wt"
BUILD_LOG="$RUN_DIR/build.log"
TEST_LOG="$RUN_DIR/test.log"

# Always applies — even on docs-only PRs we still report CI status,
# which is cheap and catches "docs change broke a doctest" cases.
applies() { ! diff_is_empty; }

cleanup_worktree() {
  if [ -d "$WT_DIR" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$WT_DIR" 2>/dev/null \
      || rm -rf "$WT_DIR"
  fi
}

detect_build_system() {
  # Echoes a label and exports BUILD_CMD / TEST_CMD when detected.
  # Returns 0 on detection, 1 otherwise.
  if [ -f "$REPO_ROOT/Cargo.toml" ]; then
    BUILD_LABEL="cargo"
    BUILD_CMD="cargo build --workspace --locked"
    TEST_CMD="cargo test --workspace --locked"
    return 0
  fi
  if [ -f "$REPO_ROOT/package.json" ]; then
    # Only run if there's an actual `test` script — avoids `npm ERR! missing script`.
    if python3 -c "
import json, sys
try: pkg = json.load(open('$REPO_ROOT/package.json'))
except Exception: sys.exit(1)
scr = pkg.get('scripts') or {}
sys.exit(0 if 'test' in scr else 1)
" 2>/dev/null; then
      BUILD_LABEL="npm"
      # --ignore-scripts prevents lifecycle hooks (preinstall/postinstall) from
      # running arbitrary code from the PR. Some packages need them to build
      # native addons — if tests fail, a project override can drop this flag.
      BUILD_CMD="npm install --no-audit --no-fund --prefer-offline --ignore-scripts"
      TEST_CMD="npm test --silent"
      return 0
    fi
  fi
  if [ -f "$REPO_ROOT/pyproject.toml" ] || [ -f "$REPO_ROOT/setup.py" ]; then
    # Build the grep target list from only existing files to avoid exit 2.
    _py_files=()
    for _f in "$REPO_ROOT/pyproject.toml" "$REPO_ROOT/setup.py" "$REPO_ROOT/requirements.txt"; do
      [ -f "$_f" ] && _py_files+=("$_f")
    done
    if grep -qE '(^|[[:space:]])pytest($|[[:space:]<>=])' "${_py_files[@]}" 2>/dev/null; then
      BUILD_LABEL="python"
      # Install into an isolated virtualenv so we don't touch the user/global env.
      VENV_DIR="$RUN_DIR/venv"
      BUILD_CMD="python3 -m venv '$VENV_DIR' && '$VENV_DIR/bin/pip' install -e . --quiet"
      TEST_CMD="'$VENV_DIR/bin/python' -m pytest -q"
      return 0
    fi
  fi
  if [ -f "$REPO_ROOT/Makefile" ] && grep -qE '^test:' "$REPO_ROOT/Makefile"; then
    BUILD_LABEL="make"
    BUILD_CMD="true"  # most makes have build folded into test
    TEST_CMD="make test"
    return 0
  fi
  return 1
}

run_local_build_test() {
  # $1 = "build|test" log target
  trap cleanup_worktree EXIT

  echo "  • [$NAME] creating worktree at $WT_DIR ($HEAD_SHA)..." >&2
  git -C "$REPO_ROOT" worktree add --detach "$WT_DIR" "$HEAD_SHA" >/dev/null 2>&1 \
    || { echo "(worktree create failed)" > "$BUILD_LOG"
         echo "(skipped)" > "$TEST_LOG"
         BUILD_RC=99; TEST_RC=skipped
         return 0; }

  echo "  • [$NAME] $BUILD_LABEL build: $BUILD_CMD" >&2
  ( cd "$WT_DIR" && timeout 300 bash -c "$BUILD_CMD" 2>&1 ) > "$BUILD_LOG"
  BUILD_RC=$?

  TEST_RC="skipped"
  if [ "$BUILD_RC" -eq 0 ]; then
    echo "  • [$NAME] $BUILD_LABEL test: $TEST_CMD" >&2
    ( cd "$WT_DIR" && timeout 360 bash -c "$TEST_CMD" 2>&1 ) > "$TEST_LOG"
    TEST_RC=$?
  else
    echo "(build failed; skipping tests)" > "$TEST_LOG"
  fi
}

run() {
  local has_local_build=false
  if detect_build_system; then
    has_local_build=true
    run_local_build_test
  else
    echo "  • [$NAME] no recognized build system; CI-only review" >&2
    echo "(no recognized build system — global runtime-truth reviewer skipped local build/test. See ci-status.md.)" > "$BUILD_LOG"
    echo "(skipped)" > "$TEST_LOG"
    BUILD_RC=skipped
    TEST_RC=skipped
  fi

  local sys; sys="$(stage1_header)
Additional context: this reviewer just executed local build + test in a sandboxed worktree
(if a build system was detected) and the orchestrator pre-fetched the GitHub Actions CI
status for this commit.

Local build/test outputs (read with the Read tool):
  $BUILD_LOG  (exit: $BUILD_RC)
  $TEST_LOG   (exit: $TEST_RC)

CI status (read with the Read tool):
  $RUN_DIR/ci-status.md
  $RUN_DIR/ci-status.json   (machine-readable: array of workflow runs)

If a job in ci-status.md is marked failed, full per-job logs are at:
  $RUN_DIR/ci-logs/*.log

When local and CI disagree (e.g., local passes, CI fails), the divergence
itself is a finding — flag it."

  local user="Focus area: RUNTIME TRUTH. Empirical layer.

You have actual build/test output AND the GitHub Actions verdict. Use them.

What to flag:
- If local build failed: root cause + exact compiler/error message (file:line). Distinguish 'real bug introduced by this PR' from 'flaky env issue'.
- If local tests failed: each failing test, root cause, what assumption broke.
- If local passed but CI failed (or vice versa): the divergence itself — what's different about the environments? (toolchain version, missing native dep, OS-specific path, race only one side hits.)
- Any compiler warnings or linter warnings of substance — not style nits.
- A test file was edited in the diff but produces no observable output here (silent-pass risk).
- This PR includes new code paths but ci-status.md shows green CI — verify by mapping the diff to the test logs. If a new public surface has zero test invocations in test.log, flag it.

What NOT to flag:
- Style nits (those belong to lint).
- Transcription of full logs — quote only the relevant excerpt at file:line.
- Findings already obvious from the build/test logs that the operator will see anyway — focus on synthesis: 'why did this fail?' not 'X failed'.

If everything passed locally and on CI with no warnings of substance, output: NONE."

  call_claude "$NAME" \
    "Read Glob Grep Bash(cargo *) Bash(npm *) Bash(python3 *) Bash(make *) Bash(git diff *) Bash(git log *) Bash(git show *)" \
    "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" "${AI_TIMEOUT:-1200}"
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
