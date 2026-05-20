// Hayes — automatic memory for OpenCode.
//
// This plugin wires the `hayes` CLI into OpenCode the same way the Claude
// Code plugin wires it into Claude Code's hooks:
//
//   - recall: before each assistant reply, surface relevant memory pairs and
//     inject them into the system prompt (via the `experimental.chat.system.
//     transform` hook).
//   - assess: reconcile the memory graph via the Anthropic Message Batches
//     API (`hayes assess --batch`) on `session.idle` (submit the finished
//     turn and collect any ready batches) and `session.created` (collect
//     batches from earlier sessions, catch this one up). Lessons land after
//     the batch completes — usually minutes — but recall stays immediate;
//     only distillation is deferred, which is where the ~50% saving is.
//
// The `hayes` binary is not bundled. On first use the plugin downloads the
// universal macOS binary matching HAYES_VERSION from the GitHub release and
// caches it under ${XDG_CACHE_HOME:-~/.cache}/hayes/ — the same cache and
// asset convention as the Claude Code plugin's hooks/lib/ensure-hayes.sh, so
// the two harnesses share one cached binary. Set HAYES_BIN to use a local
// build instead (handy for development).
//
// Every failure path degrades silently: a broken memory step must never
// break the user's turn.
//
// The recall injection path uses the `experimental.chat.system.transform`
// hook, which receives { sessionID, model } but not the user's message — so
// the plugin reads the latest message from opencode.db itself. Verified
// against OpenCode 1.15.5: the user message is persisted before this hook
// fires, so recall reflects the current turn (no one-turn lag). If a future
// version changes that ordering, switch recall to the `chat.message` hook,
// which carries the message directly.

import type { Plugin } from "@opencode-ai/plugin"
import { createHash } from "node:crypto"
import { existsSync } from "node:fs"
import { mkdir, rename, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

// Sync point: kept in lockstep with plugin/.claude-plugin/plugin.json and
// Sources/HayesCommand/Hayes.swift by scripts/release.sh.
const HAYES_VERSION = "0.1.1"

const REPO = "bensyverson/Hayes"
const ASSET = "hayes-macos-universal"

/** Path to OpenCode's SQLite session database (`opencode.db`). */
function databasePath(): string {
  const dataDir =
    process.env.OPENCODE_DATA_DIR ||
    join(process.env.XDG_DATA_HOME || join(homedir(), ".local", "share"), "opencode")
  return join(dataDir, "opencode.db")
}

/**
 * Resolve a runnable `hayes` binary, downloading and caching the release
 * binary on first use. Returns the absolute path, or null on any failure.
 */
async function resolveHayes(): Promise<string | null> {
  const override = process.env.HAYES_BIN
  if (override && existsSync(override)) return override

  const cacheDir = join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "hayes")
  const target = join(cacheDir, `hayes-${HAYES_VERSION}`)
  if (existsSync(target)) return target

  try {
    await mkdir(cacheDir, { recursive: true })
    const base = `https://github.com/${REPO}/releases/download/v${HAYES_VERSION}`

    const binResp = await fetch(`${base}/${ASSET}`)
    if (!binResp.ok) return null
    const bytes = Buffer.from(await binResp.arrayBuffer())

    const shaResp = await fetch(`${base}/${ASSET}.sha256`)
    if (!shaResp.ok) return null
    const expected = (await shaResp.text()).trim().split(/\s+/)[0]
    const actual = createHash("sha256").update(bytes).digest("hex")
    if (!expected || expected !== actual) return null

    // Write to a temp file then rename so concurrent sessions never observe a
    // half-written binary.
    const tmp = join(cacheDir, `hayes-${HAYES_VERSION}.tmp-${process.pid}`)
    await writeFile(tmp, bytes, { mode: 0o755 })
    await rename(tmp, target)
    return target
  } catch {
    return null
  }
}

/** Best-effort extraction of a session id from a session.idle event. */
function sessionIDFromEvent(event: unknown): string | undefined {
  const e = event as { properties?: { sessionID?: string }; sessionID?: string; session_id?: string }
  return e.properties?.sessionID ?? e.sessionID ?? e.session_id
}

export const HayesPlugin: Plugin = async ({ $ }) => {
  const db = databasePath()

  return {
    // recall — inject surfaced memories into the system prompt before the LLM
    // replies, reflecting the current turn (see the file header).
    "experimental.chat.system.transform": async (
      input: { sessionID?: string },
      output: { system: string[] }
    ) => {
      try {
        const hayes = await resolveHayes()
        const sessionID = input?.sessionID
        if (!hayes || !sessionID) return

        const result = await $`${hayes} recall ${db} --format opencode --session-id ${sessionID}`
          .nothrow()
          .quiet()
        const block = result.stdout?.toString().trim()
        if (block && Array.isArray(output.system)) output.system.push(block)
      } catch {
        // Degrade to "no recalled context this turn".
      }
    },

    // assess — reconcile the graph via the batch API. `session.idle` submits
    // the finished turn and collects ready batches; `session.created`
    // collects batches from earlier sessions and catches this one up.
    event: async ({ event }: { event: { type: string } }) => {
      if (event.type !== "session.idle" && event.type !== "session.created") return
      try {
        const hayes = await resolveHayes()
        const sessionID = sessionIDFromEvent(event)
        if (!hayes || !sessionID) return

        await $`${hayes} assess ${db} --format opencode --session-id ${sessionID} --batch`
          .nothrow()
          .quiet()
      } catch {
        // Degrade to "assess skipped".
      }
    },
  }
}
