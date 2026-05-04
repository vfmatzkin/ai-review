#!/usr/bin/env bash
# ai-review installer.
#
# Copies bin/ai-review to ~/.local/bin and share/ to ~/.local/share/ai-review.
# Idempotent — safe to re-run after pulling updates.
#
# Usage:
#   ./install.sh                # default prefix: ~/.local
#   PREFIX=/usr/local sudo ./install.sh

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
SRC="$(cd "$(dirname "$0")" && pwd)"

BIN="$PREFIX/bin"
SHARE="$PREFIX/share/ai-review"
CONFIG="$HOME/.config/ai-review"

echo "Installing ai-review to:"
echo "  bin:    $BIN/ai-review"
echo "  share:  $SHARE/"
echo "  config: $CONFIG/  (created if missing)"
echo ""

mkdir -p "$BIN" "$SHARE" "$CONFIG/apps"

install -m 0755 "$SRC/bin/ai-review" "$BIN/ai-review"

# share/ — replace, don't merge (keeps the upstream tree clean).
rm -rf "$SHARE/lib" "$SHARE/pipeline" "$SHARE/reviewers.default" "$SHARE/helpers"
cp -R "$SRC/share/lib" "$SHARE/"
cp -R "$SRC/share/pipeline" "$SHARE/"
cp -R "$SRC/share/reviewers.default" "$SHARE/"
cp -R "$SRC/share/helpers" "$SHARE/"
# Use find rather than globbing — bash's globs expand to themselves on
# no-match under set -e and abort the install.
find "$SHARE/pipeline" "$SHARE/reviewers.default" "$SHARE/helpers" \
  -type f -name '*.sh' -exec chmod +x {} +

# Seed an example config only if the user doesn't have one.
if [ ! -f "$CONFIG/config" ]; then
  cp "$SRC/examples/config.example" "$CONFIG/config"
  echo "  seeded $CONFIG/config (edit to taste)"
fi

echo ""
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "WARNING: $BIN is not on your PATH. Add it to your shell rc:"
     echo "    export PATH=\"$BIN:\$PATH\""
     echo "" ;;
esac

# Optional: warn if the cryptography package isn't installed (only needed
# for App-based posting).
if ! python3 -c 'import cryptography' >/dev/null 2>&1; then
  echo "Note: Python 'cryptography' package not found."
  echo "  Required only if you post reviews under a GitHub App identity."
  echo "  Install with: python3 -m pip install --user cryptography"
  echo ""
fi

echo "Done. Then:"
echo "  cd <some-repo-with-an-open-PR>"
echo "  ai-review"
echo ""
echo "First run in a repo enters an interactive setup wizard."
