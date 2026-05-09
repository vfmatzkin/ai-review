#!/usr/bin/env bash
# Reviewer: adversarial layer. Failure modes + security in one focus.
#
# 'What bites under abnormal conditions?' is the unifying question
# behind both correctness-under-failure (races, cleanup, cancellation)
# and security (injection, secrets, traversal). Splitting them invites
# overlap; merging them keeps the prompt focused on adversarial
# reasoning.
#
# Always applies — even text-only diffs can leak secrets or change
# infra-as-code in dangerous ways.
#
# Global default — language-agnostic with Python concrete examples.

set -uo pipefail
LIB="${AI_REVIEW_LIB:-$HOME/.local/share/ai-review/lib/common.sh}"
# shellcheck disable=SC1090
source "$LIB"

NAME=risk

applies() { ! diff_is_empty; }

run() {
  local sys; sys="$(stage1_header)"
  local user="Focus area: ADVERSARIAL RISK. Failure modes + security.

Imagine an unfriendly environment: a flaky network, an attacker who
controls every input, processes that get killed mid-operation,
filesystems that fill up. What in this diff breaks?

FAILURE-MODE concerns:
- Unhandled errors: bare \`except:\` or \`except Exception:\` swallowing
  in Python, ignored Result / Either / Maybe in typed languages,
  ignored return codes in C / Go.
- Race conditions, lost wakeups, ordering across threads / async
  tasks. Python: shared mutable state across asyncio tasks; missing
  \`asyncio.Lock\` or \`threading.Lock\` on a shared dict; \`await\`
  inside a critical section that releases an implicit lock.
- Resource cleanup on early-return / exception / signal: missing
  \`with\` / \`try-finally\` around files / sockets / DB connections;
  \`__del__\` doing real work (it may not run).
- Deterministic-init slots (lazy-init globals, cached singletons,
  module-level constants set on first use) left in a never-set
  state when the init path raises — the second caller sees a partial
  object instead of a clean error. Common Python shape: \`if _cache
  is None: _cache = build()\` where \`build()\` raises after a
  partial assignment.
- Cancellation / timeout safety: what happens when an asyncio task is
  cancelled mid-flight, or a thread is interrupted? Is the in-flight
  work observable in a half-applied state?
- Crash propagation across thread / task / process boundaries. Python:
  a worker thread raising — does the main thread observe the failure
  via its \`Future\`, or does the main loop hang waiting for a result
  that will never come?
- Untested failure modes — if the diff adds an error path with no
  test exercising it, flag it. (Coverage of failure modes is this
  reviewer's responsibility.)

SECURITY concerns:
- Untrusted input flowing to a sensitive sink: \`os.system\`,
  \`subprocess\` with \`shell=True\`, raw SQL string-formatting
  (instead of parametrized queries), \`eval\` / \`exec\`, dynamic
  \`__import__\` / \`importlib\`, Jinja templates rendered with
  contributor-controlled HTML.
- Secret-shape literals in source / tests / logs: Bearer tokens, API
  keys, JWTs, *.pem fragments, AWS access-key prefixes (\`AKIA\`,
  \`ASIA\`), connection strings with credentials inline.
- Path traversal: any \`open(<contributor-controlled string>)\` whose
  path isn't canonicalized + bounds-checked against an allowlist.
  Python: \`Path(user_input).resolve()\` without checking the result
  is under an expected root.
- Symlink / TOCTOU attacks in file handling.
- Auth tokens / scopes / cookies handled as plain strings without
  scope validation; tokens logged or printed.
- Phone-home behavior — never silently allowed; any new HTTP / DNS
  call to external infrastructure that isn't an explicitly-stated
  dep is a finding.
- Env-var-based USER config — flag if the project's docs forbid it
  (some projects allow env vars only as last-resort dev/CI escape
  hatches, never as the primary way to configure user behavior).

Be concrete: name the input source, the sink it can reach, and what
happens at each step. Adversarial reasoning, not vague cautioning.

What NOT to flag:
- Style nits — linter's job.
- Architectural placement — that's 02-architecture.
- Duplication / dead code — that's 03-dryness.
- The general possibility of failure without a concrete trigger — say
  'X is unhandled' only when you can name an input or condition that
  causes X.

Reference cross-file behavior with grep / read tools when the failure
mode isn't visible in one file. ci-status.md may show test failures
that are themselves runtime-failure findings — but if 01-runtime-truth
already has those, don't duplicate. Focus on what's NOT failing yet
but COULD."

  call_claude "$NAME" "$STAGE1_TOOLS" "$sys" "$user" \
    "$RUN_DIR/stage1/$NAME.md" "$RUN_DIR/stage1/$NAME.transcript" 600
}

case "${1:-run}" in
  applies) applies ;;
  run) run ;;
  *) echo "usage: $0 [applies|run]" >&2; exit 2 ;;
esac
