#!/usr/bin/env bash
# Build the hayes release binary for local plugin development.
#
# The plugins no longer ship a committed binary — at runtime they fetch it
# from the GitHub release via plugin/hooks/lib/ensure-hayes.sh. For local
# testing against an unreleased version, build here and export HAYES_BIN so
# the bootstrap's escape hatch uses your fresh binary instead of downloading.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building hayes (release)..."
swift build -c release

binary="$(pwd)/.build/release/hayes"
echo "==> Built $binary ($(du -h "$binary" | cut -f1))"
echo
echo "Test locally — export the binary so the plugin bootstrap uses it:"
echo
echo "  export HAYES_BIN=\"$binary\""
echo "  claude --plugin-dir ./plugin          # Claude Code"
echo "  # or copy ./opencode-plugin/hayes.ts into ~/.config/opencode/plugin/  # OpenCode"
