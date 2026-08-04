# NEEDLE Runtime — Source Findings

Read out of the NEEDLE source and the live `~/.needle` state on the EX44,
2026-08-03. Line references are to NEEDLE at commit `ee619ed`; NEEDLE moves fast
(443 commits in the preceding 30 days), so re-check before relying on a citation.

These are the findings that determine what needle-pod can assume about its own
worker process.

## Self-update and hot-reload — already solved

`src/upgrade/mod.rs` is titled "Self-update functionality for needle" and
implements genuine hot-reload, not just download-and-restart:

- `check_hot_reload(needle_home)` compares the running binary against the
  `:stable` binary path and returns a `HotReloadCheck`: `Skipped`, `NoChange`,
  `NewBinaryDetected`, or `CurrentBinaryDeleted` (the last forces a reload when
  the running binary has been unlinked).
- Re-exec is **Unix-only** — the non-Unix path bails with "hot-reload re-exec is
  only supported on Unix platforms."
- A `--resume` flag restores worker context from the heartbeat and registry after
  the re-exec, so an upgrade doesn't lose the worker's place.

Live state on the EX44 mirrors this: `~/.needle/bin/needle-stable` is a symlink,
with `needle-stable.prev` and `needle-stable.pre-0.2.14-backup` kept as rollback
slots, and `~/.needle/upgrade/{downloads,backups}` as the staging area.

**Consequence for needle-pod:** updating needle inside a running pod is a solved
problem — drop a new binary at the `:stable` path. No image rebuild, no restart.

**Consequence for the operating model:** the fleet does *not* run "latest." It
runs a chosen `needle-stable` with two rollback slots. Any pod design that
auto-fetches latest would be *less* safe than the bare-metal fleet it replaces.

## Agent CLIs are per-dispatch subprocesses

`src/dispatch/mod.rs:793-803` spawns the agent through
`tokio::process::Command::new("bash").arg("-c").arg(&rendered)` — a fresh process
per dispatch, from a rendered adapter template.

Adapters live in `~/.needle/agents/` (19 YAML files plus `stream-parser.sh`) and
each carries an `invoke:` command template, an `input.method`, and an `output:`
parsing block.

**Consequence:** `claude` and `codex` need no hot-reload mechanism at all. There
is no long-lived process holding them. An atomic symlink flip is sufficient, and
Unix exec semantics mean a dispatch already running is unaffected (it holds its
own inode). The only wrinkle is that Claude Code spawns subagents, so a subagent
started after a flip can differ from its parent — low harm, avoidable by flipping
at a dispatch boundary.

## The compatibility probe is too weak to catch upstream drift

`run_probe(agent_cli)` at `src/dispatch/mod.rs:1549-1562`:

```rust
ProcessCommand::new(agent_cli)
    .arg("--help")
    .stdout(Stdio::null())
    .stderr(Stdio::null())
    .status()
```

It returns only an exit code and elapsed time. That verifies the CLI **exists and
runs** — nothing about whether the flags the adapter passes still exist, or
whether output still parses.

**Consequence:** a breaking claude-code or codex release passes this probe and
then fails at dispatch. An output-format change is worse — it fails *silently*,
producing mis-parsed results rather than an error. Any auto-update design must
put its gate somewhere stronger than this probe.

## SIGTERM stops the supervisor but does not drain

`src/supervisor/mod.rs:156-190` registers SIGINT and SIGTERM handlers that set an
`AtomicBool`. The main loop checks it at 215-217 and **breaks**, then emits a
`shutdown_requested` event (line 295) and calls `telemetry.shutdown()` (line 299).

There is no await of in-flight dispatch children. The supervisor stops taking new
work and exits; in-flight `claude --print` subprocesses die with the container.

**Consequence:** a restart mid-dispatch orphans that bead. It stays claimed until
the mend strand's stale reaper releases it — `mend.heartbeat_max_age: 3600` means
up to an hour of dead lease, and the agent's partial work is lost.

This matters far more for **spot preemption** than for updates. Preemption will
trigger this path routinely on `ch.vs1.large-ord`, so the drain is worth building
regardless of how updates are designed.

## `fabric.db` is telemetry, not a claim store

`~/.needle/fabric.db` (25 MB on the EX44) contains:

```
error_history   metric_samples   schema_version   sessions
session_worker_summaries   session_worker_summary   task_metrics
```

All telemetry. It is **not** a coordination substrate.

**Consequence:** claim atomicity today comes entirely from every worker on a host
opening the same `.beads/beads.db` file. That is exactly what one-worker-per-pod
destroys, and nothing else in NEEDLE currently compensates. This confirms the
coordination problem empirically rather than by assumption.

## Telemetry already exists in the right shape

- **JSONL sink** — `src/telemetry/mod.rs:2308` writes to
  `<log_dir>/<worker>-<session>.jsonl`; default log dir is `$HOME/.needle/logs`
  (line 2321), overridable via `with_dir` (line 2328).
- **OTLP metric sink** — feature-gated (`#[cfg(feature = "otlp")]`,
  `src/telemetry/mod.rs:26-32`). `~/.needle/config.yaml` points it at
  `http://localhost:4318/v1/metrics`.

**Consequence:** nothing needs to be built to *produce* telemetry. Ship the JSONL
to stdout and a log collector picks it up. The OTLP sink should be **disabled in
pods initially** — `localhost:4318` has no collector inside a pod, and JSONL
events already carry the failure signal.

## Log files are unbounded — `max_log_files` is a dead config key

`~/.needle/config.yaml` declares:

```yaml
mend:
  heartbeat_max_age: 3600
  max_log_files: 100
  min_interval: 60
```

But `max_log_files` (and `maxLogFiles`) appears **nowhere** in the NEEDLE source —
searched `*.rs`, `*.toml`, and `*.md` excluding `target/`. No pruning or rotation
logic exists in mend.

Measured on the EX44: **2,046 files / 80 MB accumulated between 2026-07-31 and
2026-08-03** — roughly three days, at `max_workers: 21`.

**Consequence:** on bare metal this is masked by a large disk. In a pod with
bounded ephemeral storage it is a slow-motion eviction (`nodefs.available: 10%`).
needle-pod must bound it at the pod level and should file an upstream bead to
implement the config key that already exists.

## Canary harness exists

`~/.needle/canary/` is a real workspace: `expected/canary-*.yaml` files declaring
expected outcomes, its own `.beads` store, `state_machine.py`, and a
`.needle-predispatch-sha`.

**Consequence:** the gate for validating a new agent-CLI version before promoting
it fleet-wide does not need to be invented — this is it.

## Config shape (EX44, for reference)

```yaml
worker:  { max_workers: 21, default_agent: claude-code-glm-4.7 }
strands: { pluck: auto, explore: auto, mend: true, knot: true }
mend:    { heartbeat_max_age: 3600, max_log_files: 100 }   # max_log_files inert
budget:  { daily_limit_usd: 10.00 }
```

`explore: auto` means workers discover work by scanning for workspaces that have a
`.beads` store — which is why a repo without one is invisible to the fleet.
