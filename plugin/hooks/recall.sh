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

# Resolve the hayes binary via the bootstrap, which downloads + caches the
# release binary on first run. Any failure degrades to "no recalled context."
plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
version=$(jq -r '.version // empty' "${plugin_root}/.claude-plugin/plugin.json" 2>/dev/null || true)
[[ -n "$version" ]] || exit 0
hayes_bin=$("${plugin_root}/hooks/lib/ensure-hayes.sh" "$version" 2>/dev/null || true)
if [[ -z "$hayes_bin" || ! -x "$hayes_bin" ]]; then
    exit 0
fi

payload=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$payload")
session=$(jq -r '.session_id // empty' <<<"$payload")
prompt=$(jq -r '.prompt // empty' <<<"$payload")

if [[ -z "$transcript" || -z "$session" ]]; then
    exit 0
fi

# UserPromptSubmit fires before the prompt is written to the transcript, so
# pass it through with --prompt: recall then reflects the current turn (and
# works on the very first turn) instead of lagging one behind.
#
# --warn-missing-anthropic-key: the plugin's assess path is Anthropic-only, so
# if no key is resolvable, distillation is silently dead. Recall is the only
# hook with an injection channel, so it carries that one-line warning.
args=(recall "$transcript" --session-id "$session" --warn-missing-anthropic-key)
[[ -n "$prompt" ]] && args+=(--prompt "$prompt")

context=$("$hayes_bin" "${args[@]}" 2>/dev/null || true)

if [[ -z "$context" ]]; then
    exit 0
fi

jq -n --arg ctx "$context" '{
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $ctx
    }
}'
