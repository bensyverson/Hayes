# Using Hayes as a CLI hook

Wire `hayes recall` into Claude Code's `UserPromptSubmit` hook and
`hayes assess` into a `Stop`-hook or nightly cron. The same two commands
back the OpenCode plugin, which reads OpenCode's session database instead
of a JSONL transcript.

## Overview

Hayes is built so the live retrieval path and the offline distillation
path are two separate command invocations against the same SQLite graph.
The harness is responsible for firing them at the right moments; Hayes
is responsible for everything that happens once it's invoked.

The split is:

- **`hayes recall`** is the hot-path command. The harness invokes it on
  every user turn, before the agent generates. It loads the transcript,
  embeds the recent context, queries the graph, and prints the surfaced
  `(seed, behavior)` pairs to stdout for the harness to inject.
- **`hayes assess`** is the offline command. It reads a completed
  transcript, distils ``Lesson``s, and reinforces edges in the graph. It
  can run on a `Stop` hook so the session's signal lands immediately, or
  in a nightly cron over an archive of past transcripts. Assessment is
  idempotent per transcript — it only processes turns it hasn't seen
  before — so the hook and the cron compose without double-counting (see
  [Incremental assessment and backfill](#Incremental-assessment-and-backfill)).

Both commands default their `--session-id` / transcript identity to the
transcript filename stem. For a Claude Code JSONL transcript that stem
is the harness-native session UUID, so the live recall path and the
offline assess path agree on identity without any extra flag plumbing.
That's what makes [`hayes session show`](#Inspecting-a-session) work
the way users expect.

The transcript *source* depends on the harness. Claude Code writes one
JSONL file per session, which the loader auto-detects. OpenCode instead
stores every session in a single SQLite database (`opencode.db`); pass
`--format opencode` and an explicit `--session-id` to read it (see
[Wiring into OpenCode](#Wiring-into-OpenCode)).

## Wiring `hayes recall` into `UserPromptSubmit`

Claude Code passes hook data as a JSON document on the hook's
**stdin** — *not* as environment variables. For `UserPromptSubmit` the
shape is:

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/directory",
  "permission_mode": "default",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "User's prompt text"
}
```

The output contract is the inverse: the hook should print a JSON
document to stdout, and Claude Code injects the value of
`hookSpecificOutput.additionalContext` into the prompt as recalled
context. That's the only documented injection path — relying on
"plain stdout gets appended" is undocumented, version-dependent
behaviour and should be avoided in production hooks.

A minimal `UserPromptSubmit` hook script that ties Hayes's framed
plaintext to the documented JSON envelope:

```bash
#!/usr/bin/env bash
set -euo pipefail
payload=$(cat)
transcript=$(jq -r '.transcript_path' <<<"$payload")
session=$(jq -r '.session_id'      <<<"$payload")
prompt=$(jq -r '.prompt // empty'  <<<"$payload")

args=(recall "$transcript" --session-id "$session")
[[ -n "$prompt" ]] && args+=(--prompt "$prompt")
context=$(hayes "${args[@]}")

jq -n --arg ctx "$context" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
```

`--session-id` is redundant for Claude Code (the transcript filename
stem already *is* the session UUID) but passing it makes the contract
explicit and survives a harness that names its transcripts differently.

`--prompt` matters more than it looks: `UserPromptSubmit` fires *before*
Claude Code writes the new prompt to the transcript, so without it recall
is grounded in history through the previous turn (and the very first turn
sees nothing). Passing the payload's `prompt` makes recall reflect the
current turn. OpenCode persists the message before its hook fires, so it
is already current-turn and does not need this.

Register the script under the `UserPromptSubmit` event in your
`settings.json` (or a plugin's `hooks/hooks.json`):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/abs/path/to/hayes-recall-hook.sh" }
        ]
      }
    ]
  }
}
```

> The `matcher` field's behaviour for session-level events
> (`UserPromptSubmit`, `Stop`) is not explicitly documented as of this
> writing; `"*"` is the safe default.

### Tunables on the hot path

- `--context-extractor` selects the LLM for the pre-retrieval inference
  step. Defaults to `afm` because the extractor is small and AFM's
  on-device latency is dominated by IPC, not generation. Use
  `--context-extractor anthropic` when AFM isn't available; use
  `--context-extractor none` to skip the LLM entirely and fall back to
  the last user message verbatim — the right choice for CI or batch
  imports where you don't want to spend tokens on inference.
- `--prompt` supplies the in-flight user message out-of-band, appended as
  the trailing user turn. Use it when the harness has the prompt before it
  reaches the transcript (Claude Code's `UserPromptSubmit`) so recall is
  anchored on the current turn rather than the previous one.
- `--window` controls how many trailing transcript messages the
  extractor sees (default 5).
- `--dry-run` runs retrieval without persisting to `session_injections`
  and prints what *would* have been skipped as already-injected.
- `--json` switches the output to a machine-readable payload — useful
  when the harness wants structured data instead of pasting plaintext
  into the prompt.

## Wiring `hayes assess` into `Stop` (or cron)

`Stop` fires once when the agent finishes responding. Its stdin payload
is the same common-fields shape as `UserPromptSubmit`, minus the
`prompt`:

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/directory",
  "permission_mode": "default",
  "hook_event_name": "Stop"
}
```

`Stop` has no documented output contract for prompt injection — it just
needs to run. A minimal hook script:

```bash
#!/usr/bin/env bash
set -euo pipefail
payload=$(cat)
transcript=$(jq -r '.transcript_path' <<<"$payload")
hayes assess "$transcript"
```

Same identity convention as `recall`: the transcript filename stem is
the session UUID, so the edges written here line up with the
injections recorded by the live hook. Register it the same way:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/abs/path/to/hayes-assess-hook.sh", "timeout": 600 }
        ]
      }
    ]
  }
}
```

> `Stop` defaults to a 600-second timeout (much longer than
> `UserPromptSubmit`'s 30 s), so a multi-turn `assess` typically
> finishes in time. Blocking-semantics and retry behaviour for `Stop`
> are not documented — treat it as best-effort and don't depend on it
> for irrecoverable state.

To batch-process an archive instead, drop the hook and run from cron:

```bash
hayes assess ~/.claude/projects/*/conversation-*.jsonl
```

The shell expands the glob; `hayes assess` processes each transcript in
turn and prints a per-file lesson count followed by a total. The cron
path is the more reliable of the two — use it if you can't tolerate
occasional missed sessions.

### Incremental assessment and backfill

`hayes assess` is idempotent at turn granularity. It records the highest
turn index it has assessed for each transcript identity and, on every
later run, analyzes only the turns past that mark. So firing the `Stop`
hook on each turn reinforces that turn's edges exactly once — not the
whole conversation over again — which keeps cost roughly linear in the
session length and stops early turns from being over-weighted by repeated
reinforcement. (One-shot `--strategy` is the exception: it can only track
whether a transcript has been assessed at all, since it analyzes the
whole conversation in a single call.)

That idempotency is what makes a periodic cron a safe *backfill* rather
than a competing writer. The live `Stop` hook keeps the graph current
turn-by-turn, but it can't catch every turn: a session that crashes
before the agent finishes never fires `Stop`, and a non-interactive run
that bypasses hooks entirely leaves no live signal at all. A nightly
cron over the whole archive sweeps those up — and because assess skips
turns it has already processed, pointing it at transcripts the live hook
already handled costs almost nothing and never double-reinforces:

```bash
# nightly: backfill anything the live Stop hook missed
hayes assess ~/.claude/projects/*/conversation-*.jsonl
```

To force a full re-distillation of a transcript — for instance after
changing the analyzer model or prompt, so you want every turn re-judged
— pass `--reassess`, which ignores the stored progress mark and
reprocesses from the first turn.

### AFM vs Anthropic for the analyzer

`hayes recall`'s extractor is happy on AFM — it's producing short
phrases and tolerates a small model. `hayes assess`'s analyzer is a
different shape: it must call a `submit_analysis` tool with structured
arguments, and AFM currently emits that call as fenced JSON text
instead of invoking the tool. That's why `--analyzer` defaults to
`anthropic` on `assess` even though the rest of the pipeline defaults
to AFM. If you switch to `--analyzer afm`, expect to implement a
fence-parsing fallback or accept that some turns will yield zero
lessons.

The `--model` flag pins an explicit Anthropic model identifier (for
example `claude-haiku-4-5`) and is ignored under AFM.

### Other knobs

- `--strategy parallel` (default) issues one analyze call per turn with
  `--concurrency` (default 4) in flight; `--strategy one-shot` sends
  the whole transcript in a single call. Parallel is generally faster
  and produces sharper per-turn lessons; one-shot is cheaper when
  transcripts are short.
- `--no-store-source` leaves `edges.source_transcript` and
  `edges.source_excerpt` NULL. `turn_index` is still recorded, so
  ``Edge/provenance`` remains non-nil with most of its fields null —
  the renderers handle that shape, and downstream code should too.
  Progress tracking is unaffected: assess still records how far it got,
  since that's internal bookkeeping rather than edge provenance.
- `--reassess` ignores the stored per-transcript progress mark and
  reprocesses every turn (see
  [Incremental assessment and backfill](#Incremental-assessment-and-backfill)).

## Wiring into OpenCode

OpenCode plugins are JavaScript/TypeScript modules, not shell hooks, so
the integration is a small `.ts` file (`opencode-plugin/hayes.ts`) rather
than the bash scripts above. It maps OpenCode's plugin surface onto the
same two commands:

- The **`experimental.chat.system.transform`** hook runs `hayes recall`
  before each reply and pushes the framed memories block onto the system
  prompt (`output.system`). This hook receives only `{ sessionID, model }`,
  so the plugin reads the latest user message from `opencode.db` itself.
  Verified against OpenCode 1.15.5: the message is persisted before the hook
  fires, so recall reflects the current turn. The `chat.message` hook (which
  carries the message directly) is the fallback should a future version
  change that ordering.
- The **`session.idle`** event runs `hayes assess` once the agent finishes,
  the analogue of Claude Code's `Stop`.

Both shell out to:

```bash
hayes recall "$OPENCODE_DATA_DIR/opencode.db" --format opencode --session-id "$id"
hayes assess "$OPENCODE_DATA_DIR/opencode.db" --format opencode --session-id "$id"
```

`--session-id` is **required** here: unlike a JSONL transcript, OpenCode's
database holds every session, so there is no filename stem to fall back on.
The parser opens the database read-only where possible (falling back to a
normal connection for WAL-mode databases, which SQLite cannot open
read-only) and only ever issues `SELECT`s, so OpenCode's data is never
modified. It reads the `message` and `part` tables, decoding each row's JSON
`data` column — `text` parts become message text, `tool` parts become tool
calls plus their results, and `reasoning`/`file`/`step-*` parts are dropped.

The plugin downloads and caches the `hayes` binary on first use, exactly
like the Claude Code plugin; see the project README for install steps.

## Inspecting a session

Because `recall` and `assess` share an identity by default, `hayes
session show <session-uuid>` returns the full injection trail for that
conversation:

```bash
hayes session list                    # most recent first
hayes session show <session-uuid>     # the trail Hayes surfaced
hayes session reset <session-uuid>    # clear it
```

If injection persistence isn't wanted at all — say, the harness wants
retrieval semantics without dedup side effects — pass
`--no-store-injection` to `hayes recall`.

## A note on retrieval thresholds

``RetrievalConfig``'s defaults are tuned for populated graphs. A
freshly-seeded graph that contains exactly one `assess` run's worth of
edges will often surface nothing through a stock `recall` because
``RetrievalConfig/minEdgeWeight`` (default 0.1) sits above what a
single reinforcement produces. The fix is to keep accumulating signal,
not to chase the threshold — though for end-to-end smoke tests it's
fine to lower `minEdgeWeight` temporarily.

## Topics

### Related

- <doc:MemoryPipeline>
- <doc:RetrievalAlgorithm>
- <doc:ReinforcementMath>
