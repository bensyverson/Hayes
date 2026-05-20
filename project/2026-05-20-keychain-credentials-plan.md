# Keychain credentials — design

**Status:** design · 2026-05-20 · macOS-only (for now)
**Motivates:** removing the plaintext-API-key requirement for the assess hook; decoupling Hayes's Anthropic key from Claude Code's own billing.

## Goal

Give Hayes a first-class way to hold the Anthropic API key in the macOS Keychain, so the assess path (and the optional Anthropic recall path) can authenticate without the key ever sitting in a plaintext config file or being inherited through the environment. Two halves: a `hayes auth` command to **set** the key once, and a Keychain-backed **read** path so the binary resolves the key on its own.

## Why this, and why now

Today both `AssessCommand.swift:113` and `RecallCommand.swift:209` resolve the key as `--anthropic-api-key ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]`. The plugin hooks pass no flag, so the key must be exported in the shell that launched the agent. That has two real problems. First, the only non-env alternative we could offer is a plaintext `env` block in `settings.json` — and the project-level `.claude/settings.json` is version-controlled, one `git commit` from publishing a secret. Second, and more important: any value reachable as `ANTHROPIC_API_KEY` is also consumed by Claude Code itself, so exporting it can silently flip a subscription user onto pay-as-you-go API billing. There is no way to scope an inherited env var to "only the hook." A key the `hayes` binary reads directly from the Keychain never needs to enter the environment at all, which is the only thing that actually breaks that coupling.

We deliberately scope this to macOS. Mac users run OpenCode too, so this is not a Claude-Code-only feature — but AFM already pins recall's default to macOS, and we are not building a Linux credential store on spec. If a Linux story is ever needed, it slots in behind the same `CredentialStore` seam below.

## Resolution precedence

The resolver checks three sources in order and returns the first non-empty hit:

1. `--anthropic-api-key` flag (explicit, highest).
2. `$ANTHROPIC_API_KEY` (explicit override; keeps CI and one-off runs working).
3. Keychain (the stored default).

The ordering is the conventional "explicit beats stored" expectation, but the load-bearing property is the *other* direction: because the Keychain alone is sufficient, a user who runs `hayes auth set` never has to set the env var, so Claude Code never sees the key and billing stays decoupled. Env stays available as an override rather than a requirement.

## The slash-command question, resolved

We will **not** add a slash command (Claude Code or OpenCode) that collects the API key. A slash command is a prompt template: whatever the user types flows into the conversation, lands in the transcript file Hayes itself reads, is sent to the model, and may reach telemetry. Collecting a live secret that way is strictly worse than the status quo, which is why conventional tools (`gh auth login`, `gcloud auth login`) take credentials at the terminal. The secure primitive is the CLI command; secret entry happens on a TTY, never in chat.

Discoverability is handled out-of-band instead. As an optional follow-on, the recall path (which has a real `UserPromptSubmit` injection channel, unlike Stop/SessionStart) can detect "Anthropic selected but no key resolvable" and inject a one-line nudge pointing at `hayes auth set`. That surfaces exactly when assess would otherwise be silently dead, and it points to the secure path rather than being one.

## Dependency: KeyManager

We adopt the local sibling library `KeyManager` (`../KeyManager`, `https://github.com/bensyverson/KeyManager`), mirroring the existing Operator local-path-or-remote conditional in `Package.swift`. It is a small, owned, macOS-13+ wrapper over the Security framework. Relevant surface: `KeyManager(service:)`, and synchronous throwing `store(key:value:shouldUpdate:)`, `update(key:value:)`, `value(for:) -> String`, `remove(key:)`, with a `KeyManager.KeyError` (`notFound`, `duplicate`, `couldNotRead`, …). The API is synchronous and throwing — no async — which suits a one-shot CLI. Reimplementing raw `SecItem*` calls would be unreasonable churn for no benefit, so this is the rare justified dependency, and it is ours.

Service identifier: `com.bensyverson.hayes`. Key: `anthropic-api-key`. Both centralized as constants so there is one source of truth.

## Components

