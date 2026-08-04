# Worker Image and Update Strategy

Decisions taken 2026-08-03. Supporting evidence is in
`../research/needle-runtime-findings.md` and `../research/fleet-bootstrap-patterns.md`.

## The problem this resolves

needle, `claude`, and `codex` all release frequently — NEEDLE alone took 443
commits in 30 days. Baking all three into an image implies rebuilding constantly;
the obvious escape is a minimal image that fetches the latest of each at startup.
That escape is wrong, but the instinct behind it is right. The resolution is to
separate *what floats* from *what is declared*.

## Decision 1 — Fat image, not per-language cohorts

**Single image with all toolchains.** This preserves cross-repo roaming, which is
NEEDLE's standing default rather than an incidental preference.

The original open question weighed roaming against image size. The measurement
settles it: agent-sandbox nodes carry **~96 GiB of ephemeral storage**, so a fat
multi-toolchain image is affordable on disk. Cohort-splitting remains available
later as an optimization; it is not needed to start, and paying for it up front
would mean pinning each Deployment's `explore.workspaces` to a language subset.

## Decision 2 — Never fetch "latest" at init

Four reasons, in order of weight:

1. **It breaks GitOps rollback for the fastest-moving component.** The manifest
   would show a pinned image digest while the software actually running varies by
   start time. Two pods on the same digest run different code. That is worse than
   a `:latest` tag, because a `:latest` tag is at least visible in the manifest.
2. **It contradicts how the fleet already operates.** Bare metal runs a chosen
   `needle-stable` with `.prev` and `.pre-<version>-backup` rollback slots — a
   deliberately pinned version, not a moving target. Auto-latest in pods would be
   *less* safe than the setup it replaces, on a platform where restarts are more
   frequent.
3. **Startup network dependency on preemptible nodes.** Restarts are routine
   under spot preemption. Unauthenticated GitHub API allows 60 requests/hour per
   IP; a 20–30 worker fleet behind one egress IP restarting together can convert
   "degraded" into fleet-wide CrashLoopBackOff. GitHub is also the read-only
   *mirror*, not the source of truth.
4. **Supply chain.** The pod holds an Anthropic credential and a Forgejo push
   token. Pulling an executable into that boundary at runtime is a wider door than
   a digest-pinned artifact.

## Decision 3 — Baked floor, declared ceiling

- The image bakes a known-good triple and **records the versions in a manifest
  file inside the image**. This is the floor: the pod always boots with zero
  network, and "what was running when this broke?" stays answerable.
- A **ConfigMap** in `k8s/agent-sandbox/needle-pod/` declares the desired exact
  version of each tool. Unset means use the baked version.
- The **entrypoint reconciles at start**: compare desired against baked, fetch
  only what differs. Normally a no-op.
- **Stakater Reloader** (already deployed elsewhere in the fleet, chart 2.2.9)
  watches that ConfigMap and triggers the rollout when it changes.

Updating a tool is therefore a one-line commit to declarative-config → ArgoCD
syncs → Reloader restarts. No live `kubectl` mutation, and rollback is
`git revert`.

**Hard rule: exact versions in that ConfigMap, never `latest`.** Otherwise the
same pod restarting twice runs different software and the whole scheme collapses
back into invisible drift.

## Decision 4 — Nightly rebuild, no version-detection CI

Watching three upstream release feeds and reacting to each is the wrong thing to
build. It isn't needed: **build on a schedule and resolve the latest of each at
build time.** No feed parsers, no comparison state, no webhooks. When nothing
upstream changed, the layer cache makes it nearly a no-op. When all three changed,
one image absorbs all of it — there is no per-feed trigger, so there is no
rebuild storm.

This is a template copy rather than new machinery: iad-ci already runs four
CronWorkflows, and `telegram-claude-bridge-build` / `news-trader-build` already
build an image *and commit the resulting digest back into declarative-config*.

Layer ordering matters more than it looks: needle is 13 MB against a multi-GB
image whose bulk is toolchains. With needle as the **last** layer, a needle-only
rebuild is "reuse cached base, add 13 MB, push 13 MB."

## Decision 5 — Per-tool update mechanism

The two cases are structurally different and should not share a mechanism.

### needle — use the existing hot-reload

`src/upgrade/mod.rs` already implements `check_hot_reload`, Unix re-exec, and
`--resume` to restore worker context from heartbeat and registry. Dropping a new
binary at the `:stable` path is the entire update. Nothing to build.

### claude / codex — probe-gated symlink flip

These are spawned fresh per dispatch via `bash -c`
(`src/dispatch/mod.rs:793-803`), so there is no long-lived process to reload and
no state to preserve. Mirror the pattern needle already uses on itself:

- install to a versioned prefix
- `claude` → symlink → the versioned install, with `.prev` retained
- update = atomic symlink flip; rollback = flip back

Unix exec semantics make this safe even mid-dispatch — a running process holds its
own inode. The one wrinkle: Claude Code spawns subagents, so a subagent started
after a flip can differ from its parent. Low harm; avoidable by flipping at a
dispatch boundary, which needle already knows how to identify.

## Decision 6 — Strengthen the probe, and gate the flip on it

The mechanism above is easy. **The risk is adapter compatibility, and that is
where the control belongs.** Adapters are YAML with hardcoded flags and output
parsing; an upstream flag rename breaks dispatch, and an output-format change
breaks it *silently*, which is worse.

The existing preflight does not cover this. `run_probe`
(`src/dispatch/mod.rs:1549-1562`) runs `agent_cli --help` with stdout and stderr
discarded and checks only the exit code — a breaking release sails through.

So:

1. Strengthen the probe from "does `--help` exit 0" to "does a trivial end-to-end
   dispatch produce parseable output." One throwaway prompt; cheap.
2. Install the new version alongside, probe it, and **flip the symlink only on
   pass**. On failure, stay put and emit telemetry.
3. `~/.needle/canary/` — a real workspace with expected-state beads — is the
   heavier version of the same gate if deeper coverage is wanted later.

This yields self-updating agent CLIs without a bad upstream release breaking 20–30
workers simultaneously at whatever hour it ships, and still requires no
version-detection CI.

## What not to build

- Do **not** hot-swap tools under a running dispatch, and do not have needle
  replace its own binary outside the supported re-exec path. Restart is the update
  mechanism; it is the only moment the version is unambiguous.
- Do **not** write a service that polls upstream release feeds.

The `~/.needle/upgrade/{downloads,backups}` machinery stays useful as the
fetch-and-verify path — just run it at init and at explicit flip points, not
continuously.
