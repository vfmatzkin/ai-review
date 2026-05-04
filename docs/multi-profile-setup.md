# Multi-profile setup

ai-review always invokes the `claude` binary. To use different accounts
or backends in different repos, point `AI_PROFILE_DIR` at the right
Claude config dir for each one.

This page documents the maintainer's working setup as a concrete example.
Adapt to your own backends.

## The pattern

[Claude Code](https://docs.claude.com/en/docs/claude-code/) reads its
session state, MCP server list, and credentials from `CLAUDE_CONFIG_DIR`
(default: `~/.claude`). You can keep multiple parallel profiles by
pointing the env var at different directories before calling `claude`.

ai-review wires this up automatically: it sets `CLAUDE_CONFIG_DIR=$AI_PROFILE_DIR`
when it spawns each reviewer.

## The maintainer's setup

The author runs three Claude profiles on the same machine:

| Profile dir              | Backend                                        | Shell alias |
|--------------------------|------------------------------------------------|-------------|
| `~/.claude`              | Anthropic API (default)                        | `claude`    |
| `~/.claude-alibaba`      | Alibaba DashScope, via a local adapter on :3082 | `claudea`   |
| `~/.claude-qwen`         | Qwen direct (used at work)                     | `claudeq`   |

The `claudea` / `claudeq` shell functions look roughly like:

```bash
claudea() {
  # Spin up the local adapter if it isn't already listening.
  if ! lsof -i :3082 -sTCP:LISTEN -t &>/dev/null; then
    tmux new-session -d -s cc-adapter-alibaba 'node ~/.claude-adapter-alibaba/server.js'
    # ...wait for it...
  fi
  CLAUDE_CONFIG_DIR=$HOME/.claude-alibaba claude "$@"
}

claudeq() {
  CLAUDE_CONFIG_DIR=$HOME/.claude-qwen claude "$@"
}
```

**ai-review does not call `claudea`/`claudeq`.** It always calls plain
`claude`. The aliases exist only for interactive use.

To get the same behavior under ai-review, the author's per-repo
`.ai-review/config` files set:

```bash
# personal repo (uses Alibaba/Qwen via the adapter)
AI_CMD=claudea
AI_PROFILE_DIR=$HOME/.claude-alibaba
AI_MODEL=qwen3.6-plus
AI_PRELAUNCH='lsof -i :3082 -t >/dev/null || tmux new-session -d -s cc-adapter-alibaba "node $HOME/.claude-adapter-alibaba/server.js"'
```

```bash
# work repo (uses Qwen direct, no adapter)
AI_CMD=claudeq
AI_PROFILE_DIR=$HOME/.claude-qwen
```

`AI_CMD` is just a label — it shows up in logs and in
`ai-review --status`, but ai-review still calls `claude` either way.
The profile dir is what actually changes the backend.

## Adapting this

If you only have one Claude profile, you don't need any of this — the
defaults (`AI_PROFILE_DIR=$HOME/.claude`, `AI_CMD=default`) work as-is.

If you have multiple, set `AI_PROFILE_DIR` per repo (or globally in
`~/.config/ai-review/config`). Use `AI_PRELAUNCH` for any setup the
profile needs that isn't already running.

## Why a label at all?

Without `AI_CMD`, the run registry (`ai-review --status`) couldn't tell
you which backend produced which review. With it, `--status` shows
`cmd: claudeq` and you know whether the review came out of your work
account or your personal one.
