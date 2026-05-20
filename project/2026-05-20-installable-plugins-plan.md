# Installable Hayes for Claude Code & OpenCode

## Context

The README's only integration guidance is a pointer to a DocC article. The
primary use case is *installing Hayes as an agent plugin*, so the README must
carry concrete install instructions — first for Claude Code (already has a
working plugin + marketplace manifest), and now for OpenCode too.

OpenCode plugins are JS/TS modules (not shell hooks), and they cannot bundle
the compiled Swift `hayes` binary the way the Claude Code plugin does today via
the committed `plugin/bin/hayes`. The user chose the *clean* architecture: add
a real GitHub Release that ships the binary, have **both** harnesses bootstrap
that binary into a shared cache on first run, and **drop the committed binary
from git**. OpenCode also needs Hayes to understand its on-disk transcript
format.

Decisions already made with the user:

- Build the OpenCode plugin (not just docs).
- Distribute the OpenCode plugin as an in-repo `.ts` file installed via a
  one-line `curl` into `~/.config/opencode/plugin/` (or `.opencode/plugin/`).
- Add a real binary release; **both** plugins bootstrap-download the binary;
  delete `plugin/bin/hayes` from git.

### Verified contracts

- **Hayes transcript pipeline**: `TranscriptLoader.load(path:format:)`
  (`Sources/HayesCore/Transcripts/TranscriptLoader.swift`) dispatches on a
  `Format` enum (`auto`, `claudeCode`, `openaiResponses`) to parsers that
  return `[Operator.Message]`. `ClaudeCodeTranscriptParser` is the model to
  follow. Recall uses the last user message / a trailing window; assess splits
  by user turn. **The CLI does not yet expose `--format`** — recall/assess take
  a path + `--session-id` only.
- **OpenCode storage** (`$OPENCODE_DATA_DIR`, default
  `~/.local/share/opencode/storage/`): `message/<sessionID>/<messageID>.json`
  (one file per message; user/assistant `role`, `time.created`) and
  `part/<messageID>/<partID>.json` (discriminated by `type`: `text`→`text`;
  `tool`→`callID`/`tool`/`state{input,output}`; `reasoning`→drop like thinking;
  `file`/`step-start`→drop).
- **OpenCode plugin API**: a `.ts` module exporting `async ({ $, client,
  directory, worktree, project }) => ({ hooks })`. `event` hook receives
  `({ event })`; `event.type === "session.idle"` fires when the agent finishes
  (the `Stop` analog). Context injection is the uncertain part: documented
  `experimental.chat.system.transform({input,output})` can push to
  `output.system` but lacks the current user message; `chat.message` has the
  message but its mutation contract is less documented. **OpenCode is not
  installed in the dev environment**, so the injection path needs a live
  smoke test before we trust it.
- **Version constant**: `Sources/HayesCommand/Hayes.swift:14`. Release sync
  points today: that file + `plugin/.claude-plugin/plugin.json` (see
  `scripts/release.sh`). The OpenCode plugin `.ts` adds a third sync point.
- `lipo` and `jq` are available locally; `gh` runs in CI.

### Claude Code install (target UX, confirmed against docs)

```
/plugin marketplace add bensyverson/Hayes
/plugin install hayes@hayes
/reload-plugins
```

The marketplace `source` is `./plugin`; both marketplace and plugin are named
`hayes`. The plugin's `bin/` is auto-added to PATH; with bootstrap, the binary
is fetched on first hook run.

## Plan

