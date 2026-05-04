# Writing reviewers

A reviewer is a bash script that produces one markdown file of findings.
ai-review runs all enabled reviewers sequentially, then a second-stage
pass extracts line-anchored findings and posts them as a single GitHub
review.

## File layout

```
<repo>/.ai-review/reviewers/02-style.sh        # project-specific (override)
~/.local/share/ai-review/reviewers.default/    # global defaults
```

Project files override globals by basename. Numeric prefix sets order
(`01-...` runs before `02-...`).

## Minimal template

```bash
#!/usr/bin/env bash
# Reviewer: <one-line description shown in --list>.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=style

# Returns 0 if this reviewer should run for the current PR. Use the
# diff_touches helper to gate by file extension.
applies() { diff_touches '.+\.py'; }

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: <YOUR FOCUS HERE>.

Concrete things to flag:
- ...

Do NOT flag:
- ..."

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript"
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
```

## Helpers from `lib/common.sh`

| Helper | Use |
|---|---|
| `diff_touches '<regex>'` | true if PR diff touches a path matching `<regex>` |
| `diff_is_empty` | true if there's nothing to review |
| `stage1_header` | standard preamble for stage-1 reviewer system prompts |
| `STAGE1_TOOLS` | sensible default tool allowlist for stage-1 reviewers |
| `call_claude <name> <tools> <sys> <user> <out> <transcript> [secs]` | spawn the model |
| `gh_api` | authenticated `gh api` (uses App token if available) |

## What makes a good reviewer

**Be specific about the focus.** A reviewer titled "general code review"
produces vague output. A reviewer titled "secret-leak detection in shell
scripts" produces precise output. One file = one focus area.

**Tell the model what NOT to flag.** PRs surface a lot of incidental
changes. List the things that should be ignored (formatting handled by
CI, test-only `unwrap()`, conventions enforced by linters).

**Reference your project's docs.** If you have `AGENTS.md`,
`CONTRIBUTING.md`, an architecture spec — point the reviewer at it.
The model will read it once at the start.

**Use `applies()` to gate.** Don't waste a model call on a docs-only
PR for a reviewer that needs to look at code. Filter early.

## Project-specific override pattern

When `ai-review --init` copies global defaults into your project, each
copy gets a guidance header reminding you what to tweak. You can:

- **Narrow the regex** in `applies()` — global defaults apply broadly.
- **Replace the focus area** with project-specific concerns.
- **Reference the project's docs** so reviews are calibrated.

To diff your tweaked version against the upstream:

```bash
diff <repo>/.ai-review/reviewers/02-style.sh \
     ~/.local/share/ai-review/reviewers.default/02-style.sh
```

## Custom reviewers (no global counterpart)

Drop any `NN-name.sh` into `<repo>/.ai-review/reviewers/`. As long as it
implements `applies` and `run`, ai-review picks it up. Examples this
pattern enables:

- a runtime-test reviewer: `git worktree add` the PR head, run the
  project's build + test commands inside it, capture the logs, and feed
  them to the model alongside the diff
- a project-specific architecture invariant checker (e.g. "does any new
  file in `core/` import from `platform/`?")
- a "PR description vs diff" cross-checker tuned to your PR template
