#!/usr/bin/env bash
# Live end-to-end check for the batch assess path (hayes assess --batch).
#
# Confirms the Anthropic Message Batches wire format against the real API:
# a submit that returns a msgbatch_ id proves the request body is accepted;
# a later collect that reinforces edges proves status + results parsing.
#
# Everything runs against a throwaway DB in $TMPDIR, so your real graph at
# ~/.hayes/graph.sqlite is never touched.
#
# Usage:
#   ANTHROPIC_API_KEY=sk-ant-... ./scripts/verify-batch.sh [transcript.jsonl]
#
# With no argument it picks your most recent Claude Code transcript. Batches
# usually finish in minutes; the script polls (re-running the reconcile,
# which collects ready batches first) until the pending batch drains or the
# timeout is hit.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "error: set ANTHROPIC_API_KEY first." >&2
    exit 1
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "error: sqlite3 is required." >&2
    exit 1
fi

transcript="${1:-}"
if [[ -z "$transcript" ]]; then
    transcript=$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1 || true)
fi
if [[ -z "$transcript" || ! -f "$transcript" ]]; then
    echo "error: no transcript found; pass one explicitly." >&2
    exit 1
fi

db="${TMPDIR:-/tmp}/hayes-verify-batch-$$.sqlite"
trap 'rm -f "$db" "$db"-* 2>/dev/null || true' EXIT

echo "==> Building hayes (debug)..."
swift build >/dev/null
hayes=".build/debug/hayes"

echo "==> Transcript: $transcript"
echo "==> Throwaway DB: $db"
echo

echo "==> Submitting batch (this validates the request wire format)..."
"$hayes" assess --batch "$transcript" --db "$db"

pending() { sqlite3 "$db" "SELECT batch_id, transcript, min_turn, max_turn FROM pending_batches;" 2>/dev/null || true; }
edges()   { sqlite3 "$db" "SELECT COUNT(*) FROM edges;" 2>/dev/null || echo 0; }

row=$(pending)
if [[ -z "$row" ]]; then
    echo
    echo "No pending batch was recorded. Either the transcript had no backlog,"
    echo "or submit failed — check the stderr above for an http(...) error." >&2
    exit 1
fi
echo
echo "Pending batch (id should start with msgbatch_ — that means accepted):"
echo "  $row"

echo
echo "==> Polling for completion (collect runs first on each pass)..."
deadline=$(( $(date +%s) + 1200 ))   # 20 minutes
while [[ -n "$(pending)" ]]; do
    if (( $(date +%s) > deadline )); then
        echo "Timed out with a batch still pending. The batch SLA is 24h; re-run"
        echo "  $hayes assess --batch \"$transcript\" --db \"$db\""
        echo "later to collect it." >&2
        exit 1
    fi
    sleep 30
    "$hayes" assess --batch "$transcript" --db "$db" >/dev/null 2>&1 || true
    printf '.'
done

echo
echo "==> Collected. Edges reinforced: $(edges)"
echo "==> Sample pairs:"
"$hayes" ls --db "$db" 2>/dev/null | head -20 || true
echo
echo "Batch path verified end to end."
