#!/usr/bin/env bash
# UserPromptSubmit hook: read the transcript + session id off stdin,
# run `hayes recall`, and emit the documented JSON injection envelope.
#
# Failure modes are silent on purpose: a hook that breaks shouldn't
# break the agent's turn. Missing binary, jq error, or recall fault
# all degrade to "no recalled context this turn."

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
session=$(jq -r '.session_id // empty' <<<"$payload")

if [[ -z "$transcript" || -z "$session" ]]; then
    exit 0
fi

context=$("$hayes_bin" recall "$transcript" --session-id "$session" 2>/dev/null || true)

if [[ -z "$context" ]]; then
    exit 0
fi

jq -n --arg ctx "$context" '{
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $ctx
    }
}'
