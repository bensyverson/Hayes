// Runtime smoke test for opencode-plugin/hayes.ts WITHOUT OpenCode or an LLM.
//
// Mocks Bun's `$` and points HAYES_BIN at a logging stub, then invokes the
// exported hooks and asserts they call `hayes` with the expected arguments
// and inject recall output into output.system.
//
// Run:  node --experimental-strip-types scripts/opencode-plugin-harness.mjs
import { HayesPlugin } from "../opencode-plugin/hayes.ts"
import { writeFileSync, mkdtempSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { execFileSync } from "node:child_process"

const dir = mkdtempSync(join(tmpdir(), "hayes-harness-"))
const stub = join(dir, "hayes-stub")
const log = join(dir, "calls.log")
writeFileSync(
  stub,
  ['#!/bin/sh', 'printf "%s\\n" "$*" >> "' + log + '"', "printf '\\n\\n[Memories:]\\n- seed -> behavior\\n'", ""].join("\n"),
  { mode: 0o755 }
)
process.env.HAYES_BIN = stub
process.env.OPENCODE_DATA_DIR = "/tmp/fake-oc-data"

// Mock Bun shell: $`...`.nothrow().quiet() -> awaitable -> { stdout }.
// Reconstruct the full command by interleaving literal template strings with
// interpolated values (Bun puts `recall`, `--format opencode`, … in strings).
const $ = (strings, ...values) => {
  let cmd = ""
  strings.forEach((s, i) => {
    cmd += s + (i < values.length ? String(values[i]) : "")
  })
  const argv = cmd.trim().split(/\s+/)
  const run = async () => {
    const out = execFileSync(argv[0], argv.slice(1), { encoding: "utf8" })
    return { stdout: Buffer.from(out) }
  }
  const chain = { nothrow: () => chain, quiet: () => chain, then: (res, rej) => run().then(res, rej) }
  return chain
}

const hooks = await HayesPlugin({ $ })

const output = { system: [] }
await hooks["experimental.chat.system.transform"]({ sessionID: "ses_TEST" }, output)
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_TEST" } } })
await hooks.event({ event: { type: "session.created", properties: { sessionID: "ses_X" } } })

const invocations = readFileSync(log, "utf8").trim().split("\n")
const expectedDb = "/tmp/fake-oc-data/opencode.db"
const recallOK = invocations.some((c) => c.startsWith(`recall ${expectedDb} --format opencode --session-id ses_TEST`))
const assessOK = invocations.some((c) => c.startsWith(`assess ${expectedDb} --format opencode --session-id ses_TEST`))
const injectedOK = output.system.length === 1 && output.system[0].includes("[Memories:]")
const idleOnly = invocations.length === 2 // session.created must NOT invoke hayes

console.log("recall invoked with db+format+session:", recallOK)
console.log("assess invoked with db+format+session:", assessOK)
console.log("recall output injected into system[]:", injectedOK)
console.log("non-idle event ignored:", idleOnly)
console.log("invocations:\n  " + invocations.join("\n  "))

if (recallOK && assessOK && injectedOK && idleOnly) {
  console.log("PASS")
} else {
  console.log("FAIL")
  process.exit(1)
}