```yaml
tasks:
  - title: "Installable Hayes for Claude Code & OpenCode"
    desc: >-
      Make installing Hayes a first-class, low-friction experience for both
      Claude Code and OpenCode, and document both in the README (the original
      ask). Net new: a GitHub binary release, a shared bootstrap that both
      plugins use to fetch the binary, an OpenCode transcript parser, an
      OpenCode plugin, and install docs. The committed plugin/bin/hayes is
      deleted in favor of the release.
    labels: [epic]
    children:

      - title: "Binary release pipeline"
        desc: >-
          Publish the hayes binary as a GitHub Release asset so both plugins
          can download it. This replaces the committed binary as the source of
          truth.
        children:
          - title: "Build universal macOS binary and attach to GitHub Release in release.yml"
            ref: release-yml
            desc: >-
              In .github/workflows/release.yml, on a v* tag build a universal
              binary (swift build -c release --arch arm64 --arch x86_64; output
              under .build/apple/Products/Release/hayes), compute a SHA256
              sidecar, and `gh release create v<version>` attaching
              hayes-macos-universal and hayes-macos-universal.sha256. Remove the
              "verify committed binary version matches manifest" step (no
              committed binary anymore). Download URL convention the bootstrap
              relies on:
              https://github.com/bensyverson/Hayes/releases/download/v<version>/hayes-macos-universal
          - title: "Add OpenCode plugin version as a third release sync point"
            ref: release-sync
            desc: >-
              Update scripts/release.sh to bump and verify the version constant
              in the OpenCode plugin .ts alongside plugin.json and Hayes.swift,
              so all three stay locked together. Update the CI version-sync
              check accordingly (it currently compares the committed binary).
            blockedBy: [opencode-plugin]

      - title: "Claude Code plugin bootstrap (drop committed binary)"
        desc: >-
          Re-architect the CC plugin so it fetches the binary from the release
          instead of relying on a committed plugin/bin/hayes.
        children:
          - title: "Write shared ensure-hayes.sh bootstrap"
            ref: bootstrap
            desc: >-
              New plugin/hooks/lib/ensure-hayes.sh, sourced by the hooks.
              Responsibilities: resolve version via `jq -r .version
              $CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json`; honor a HAYES_BIN
              env override (for local dev / `--plugin-dir`); cache at
              ${XDG_CACHE_HOME:-$HOME/.cache}/hayes/hayes-<version>; if absent,
              curl the release asset + .sha256, verify with `shasum -a 256 -c`,
              chmod +x, atomic mv into the cache; echo the resolved path.
              Silent-degrade on any failure (return non-zero so the hook exits
              0 — a broken bootstrap must never break the user's turn).
          - title: "Point recall.sh/assess.sh at the bootstrapped binary"
            ref: hooks-use-bootstrap
            desc: >-
              Source ensure-hayes.sh in plugin/hooks/recall.sh and assess.sh,
              replace the ${CLAUDE_PLUGIN_ROOT}/bin/hayes reference with the
              resolved cache path. Keep existing silent-degradation behavior
              (missing jq/binary/recall fault => exit 0).
            blockedBy: [bootstrap]
          - title: "Remove committed binary and update tooling/docs"
            ref: drop-binary
            desc: >-
              git rm plugin/bin/hayes; add plugin/bin/ to .gitignore; repurpose
              scripts/build-plugin.sh for local dev (build + print `export
              HAYES_BIN=.build/release/hayes`); update plugin/README.md (drop
              the "marketplace will land separately" note; document bootstrap +
              HAYES_BIN).
            blockedBy: [hooks-use-bootstrap]

      - title: "Hayes reads OpenCode transcripts (TDD)"
        desc: >-
          Teach the CLI to parse OpenCode's on-disk session storage so recall
          and assess work against it. Strict red/green TDD; DocC 100%.
        children:
          - title: "RED: failing tests for OpenCode parsing + --format wiring"
            ref: oc-tests
            desc: >-
              Add JSON fixtures mirroring OpenCode storage (message/ + part/)
              and tests for a new OpenCodeTranscriptParser: user text,
              assistant text, assistant tool call (callID/tool/input) +
              completed tool output as a .tool message, reasoning dropped, parts
              ordered by message time/id. Add tests for the new `--format`
              option on recall/assess and a clear error when --format opencode
              is given without --session-id. Verify all fail.
          - title: "GREEN: implement Format.opencode + OpenCodeTranscriptParser + --format"
            ref: oc-parser
            desc: >-
              Add `case opencode` to TranscriptLoader.Format; new
              Sources/HayesCore/Transcripts/OpenCodeTranscriptParser.swift that
              takes a storage root + sessionID, reads message/<id>/*.json sorted
              by time/id, assembles part/<messageID>/*.json into
              Operator.Message values (mirroring ClaudeCodeTranscriptParser's
              mapping). Add a `--format` @Option to RecallCommand/AssessCommand
              threaded into TranscriptLoader.load(path:format:); require
              --session-id for opencode (directory has no filename stem). DocC
              annotations to 100% coverage.
            blockedBy: [oc-tests]
          - title: "Auto-detect OpenCode storage directories in TranscriptLoader"
            ref: oc-autodetect
            desc: >-
              Nice-to-have: when the path is a directory containing message/ and
              part/, resolve Format.auto to .opencode. Plugin still passes
              --format explicitly, so this is convenience, not load-bearing.
            blockedBy: [oc-parser]

      - title: "OpenCode plugin"
        desc: >-
          A thin JS/TS plugin that wires hayes into OpenCode and reuses the
          bootstrap so install is one-line.
        children:
          - title: "Write opencode-plugin/hayes.ts"
            ref: opencode-plugin
            desc: >-
              Export the plugin function. event hook: on session.idle, resolve
              $OPENCODE_DATA_DIR (default ~/.local/share/opencode/storage) +
              sessionID and run `hayes assess <storage> --format opencode
              --session-id <id>` via Bun `$`. Recall injection: implement via
              experimental.chat.system.transform pushing framed `hayes recall
              ... --format opencode` output to output.system (documented path),
              with a code comment flagging the known current-message timing
              caveat and chat.message as the fallback. Reuse the bootstrap
              (download release binary to ~/.cache/hayes on first use; honor
              HAYES_BIN) in TS. Embed a version constant (the third release sync
              point). Silent-degrade on any failure.
            blockedBy: [oc-parser, bootstrap]
          - title: "DEFERRED: smoke-test OpenCode plugin against a live install"
            ref: opencode-smoke
            desc: >-
              OpenCode is not installed in the dev environment, so the injection
              hook (system.transform vs chat.message timing) and the session.idle
              assess path cannot be verified here. Install OpenCode, run a real
              session, confirm memories inject and assess reinforces edges. If
              system.transform lags the current turn, switch recall to
              chat.message. This task gates calling OpenCode support "verified."
            labels: [decision]
            blockedBy: [opencode-plugin]

      - title: "Documentation (the original ask)"
        desc: >-
          Concrete install instructions in the README, plus DocC/plugin README
          updates. Keep DocC at 100% coverage.
        children:
          - title: "Rewrite README install sections for Claude Code and OpenCode"
            ref: readme
            desc: >-
              Replace the thin "Wiring into Claude Code" pointer with an Install
              section. Claude Code: `/plugin marketplace add bensyverson/Hayes`
              -> `/plugin install hayes@hayes` -> `/reload-plugins`; note jq +
              macOS requirement and that the binary auto-bootstraps. OpenCode:
              one-line curl of hayes.ts into ~/.config/opencode/plugin/ (global)
              or .opencode/plugin/ (project); binary auto-bootstraps; note
              requirements. Mention HAYES_BIN for local/dev.
            blockedBy: [hooks-use-bootstrap, opencode-plugin]
          - title: "Update DocC article + plugin README for both harnesses"
            ref: docc
            desc: >-
              Update Sources/HayesCore/Documentation.docc/Articles/UsingHayesAsACLIHook.md
              for the bootstrap + OpenCode flow (or add a sibling OpenCode
              article and update the README docs list per CLAUDE.md). Keep DocC
              coverage at 100% (swift package generate-documentation).
            blockedBy: [oc-parser]

      - title: "Validation & commit"
        desc: >-
          Final gate before presenting work as complete.
        children:
          - title: "Lint, full test suite, DocC coverage"
            ref: validate
            desc: >-
              swiftformat . --lint (then format if needed); swift test --quiet;
              swift package generate-documentation --target HayesCore. Fix all
              issues before declaring done.
            blockedBy: [release-yml, drop-binary, oc-parser, opencode-plugin, readme, docc]
          - title: "Offer to commit in logical chunks"
            desc: >-
              Propose commits grouped by concern (release pipeline, CC
              bootstrap + binary removal, OpenCode parser, OpenCode plugin,
              docs). Commit only on user approval.
            blockedBy: [validate]
```

## Verification

- **Hayes parser**: `swift test --quiet` (new OpenCode parser + `--format`
  tests pass; existing tests stay green).
- **CC bootstrap**: with `HAYES_BIN` set, `claude --plugin-dir ./plugin` runs
  recall/assess without a committed binary; unset `HAYES_BIN` exercises the
  download path against a published release.
- **OpenCode**: deferred live smoke test (OpenCode not installed here) — see the
  `opencode-smoke` task.
- **Docs**: `swift package generate-documentation --target HayesCore` clean at
  100% coverage; README install steps followed verbatim on a clean machine.
