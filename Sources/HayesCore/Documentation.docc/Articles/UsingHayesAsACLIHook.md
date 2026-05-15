# Using Hayes as a CLI hook

Wire `hayes recall` into Claude Code's `UserPromptSubmit` hook and
`hayes assess` into a `Stop`-hook or nightly cron.

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
  in a nightly cron over an archive of past transcripts.

Both commands default their `--session-id` / transcript identity to the
transcript filename stem. For a Claude Code JSONL transcript that stem
is the harness-native session UUID, so the live recall path and the
offline assess path agree on identity without any extra flag plumbing.
That's what makes [`hayes session show`](#Inspecting-a-session) work
the way users expect.

## Wiring `hayes recall` into `UserPromptSubmit`

Claude Code passes the transcript path and session UUID to hooks as
environment variables. The minimal hook is one line:

```bash
hayes recall "$TRANSCRIPT_PATH" --session-id "$SESSION_ID"
```

The hook's stdout is appended to the user's prompt as Hayes-surfaced
context. The `--session-id` argument is redundant for Claude Code (the
transcript filename stem already *is* the session UUID), but stating it
explicitly makes the contract obvious and survives a harness that names
its transcripts differently.

### Tunables on the hot path

- `--context-extractor` selects the LLM for the pre-retrieval inference
  step. Defaults to `afm` because the extractor is small and AFM's
  on-device latency is dominated by IPC, not generation. Use
  `--context-extractor anthropic` when AFM isn't available; use
  `--context-extractor none` to skip the LLM entirely and fall back to
  the last user message verbatim — the right choice for CI or batch
  imports where you don't want to spend tokens on inference.
- `--window` controls how many trailing transcript messages the
  extractor sees (default 5).
- `--dry-run` runs retrieval without persisting to `session_injections`
  and prints what *would* have been skipped as already-injected.
- `--json` switches the output to a machine-readable payload — useful
  when the harness wants structured data instead of pasting plaintext
  into the prompt.

## Wiring `hayes assess` into `Stop` (or cron)

A `Stop` hook fires once when the agent's turn ends. The minimal
invocation is:

```bash
hayes assess "$TRANSCRIPT_PATH"
```

Same identity convention: the transcript filename stem is the session
UUID, so the edges written here will line up with the injections
recorded by `hayes recall`. To batch-process an archive instead, drop
the hook and run from cron:

```bash
hayes assess ~/.claude/projects/*/conversation-*.jsonl
```

The shell expands the glob; `hayes assess` processes each transcript in
turn and prints a per-file lesson count followed by a total.

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
