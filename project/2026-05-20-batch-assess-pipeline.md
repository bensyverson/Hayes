# Batch-API assess pipeline — design

**Status:** design (spike `gEnbW`, epic `q6PcE`) · 2026-05-20
**Depends on:** assess idempotency / `assess_progress` (epic `leNJl`, shipped commit `f03879b`)

## Goal

For heavy Claude-Code-style turns the Anthropic **Message Batches API**'s
flat 50% discount dwarfs prompt caching (see
`project_analyzer_prefix_caching` — caching is on but inert on the default
Haiku model). Batch SLA is 24h but usually minutes; assess is not the hot
path, so a ~1-turn delay before a lesson lands is acceptable. We keep the
per-turn trigger and the no-daemon rule: all work happens inside ordinary
hook/CLI invocations driven off durable state.

Anthropic-only. AFM stays on the live synchronous per-turn path. Batch is
layered on the Anthropic backend as an opt-in.

## What exists vs. what's missing

- **Reusable.** `LLM.OpenAICompatibleAPI.ChatCompletion` is `Codable` and
  its `encode(to:)` already emits the Anthropic Messages request body
  (system blocks with `cache_control`, anthropic tool format, anthropic
  messages). That body is exactly what each batch request's `params`
  needs. `AnalysisInput` is `ToolInput`/`Codable`, so a batch result's
  `tool_use.input` JSON decodes straight into it, then `.toAnalysisResult()`.
  `assess_progress` + the persist/reinforce path already exist.
- **Missing.** Neither `LLM` nor `Operator` has any Message Batches
  support (only tool-call *batching* inside the live loop). The live
  analyzer reaches Anthropic through the streaming `Operative` loop, which
  is the wrong shape for batch. We must add: a tiny Anthropic batch HTTP
  client, a way to build the request body without running `Operative`, a
  result→`AnalysisResult` parser, the `pending_batches` table, and
  `reconcile()`.

## Core model: no queue, durable-state reconcile

The only new explicit state is a small `pending_batches` table. The
"backlog" is implicit: **turns beyond `assess_progress` that aren't
covered by a pending batch.** Everything is driven by one idempotent
function, `reconcile()`, callable at any opportunity; it always derives
what to do from durable state, so it tolerates missed events and the
Claude Code / OpenCode event asymmetry.

### `pending_batches` schema

```
pending_batches(
  batch_id     TEXT PRIMARY KEY,   -- Anthropic batch id (msgbatch_…)
  transcript   TEXT NOT NULL UNIQUE,  -- one in-flight batch per transcript
  min_turn     INTEGER NOT NULL,   -- inclusive backlog range covered
  max_turn     INTEGER NOT NULL,
  submitted_at REAL NOT NULL
)
```

`UNIQUE(transcript)` enforces **at most one in-flight batch per
transcript**. That invariant is what keeps `assess_progress` (a single
high-water mark) sound: a transcript never has two overlapping or
out-of-order batches, so collection can advance the mark contiguously
with no holes.

### `reconcile(transcripts:)`

Two phases, collection before submission:

1. **Collect (global, cheap).** For every row in `pending_batches`, GET
   the batch status. If `ended`, fetch its `results_url` (JSONL), and for
   each result, **in ascending `custom_id` (turn index) order**:
   - on a `succeeded` result: decode `tool_use.input` → `AnalysisInput`
     → `AnalysisResult`, ingest it for that turn via the shared
     reinforce/persist path (same dedup, `reinforceEdge`, provenance with
     `turn_index` from `custom_id`).
   - **stop at the first non-`succeeded` result.** Advance
     `assess_progress` to the last *contiguous* succeeded turn from
     `min_turn`; drop the `pending_batches` row. Any turns at/after the
     gap re-enter the backlog and get resubmitted next pass. (Anthropic
     per-request failures inside an ended batch are rare; discarding a
     succeeded tail past a gap trades a little wasted work for the
     no-holes / no-double-reinforce invariant. Reinforcement is EMA —
     *not* idempotent per edge — so the high-water mark, not re-running,
     is what guarantees once-only counting.)
   - if a batch is `canceled`/`expired`/`errored` as a whole: drop the
     row without advancing; the range re-enters the backlog.
