#!/usr/bin/env bash
# claude-chats — explorer for the Claude Code conversation transcripts that
# built a repo's changes. Surfaces INTENT: what the human actually asked for
# and what the assistant decided, mined from ~/.claude*/projects/*/*.jsonl.
#
# Why: an ai-review reviewer (06-intent-chat) reads the resulting digest to
# check the diff against the real building intent — unmet asks, reversed
# decisions, constraints stated in chat but violated in code — signal that
# lives nowhere in the diff or the PR description.
#
# Standalone use (it's a normal CLI, not just an ai-review internal):
#   claude-chats.sh find                 # ranked relevant sessions for this repo
#   claude-chats.sh find --json          # machine-readable ranking
#   claude-chats.sh digest               # intent digest (markdown) to stdout
#   claude-chats.sh digest --out FILE    # write the digest to FILE
#   claude-chats.sh show <session-id>    # digest a single session
#
# Options:
#   --repo PATH          repo to analyze        (default: $REPO_ROOT or git root of cwd)
#   --max-sessions N     sessions in the digest  (default: 4)
#   --max-user N         user asks per session   (default: 12)
#   --max-asst N         assistant blocks/session (default: 8)
#   --days N             ignore transcripts older than N days (default: 30; 0 = no limit)
#   --profiles "a b"     CLAUDE_CONFIG_DIRs to scan (default: ~/.claude plus ~/.claude-*)
#
# PRIVACY: a digest feeds your conversation (user asks + assistant intent
# text, tool I/O stripped) to whatever backend the reviewer runs on. If that
# profile points at a third-party or self-hosted model, this content leaves
# for that backend. Scope --days / --max-* down for sensitive repos.

set -uo pipefail

REPO="${REPO_ROOT:-}"
MAX_SESSIONS=4
MAX_USER=12
MAX_ASST=8
DAYS=30
PROFILES=""
CMD="${1:-digest}"
shift || true
OUT=""
JSON=0
SESSION_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --max-sessions) MAX_SESSIONS="$2"; shift 2 ;;
    --max-user) MAX_USER="$2"; shift 2 ;;
    --max-asst) MAX_ASST="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --profiles) PROFILES="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -*) echo "claude-chats: unknown option $1" >&2; exit 2 ;;
    *) SESSION_ID="$1"; shift ;;
  esac
done

# Resolve the repo root (and thus every worktree's path) from cwd if unset.
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
fi
if [ -z "$REPO" ]; then
  echo "claude-chats: not inside a git repo and no --repo given." >&2
  exit 2
fi

# Default profiles: the main config dir plus every sibling ~/.claude-*
# profile, so transcripts from delegated agents are included too.
if [ -z "$PROFILES" ]; then
  PROFILES="$HOME/.claude"
  for d in "$HOME"/.claude-*; do [ -d "$d/projects" ] && PROFILES="$PROFILES $d"; done
fi

# Worktree paths for this repo — each maps to its own projects/<slug> dir, so a
# change made in a worktree (ai-review's common case) is still found.
WORKTREES="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')"
[ -z "$WORKTREES" ] && WORKTREES="$REPO"

BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

# Changed files vs the most plausible base — a soft relevance signal only.
CHANGED=""
for base in "@{upstream}" origin/dev origin/main dev main; do
  if git -C "$REPO" rev-parse --verify -q "$base" >/dev/null 2>&1; then
    mb="$(git -C "$REPO" merge-base "$base" HEAD 2>/dev/null || echo "")"
    [ -n "$mb" ] && CHANGED="$(git -C "$REPO" diff --name-only "$mb"...HEAD 2>/dev/null)" && break
  fi
done

export CC_PROFILES="$PROFILES" CC_WORKTREES="$WORKTREES" CC_BRANCH="$BRANCH" \
  CC_CHANGED="$CHANGED" CC_MAX_SESSIONS="$MAX_SESSIONS" CC_MAX_USER="$MAX_USER" \
  CC_MAX_ASST="$MAX_ASST" CC_DAYS="$DAYS" CC_CMD="$CMD" CC_JSON="$JSON" \
  CC_SESSION_ID="$SESSION_ID" CC_REPO="$REPO"

