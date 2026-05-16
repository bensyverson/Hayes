# cache-trace-proxy

A diagnostic pass-through proxy for the Anthropic API. It forwards every request
to `https://api.anthropic.com` untouched (streaming responses included), but tees
each `POST /v1/messages` request body to disk so you can inspect exactly where
`cache_control` breakpoints land across the successive requests of a multi-step
tool-calling turn.

## Why

To answer: during one agent turn with several tool-call round trips, does the
harness re-place a rolling `cache_control` breakpoint on *every* intra-turn
request, or only at turn boundaries? That determines whether intra-turn tool
content gets cached incrementally or reprocessed.

## Run

```sh
cd scripts/cache-trace-proxy
go run .
```

In another shell:

```sh
ANTHROPIC_BASE_URL=http://localhost:8787 claude
```

Run one tool-heavy turn, then inspect:

- `captures/req-NNN.json` — pretty-printed request bodies, in order.
- stdout — one line per request summarizing where `cache_control` appears.

Diff consecutive captures (`diff captures/req-001.json captures/req-002.json`)
to watch the breakpoint roll forward — or not.

## Notes

- Plain HTTP to localhost, so no TLS/cert setup is needed.
- Auth headers are forwarded as-is; the proxy never inspects or stores them.
- `captures/` is regenerated on each run; request numbering resets when the
  proxy restarts.