2. **Submit (per transcript in `transcripts`).** For each transcript with
   **no** pending row, compute backlog = turns with index >
   `assess_progress`. If non-empty, build one batch request per backlog
   turn (`custom_id = String(turnIndex)`, `params` = the analyzer
   `ChatCompletion` body for that turn), POST a single batch covering the
   whole `[min..max]` range, and insert the `pending_batches` row. If the
   transcript already has a pending row, skip (its batch is in flight).

`reconcile()` is non-blocking and silent-degrading: network/credential
failure logs and returns; nothing is lost because state is durable.

## Resolved open questions

- **One-batch-per-turn vs accumulate-then-submit.** Resolved as a third
  option: **one batch per transcript per `reconcile` submit, covering the
  whole current backlog range** (1 request on a steady per-Stop cadence,
  N requests on a session-start catch-up). No time-based buffering, no
  queue. Cache utilization is *not* a deciding factor — the prefix is
  below Haiku's cache minimum regardless (`project_analyzer_prefix_caching`).
- **Session-start scan horizon.** **Collection is always global**
  (it's just a `pending_batches` scan). **Submission at session start is
  scoped to the current transcript only.** The wide backlog sweep is the
  cron's job (the existing archive glob), keeping session start fast and
  bounded.

## Triggers (per `iD6bE`)

`reconcile()` runs, non-blocking, at every opportunity — each derives the
right action from state:

- **Session start** — primary collect + current-transcript catch-up:
  Claude Code `SessionStart`, OpenCode `session.created`.
- **Per-turn idle/Stop** — submit (optional): CC `Stop`, OpenCode
  `session.idle`. Usually finds a pending batch and just collects.
- **Cron backstop** — global collect + backlog submit over the archive
  glob; sweeps tails for transcripts that never reopen and the 24h worst
  case.
- **CC `SessionEnd`** — bonus submit. OpenCode has no analogue; durable
  state covers the asymmetry.

## CLI / backend split

- AFM backend: `hayes assess` unchanged (live synchronous).
- Anthropic backend: add **`hayes assess --batch`** = one `reconcile()`
  pass (collect globally, submit the given transcript(s)). Default stays
  live/synchronous; `--batch` is the explicit opt-in the hooks pass.
  (Alternative considered: make batch automatic on the Anthropic backend.
  Rejected for the spike — it silently removes synchronous assess; opt-in
  is clearer for green-field.) The cron form is `hayes assess --batch <glob>`.

## New components (feasibility confirmed)

- **`AnthropicBatchClient`** (HayesCore, `URLSession` — no new dependency):
  `submit(requests:) -> batchID`, `status(batchID:)`, `results(batchID:)
  -> [(customID, Result)]`. Reuses the api key + `https://api.anthropic.com`
  + `anthropic-version` header (mirrors `LLM.Provider.anthropic`). Add the
  message-batches beta header if required at impl time.
- **Request-body seam (via a new public Operator API).** Operator is a
  local path dependency we own, so rather than re-deriving the tool schema
  outside the loop, add a public seam on `Operative` that returns the exact
  request it *would* send for a given user message — e.g.
  `public func requestBody(for userMessage: String, provider: LLM.Provider)
  -> LLM.OpenAICompatibleAPI.ChatCompletion`, which internally does what
  `run()` does (`config.tools = toolDefinitions`; build the `Conversation`;
  `conversation.request(for: provider)`). The batch path then builds the
  identical analyzer request by constructing the same `Operative`
  `AnalysisRunner.makeOperative` builds and calling `requestBody(...)`,
  encoding the result as the batch `params`. This guarantees live and batch
  request shapes can't drift (single source of truth) with no schema
  re-extraction. (Minimal alternative if we'd rather not add a method: make
  `Operative.toolDefinitions` public and build the `Conversation` in
  `AnalysisRunner`. The `requestBody` seam is cleaner.)
- **Result parser.** Extract the `submit_analysis` `tool_use` block from a
  result message's content and decode `input` → `AnalysisInput`.
- **`GraphStore+PendingBatches`** + **`AssessService` ingest seam.** Expose
  a reusable "ingest analyzed turns for a transcript" entrypoint (the
  current `persist` + `advanceAssessProgress`, refactored out of `assess`)
  so the batch collector reinforces identically to the live path.

## Follow-on impl tasks

This refines the epic's pre-spike children (`wLPA9`, `iD6bE`): the spike
splits `wLPA9`'s "client" and "reconcile core" into two leaves so each is a
shippable TDD increment. The block below is `job import`-ready (the first
fenced YAML block keyed `tasks`); it's the canonical breakdown — re-import
into a fresh tracker, or use it to reconcile the existing rows. The
existing `wLPA9`/`iD6bE` IDs stay valid if you'd rather just work them in
place against this design.

```yaml
tasks:
  - title: Batch-API assess path — implementation
    desc: Anthropic-only batch path layered on the existing assess pipeline, per project/2026-05-20-batch-assess-pipeline.md. AFM stays on the live synchronous path. Builds on the shipped assess_progress idempotency work.
    labels: [enhancement]
    children:
      - title: AnthropicBatchClient + analyzer request-body seam + result parser
        ref: batch-client
        labels: [enhancement]
        desc: Add a small AnthropicBatchClient (Foundation URLSession, no new dependency) with submit(requests:)->batchID, status(batchID:), and results(batchID:)->[(customID, Result)], reusing the api key, https://api.anthropic.com base URL, and anthropic-version header (add the message-batches beta header if required at impl time). Add a public Operative.requestBody(for:provider:)->ChatCompletion seam in the Operator package (we own it) that does what run() does internally, so the batch path reuses the EXACT live analyzer request and the two can't drift; centralize the call in AnalysisRunner. Add a result parser that extracts the submit_analysis tool_use block from a result message and decodes its input into AnalysisInput. Strict TDD against a stubbed HTTP layer.
      - title: pending_batches table + reconcile() core + AssessService ingest seam
        ref: reconcile-core
        blockedBy: [batch-client]
        labels: [enhancement]
        desc: Add pending_batches(batch_id PK, transcript UNIQUE, min_turn, max_turn, submitted_at) with GraphStore accessors. Refactor AssessService so the persist + advanceAssessProgress logic is a reusable ingest-analyzed-turns entrypoint shared by the live and batch paths. Implement reconcile(transcripts:) — collect globally (contiguous ingest from min_turn, stop at first non-succeeded result, advance assess_progress to the last contiguous success, drop the row; whole-batch failure re-enqueues without advancing), then submit each transcript's backlog (turns beyond assess_progress) as one batch with custom_id = turn index, skipping transcripts that already have a pending row. Anthropic-gated. Strict TDD with a mock batch client — assert submit-skips-when-pending, contiguous collect + progress advance, gap handling, and whole-batch failure re-enqueues.
      - title: --batch CLI flag + wire reconcile() triggers across CC and OpenCode + cron
        ref: wiring
        blockedBy: [reconcile-core]
        labels: [enhancement]
        desc: Add `hayes assess --batch` (one reconcile pass — global collect plus submit the given transcripts), defaulting off so live stays the default. Wire reconcile() triggers, non-blocking and silent-degrading, derived from durable state — CC SessionStart / OpenCode session.created (primary collect + current-transcript catch-up), CC Stop / OpenCode session.idle (optional submit), a cron backstop over the archive glob (wide sweep + 24h tail), and CC SessionEnd (bonus submit). Update the plugin hooks.json, the OpenCode plugin .ts, and UsingHayesAsACLIHook.md.
```