- **`CredentialStore` protocol (HayesCore, `Sendable`).** Narrow seam — `func value(for:) throws -> String?`, `func store(_:for:) throws`, `func remove(for:) throws` — so the real Keychain is never touched in tests. A `notFound` from KeyManager maps to `nil`, not a throw, so "no key yet" is a normal value rather than an error.
- **`KeychainCredentialStore: CredentialStore` (HayesCore).** Thin adapter wrapping `KeyManager(service: "com.bensyverson.hayes")`. The only type that imports KeyManager.
- **`InMemoryCredentialStore` (tests).** Dictionary-backed double for strict TDD of the resolver and the `auth` command without hitting the real Keychain (which would be flaky/interactive in CI).
- **Anthropic key resolver (HayesCommand).** A pure function `resolveAnthropicKey(flag:environment:store:) -> String?` implementing the precedence above. Replaces the two inline `?? ProcessInfo…` lookups in `RecallCommand` and `AssessCommand` so resolution has a single tested definition.
- **`AuthCommand` (HayesCommand/Commands), registered in `Hayes.swift`.** Subcommands:
  - `auth set` — acquire the secret from a hidden (no-echo) TTY prompt; `--from-stdin` reads one line from a pipe for automation. **No `--key <value>` argument** — that would leak the secret into shell history and the process list. Stores via `store(_:for:)` (update-if-present). The acquisition I/O is separated from the store call so the storing logic is unit-testable with an injected secret + the in-memory double; the TTY read stays a thin untested shell (`getpass`/termios, no new dependency).
  - `auth status` — report whether a key is stored and **which source would win**, without ever printing the secret itself.
  - `auth clear` — remove the Keychain entry (`notFound` is a no-op success, so it's idempotent).

## TDD plan (red first)

Resolver: one test per precedence combination (flag-only, env-only, store-only, and each override pair) plus the all-empty `nil` case. `CredentialStore` double: store/overwrite/read-missing/remove/remove-missing. `AuthCommand`: `set` writes through to the store; `status` reports the correct winning source and never emits the secret; `clear` is idempotent. Write and run these against the protocol + in-memory double, confirm all fail, then implement the resolver, the adapter, and the command.

## Docs

Update the README quick-start to present `hayes auth set` as the recommended way to provision the key (with env noted as the override/CI path), and add a DocC article on credential resolution and the billing-decoupling rationale. Note in the hook/usage docs that exporting `ANTHROPIC_API_KEY` is no longer required once `hayes auth set` has run. Keep DocC coverage at 100% for the new public types.

## Follow-on impl tasks

The block below is `job import`-ready (first fenced YAML block keyed `tasks`).

```yaml
tasks:
  - title: Keychain-backed Anthropic credentials
    desc: Give Hayes a macOS Keychain credential store plus a `hayes auth` command, so the assess/recall Anthropic key can be resolved without a plaintext config file or an inherited ANTHROPIC_API_KEY env var (which also decouples Hayes's key from Claude Code's own billing). macOS-only for now; behind a CredentialStore seam so a Linux story could slot in later. Full design in project/2026-05-20-keychain-credentials-plan.md. Strict red/green TDD throughout, against an in-memory CredentialStore double so the real Keychain is never touched in tests.
    labels: [enhancement]
    children:
      - title: KeyManager dependency + CredentialStore seam + Keychain adapter
        ref: cred-store
        labels: [enhancement]
        desc: Add the KeyManager dependency to Package.swift, mirroring the existing Operator local-path-or-remote conditional (../KeyManager vs the github URL). Define a Sendable CredentialStore protocol in HayesCore — value(for:) throws -> String?, store(_:for:) throws, remove(for:) throws — where a KeyManager notFound maps to nil rather than throwing. Add KeychainCredentialStore conforming to it, the only type importing KeyManager, using service "com.bensyverson.hayes" and key "anthropic-api-key" as shared constants. Add an InMemoryCredentialStore double in the test target. TDD the double's store/overwrite/read-missing/remove/remove-missing semantics first.
      - title: Anthropic key resolver with flag > env > keychain precedence
        ref: resolver
        blockedBy: [cred-store]
        labels: [enhancement]
        desc: Add a pure resolveAnthropicKey(flag:environment:store:) -> String? in HayesCommand implementing precedence flag > $ANTHROPIC_API_KEY > Keychain, returning the first non-empty source and nil when all are empty. Replace the inline `anthropicAPIKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]` lookups in RecallCommand.swift:209 and AssessCommand.swift:113 with calls to it, so resolution has a single tested definition. TDD every precedence combination plus the all-empty case first.
      - title: hayes auth command (set / status / clear)
        ref: auth-cmd
        blockedBy: [resolver]
        labels: [enhancement]
        desc: Add AuthCommand with subcommands and register it in Hayes.swift. `auth set` reads the secret from a hidden no-echo TTY prompt (getpass/termios, no new dependency) or one line from stdin via --from-stdin for automation, with NO --key argument (avoids shell-history/process-list leakage), and stores via the CredentialStore (update-if-present). `auth status` reports whether a key is stored and which source would win, without ever printing the secret. `auth clear` removes the entry idempotently (notFound is a no-op success). Separate the secret-acquisition I/O from the store call so the storing/status/clear logic is unit-tested with an injected secret and the in-memory double; the TTY read stays a thin untested shell. TDD the command logic first.
      - title: Docs — README quick-start, DocC credentials article, hook usage note
        ref: cred-docs
        blockedBy: [auth-cmd]
        labels: [documentation]
        desc: Update the README quick-start to recommend `hayes auth set` for provisioning the key, with env noted as the override/CI path. Add a DocC article covering credential resolution precedence and the Claude-Code billing-decoupling rationale. Note in the hook/usage docs that exporting ANTHROPIC_API_KEY is no longer required once `hayes auth set` has run. Keep DocC coverage at 100% for the new public types.
      - title: (Optional) Recall nudge when Anthropic key is missing
        ref: cred-nudge
        blockedBy: [resolver]
        labels: [enhancement]
        desc: Optional follow-on. When the Anthropic backend is selected but resolveAnthropicKey returns nil, have the recall path inject a one-line UserPromptSubmit nudge pointing at `hayes auth set`, so a silently-dead assess surfaces exactly when it breaks. Recall is the only hook event with a documented injection channel (Stop/SessionStart have none). Keep it to a single non-spammy line; TDD the missing-key branch.
```