run_python() {
python3 - <<'PY'
import json, os, sys, time, glob, re

profiles = os.environ["CC_PROFILES"].split()
worktrees = [w for w in os.environ["CC_WORKTREES"].split("\n") if w.strip()]
branch = os.environ.get("CC_BRANCH", "").strip()
changed = [c for c in os.environ.get("CC_CHANGED", "").split("\n") if c.strip()]
max_sessions = int(os.environ["CC_MAX_SESSIONS"])
max_user = int(os.environ["CC_MAX_USER"])
max_asst = int(os.environ["CC_MAX_ASST"])
days = int(os.environ["CC_DAYS"])
cmd = os.environ["CC_CMD"]
as_json = os.environ["CC_JSON"] == "1"
want_session = os.environ.get("CC_SESSION_ID", "").strip()
repo = os.environ["CC_REPO"]

changed_bases = {os.path.basename(c) for c in changed if c}
now = time.time()
cutoff = now - days * 86400 if days > 0 else 0


def slug(path):
    # Claude Code encodes a cwd as projects/<path-with-slashes-as-dashes>.
    return path.replace("/", "-")


# Worktree path variants: the literal path AND its realpath. Claude Code slugs
# the cwd as-recorded, which may be a symlinked alias (the user symlinks a lot),
# so match both so a session opened via either path resolves.
wt_paths = []
_seen_wt = set()
for wt in worktrees:
    for p in (wt, os.path.realpath(wt)):
        if p and p not in _seen_wt:
            _seen_wt.add(p)
            wt_paths.append(p)

# Candidate transcript dirs: every (profile x worktree-slug) that exists.
cand_dirs = []
for prof in profiles:
    for wt in wt_paths:
        d = os.path.join(prof, "projects", slug(wt))
        if os.path.isdir(d):
            cand_dirs.append((prof, wt, d))

files = []
seen_real = set()  # sibling profiles symlink projects/ into ~/.claude — dedupe by realpath.
for prof, wt, d in cand_dirs:
    for f in glob.glob(os.path.join(d, "*.jsonl")):
        real = os.path.realpath(f)
        if real in seen_real:
            continue
        seen_real.add(real)
        try:
            mt = os.path.getmtime(f)
        except OSError:
            continue
        if cutoff and mt < cutoff:
            continue
        files.append({"path": f, "profile": prof, "worktree": wt, "mtime": mt})


def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text")
    return ""


SKIP_USER_PREFIXES = ("<", "[Request interrupted", "Caveat:", "This session is being continued",
                      "# /", "Base directory for this skill", "## Input", "<command")
# Slash-command / skill bodies get recorded as user turns — they are harness
# injections, not the human's intent. Drop anything that smells like one.
SKIP_USER_CONTAINS = ("Base directory for this skill:", "# /loop", "## Core principle")
# API-error echoes the assistant emits as plain text — pure noise.
SKIP_ASST_EXACT = {"Prompt is too long", "(no content)"}


def parse(path):
    """Return (user_asks, assistant_blocks, n_rows). Tool I/O and system noise dropped."""
    users, assts, n = [], [], 0
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                n += 1
                t = row.get("type")
                if t == "user":
                    msg = row.get("message", {})
                    # Drop tool_result turns (content is a list of tool_result dicts).
                    cont = msg.get("content")
                    if isinstance(cont, list) and any(isinstance(p, dict) and p.get("type") == "tool_result" for p in cont):
                        continue
                    txt = text_of(msg).strip()
                    if txt and not txt.startswith(SKIP_USER_PREFIXES) and not any(s in txt[:120] for s in SKIP_USER_CONTAINS):
                        users.append(txt)
                elif t == "assistant":
                    txt = text_of(row.get("message", {})).strip()
                    if txt and txt not in SKIP_ASST_EXACT:
                        assts.append(txt)
    except OSError:
        pass
    return users, assts, n


def score(meta, users, assts):
    blob = ("\n".join(users) + "\n" + "\n".join(assts)).lower()
    s = 0.0
    if branch and branch.lower() in blob:
        s += 5
    s += sum(1 for b in changed_bases if b.lower() in blob)
    # Recency: newer wins, gently (max ~3).
    age_days = (now - meta["mtime"]) / 86400
    s += max(0.0, 3.0 - age_days / 7.0)
    s += min(2.0, len(users) * 0.1)  # conversations with real asks over tool-only runs
    return s


sessions = []
for meta in files:
    if want_session and want_session not in os.path.basename(meta["path"]):
        continue
    users, assts, n = parse(meta["path"])
    if not users and not assts:
        continue
    meta = dict(meta, users=users, assts=assts, rows=n,
                sid=os.path.basename(meta["path"]).replace(".jsonl", ""))
    meta["score"] = score(meta, users, assts)
    sessions.append(meta)

sessions.sort(key=lambda m: (m["score"], m["mtime"]), reverse=True)
if not want_session:
    sessions = sessions[:max_sessions]


def stamp(mt):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(mt))


def trunc(s, n):
    s = " ".join(s.split())
    return s if len(s) <= n else s[:n] + " […]"


if cmd == "find":
    if as_json:
        print(json.dumps([{k: m[k] for k in ("sid", "profile", "worktree", "score", "rows", "mtime")} for m in sessions], indent=2))
    else:
        if not sessions:
            print("No Claude Code transcripts found for this repo.")
        for m in sessions:
            print(f"{m['score']:5.1f}  {stamp(m['mtime'])}  {m['sid']}")
            print(f"        profile={os.path.basename(m['profile'])}  worktree={m['worktree']}  asks={len(m['users'])} rows={m['rows']}")
    sys.exit(0)

# digest / show -> markdown
out = []
out.append("# Claude Code build intent (mined from session transcripts)")
out.append("")
out.append(f"Repo `{repo}` · branch `{branch or '(unknown)'}` · "
           f"{len(sessions)} session(s) · profiles scanned: "
           f"{', '.join(os.path.basename(p) for p in profiles)}.")
out.append("")
out.append("_What the human asked for and what the assistant decided, in the "
           "conversations that produced these changes. Tool calls, file dumps, "
           "and system messages are stripped. Use this to judge the diff against "
           "stated intent — not as ground truth (a chat can be wrong or superseded)._")
out.append("")
if not sessions:
    out.append("No matching transcripts found. Skip the intent-vs-chat angle this run.")
else:
    for m in sessions:
        out.append(f"## Session `{m['sid']}` — {stamp(m['mtime'])} "
                   f"(profile {os.path.basename(m['profile'])}, score {m['score']:.1f})")
        out.append("")
        out.append("### Human asks (verbatim, truncated)")
        for u in m["users"][:max_user]:
            out.append(f"- {trunc(u, 500)}")
        if len(m["users"]) > max_user:
            out.append(f"- _(+{len(m['users']) - max_user} more asks)_")
        out.append("")
        out.append("### Assistant intent / decisions (truncated)")
        # Bias to the LAST assistant blocks — summaries/decisions land near the end.
        for a in m["assts"][-max_asst:]:
            out.append(f"- {trunc(a, 600)}")
        out.append("")

text = "\n".join(out)
dest = os.environ.get("CC_OUT", "")
if dest:
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(text + "\n")
    print(f"wrote {dest}")
else:
    print(text)
PY
}

CC_OUT="$OUT" run_python
