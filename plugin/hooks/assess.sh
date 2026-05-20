#!/usr/bin/env bash
# Stop / SessionStart hook: read the transcript path off stdin and run
# `hayes assess --batch` to reconcile the memory graph via the Anthropic
# Message Batches API. One pass collects any ready batches (reinforcing
# completed turns) and submits this transcript's new backlog. Lessons land
# after the batch completes (usually minutes), but recall stays immediate —
# only distillation is deferred, which is where the ~50% batch saving is.
#
# Wired on Stop (submit the just-finished turn, collect prior ones) and
# SessionStart (collect batches from earlier sessions, catch up this one).
#
# Output is suppressed because neither event has a documented injection
# path; the hook just needs to run. Failures are swallowed so a broken
# assess can't keep the session from ending.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# Resolve the hayes binary via the bootstrap, which downloads + caches the
# release binary on first run. Any failure degrades to "assess skipped."
plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
version=$(jq -r '.version // empty' "${plugin_root}/.claude-plugin/plugin.json" 2>/dev/null || true)
[[ -n "$version" ]] || exit 0
hayes_bin=$("${plugin_root}/hooks/lib/ensure-hayes.sh" "$version" 2>/dev/null || true)
if [[ -z "$hayes_bin" || ! -x "$hayes_bin" ]]; then
    exit 0
fi

payload=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$payload")

if [[ -z "$transcript" ]]; then
    exit 0
fi

"$hayes_bin" assess --batch "$transcript" >/dev/null 2>&1 || true
