# Development Environment Tools

Concrete tool inventory for the worker runtime image. Confirmed near-term
scope: **Claude Code and Codex** are the two coding-agent CLIs to actually
set up. `opencode`, `goose`, and `pi` were mentioned as a longer-run
possibility but are deferred — not designed against yet, don't build for
them speculatively.

## Coding-agent CLIs

### Claude Code

- npm-distributed, requires Node.js in the image.
- **Container auth: set `ANTHROPIC_API_KEY`** — Claude Code checks for it
  before attempting OAuth, so setting it skips the browser flow entirely.
  This is the recommended path for automation.
- Auth priority order (highest first): cloud provider credentials →
  `ANTHROPIC_AUTH_TOKEN` → `ANTHROPIC_API_KEY` → `apiKeyHelper` → OAuth token
  → `/login` subscription credentials.
- Subscription-billed alternative exists (`claude setup-token` generates an
  OAuth token) — this is the pattern bare-metal NEEDLE's existing
  `claude-print`/`claude-interactive` adapters already solved for a
  persistent tmux session doing a one-time interactive login. Whether that's
  worth replicating for an ephemeral pod, versus just using a plain API key,
  is an open decision — pods are far more disposable than a long-lived tmux
  session, which cuts toward API-key billing being the simpler fit even if
  the org's existing bare-metal precedent is subscription-based.
- Entrypoint pattern: `claude --print`. Containers are specifically called
  out as the safe place to use `--dangerously-skip-permissions` — reasonable
  here since a worker pod is single-purpose and isolated, unlike a shared
  bare-metal host.

### Codex

- Install via npm — **must be the scoped package `@openai/codex`**; the
  unscoped `codex` package on npm is a different, unrelated tool from 2012.
  (Homebrew and a standalone installer also exist, npm is simplest for a
  Docker build.)
- Default auth (ChatGPT OAuth, subscription-tied) needs a browser and does
  **not** work headless.
- For containers/Kubernetes: **device-code authentication** (added to
  Codex's app-server in late March 2026) is the flow specifically called out
  as useful for headless/Kubernetes deployments. API-key auth is also
  available for CI/CD-style use.

### Sources (verify before relying on if this file gets stale)

- [How to Authenticate Claude Code and Codex on a Headless VPS](https://codeongrass.com/blog/how-to-run-claude-code-on-a-remote-server/)
- [Claude Code Headless Mode: The Complete Self-Hosting Guide (2026)](https://amux.io/guides/claude-code-headless/)
- [Codex CLI Authentication: OAuth, Device Code, API Keys, and CI/CD Credential Management](https://codex.danielvaughan.com/2026/04/01/codex-cli-authentication-flows-credential-management/)
- [Enable Headless or Command-line Authentication for Codex CLI · openai/codex#3820](https://github.com/openai/codex/issues/3820)

## Core runtime

- `needle` binary itself.
- `git`, plus whatever credential helper the eventual push-credential model
  needs (see `features.md` — unresolved).
- Node.js (required by both Claude Code and Codex CLIs regardless of which
  language a given repo's beads are in).

## Base language toolchains (for iteration, not full CI parity)

Per `plan.md`'s offload discussion — these need to be "fast enough to
iterate," with heavy/final verification routed to iad-ci instead of baked in
at full weight:

- Rust (`rustc`/`cargo`) — already has a remote-offload path (`cargo-remote`
  → `rust-verify` on iad-ci) to extend into the image.
- Go, Node, Python — no remote-offload equivalent exists yet; needs building
  before repos in these languages are safe to hand to a needle-pod worker.

## Explicitly not baking in

- **tailscale** — handled at the Service/operator layer (tailnet-egress
  Services), not per-pod. Only reconsider if workers need to dial arbitrary,
  unregistered tailnet hosts on the fly.
- **cloudflared** — same reasoning; workers are outbound-only, not something
  being exposed.
- **tmux** — was load-bearing on bare metal for sharing one host across many
  workers; with one pod per worker that justification goes away. Keep only
  if wanted for `kubectl exec` attach parity, not by default.
