#!/usr/bin/env bash
# Stop hook: read the transcript path off stdin, run `hayes assess` to
# distil lessons from the completed turn and reinforce graph edges.
#
# Output is suppressed because Stop has no documented injection path;
# the hook just needs to run. Failures are swallowed so a broken assess
# can't keep the session from ending.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

hayes_bin="${CLAUDE_PLUGIN_ROOT:-}/bin/hayes"
if [[ ! -x "$hayes_bin" ]]; then
    exit 0
fi

payload=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$payload")

if [[ -z "$transcript" ]]; then
    exit 0
fi

"$hayes_bin" assess "$transcript" >/dev/null 2>&1 || true
