#!/usr/bin/env bash
# Build the hayes release binary and stage it inside plugin/bin/ so the
# Claude Code plugin has a working executable on PATH. Run this before
# committing a new plugin/bin/hayes for a release, or before testing
# locally with `claude --plugin-dir ./plugin`.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building hayes (release)..."
swift build -c release

mkdir -p plugin/bin
cp -f .build/release/hayes plugin/bin/hayes
chmod +x plugin/bin/hayes

echo "==> Staged binary at plugin/bin/hayes ($(du -h plugin/bin/hayes | cut -f1))"
echo
echo "Test locally:"
echo "  claude --plugin-dir ./plugin"
