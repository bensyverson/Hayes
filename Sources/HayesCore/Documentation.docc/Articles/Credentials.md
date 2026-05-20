# Providing the Anthropic API key

Store the key Hayes uses for assess (and the optional Anthropic recall
extractor) in the macOS Keychain, so it never has to live in a plaintext
config file or be inherited through the environment.

## Why a Keychain, not an environment variable

`hayes assess` distils lessons through Anthropic's API, so it needs an
Anthropic API key. The obvious way to supply one is to export
`ANTHROPIC_API_KEY` in the shell that launches your agent — but that has two
problems.

First, the only non-environment alternative most harnesses offer is a
plaintext `env` block in a settings file, and a project-level settings file
is often version-controlled: one commit away from publishing a secret.

Second, and more important: **anything reachable as `ANTHROPIC_API_KEY` is
also consumed by the agent harness itself.** Under Claude Code, exporting the
key can silently switch a subscription user onto pay-as-you-go API billing,
because the harness picks up the same variable. There is no way to scope an
inherited environment variable to "only Hayes's hook."

A key Hayes reads directly from the Keychain never enters the environment at
all. That is the only thing that actually decouples Hayes's key from the
harness's billing — which is why `hayes auth set` is the recommended way to
provision it.

## Managing the key

```bash
hayes auth set       # prompt for the key on the terminal (input is not echoed)
hayes auth status    # show whether a key is available and which source wins
hayes auth clear     # remove the stored key
```

`hayes auth set` reads the key from a hidden terminal prompt. For scripted
setup — piping from another password manager, say — pass `--from-stdin` to
read a single line from stdin instead:

```bash
pass show anthropic/api-key | hayes auth set --from-stdin
```

The key is deliberately never accepted as a command-line argument: that would
leak it into shell history and the process list. It is stored as a generic
password under the Keychain service `com.bensyverson.hayes`.

`hayes auth status` reports availability without ever printing the secret:

```
Anthropic API key:
  Keychain (com.bensyverson.hayes): set
  ANTHROPIC_API_KEY environment variable: not set
  Resolved from: Keychain (com.bensyverson.hayes)
```

## Resolution precedence

When `recall` or `assess` needs the Anthropic key, it resolves the first
non-empty source of:

1. the `--anthropic-api-key` flag,
2. the `ANTHROPIC_API_KEY` environment variable,
3. the Keychain.

The environment variable stays available as an override — useful for CI or a
one-off run — but it is no longer *required*. Because the Keychain alone
suffices, once you have run `hayes auth set` you never need to export the
variable, and the harness never sees the key.

Only the Anthropic path consults these sources. An on-device AFM run never
reads the Keychain, so it can't trigger an access prompt.

## Surfacing a missing key

`assess` runs from hooks (Claude Code's `Stop`/`SessionStart`, OpenCode's
`session.idle`/`session.created`) that have **no** prompt-injection channel,
so a missing key would leave distillation silently dead. `recall` — which
*does* have an injection channel — carries the warning on its behalf: pass
`--warn-missing-anthropic-key` and, when no key resolves, recall prepends a
one-line nudge pointing at `hayes auth set` to its plaintext output (never to
`--json`). The shipped plugins pass this flag because their assess path is
Anthropic-only; standalone `hayes recall` stays silent unless you opt in.

## Scope

Keychain storage is macOS-only, accessed through the
[KeyManager](https://github.com/bensyverson/KeyManager) wrapper over the
Security framework. The ``CredentialStore`` protocol is the seam behind which
a different platform's store could slot in; ``KeychainCredentialStore`` is the
shipped implementation.

## Topics

### Credential storage

- ``CredentialStore``
- ``KeychainCredentialStore``
- ``HayesCredential``
