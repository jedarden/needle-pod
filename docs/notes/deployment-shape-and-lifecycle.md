# Deployment Shape, Lifecycle, and Observability

Design constraints for running a NEEDLE worker as a pod. Evidence in
`../research/needle-runtime-findings.md` and
`../research/agent-sandbox-cluster-state.md`.

## Workload kind

`Deployment` — `Job` and `CronJob` are banned repo-wide. `StatefulSet` is not
banned and becomes relevant below.

## Storage: a Deployment with a PVC cannot scale past one replica

Cinder classes on Rackspace Spot are effectively ReadWriteOnce, so a Deployment
with a shared PVC caps at `replicas: 1`. Scaling out therefore needs either:

- a **StatefulSet** with `volumeClaimTemplates` (one PVC per pod), or
- **`emptyDir`** with clone-on-start.

**Recommendation: `emptyDir`.** Nodes carry ~96 GiB ephemeral, which is ample for
a clone, and it sidesteps stale-`.beads` questions entirely by always starting
from a fresh clone. It also avoids `sata`'s 5–20 GB PVC size constraint.

**Decide this at Phase 4, not Phase 5.** Getting it wrong means rewriting the
manifest at exactly the point the fleet starts to matter.

## Lifecycle gap 1 — workers exit on an empty ready pool

Documented in `features.md`: bare-metal workers *exit* when no work is available.
Inside a Deployment that is indistinguishable from CrashLoopBackOff.

An explicit idle/backoff loop in the entrypoint is a **prerequisite for the first
deployment**, not a refinement — without it the pod is undeployable and its
telemetry unreadable.

## Lifecycle gap 2 — SIGTERM does not drain

`src/supervisor/mod.rs:156-190` sets a shutdown flag on SIGTERM; the loop breaks
at 215-217, emits `shutdown_requested`, and exits. In-flight dispatch children are
never awaited.

Consequence: a restart mid-dispatch orphans the bead. It stays claimed until the
mend strand's stale reaper releases it — `heartbeat_max_age: 3600` means up to an
hour of dead lease, with the agent's partial work lost.

**This is a preemption problem before it is an update problem.** On
`ch.vs1.large-ord` at a 0.01 bid, preemption will fire this path routinely.
Options:

1. Add the drain — supervisor awaits in-flight children before exiting — plus a
   `terminationGracePeriodSeconds` sized to a typical dispatch. *Preferred:*
   bounded change, and it de-risks the whole pod model rather than just updates.
2. Accept reaper-based recovery and lower `heartbeat_max_age` for pods.

Whichever is chosen, choose it **before the first restart**, or the first
telemetry you read will be confusing.

## Observability comes before the first worker

The point of this exercise is learning how pods behave under preemption, OOM, and
restart. If a worker starts before logs are flowing, the first failure is
invisible and teaches nothing. Telemetry is therefore sequenced ahead of the
worker, not after it.

### Local VictoriaLogs, behind Traefik

A local `victoria-logs-single` instance on agent-sandbox (chart 0.11.17, image
`v1.36.1-scratch`), reached through the cluster's single Traefik ingress at
`https://victorialogs-agent-sandbox-ts.ardenone.com:8444`.

**Traefik is the single ingress connection point** — one path to control, one path
to monitor. Exposing VictoriaLogs directly with `tailscale.com/expose` would spend
the cluster's one exposure on a single service and force a second, separately
monitored Tailscale proxy the moment anything else needed ingress. That is the
failure the pattern exists to prevent. No service in this cluster other than
`traefik-tailscale` may carry that annotation.

### Getting worker telemetry into it

NEEDLE already emits what is needed — nothing must be built to *produce*
telemetry:

- **JSONL** to `<log_dir>/<worker>-<session>.jsonl` (`src/telemetry/mod.rs:2308`).
  Route it to **stdout** so the chart's bundled Vector DaemonSet picks it up from
  container logs with no shared volume. Minimum viable: `tail -F` in the
  entrypoint. Proper fix: a native stdout sink in NEEDLE — a small follow-up.
- **OTLP metrics** — feature-gated, configured against `localhost:4318`.
  **Disable in pods initially**; there is no collector in-pod, and JSONL events
  carry the failure signal. Metrics can come later.

Vector's remap parses the JSONL so NEEDLE's fields become queryable, and stamps
`cluster`, `namespace`, `app`, and `pod` — the last lets a single failing worker's
history be isolated during triage.

## Log rotation — four layers, all bounded

| Layer | Bound | Status |
|---|---|---|
| NEEDLE JSONL in-pod | none | **gap — must be handled in the Deployment** |
| Container stdout → kubelet | `containerLogMaxSize: 10Mi` × `containerLogMaxFiles: 5` = **50 MiB/container** | verified on the node; no action |
| Vector agent | `ignore_older_secs: 3600` | cannot replay a backlog on restart |
| VictoriaLogs storage | `--retentionPeriod=14d` **and** `--retention.maxDiskSpaceUsageBytes=15GiB` on a 20Gi `sata` PVC | verified by rendering the chart |

Layer 1 is the only real gap. `mend.max_log_files: 100` is configured but the key
appears nowhere in the NEEDLE source — nothing prunes those files. Measured on the
EX44: **2,046 files / 80 MB in ~3 days**. On bare metal a large disk masks it; in
a pod it is a slow-motion eviction against `nodefs.available: 10%`.

Mitigation: `emptyDir` `sizeLimit` plus container `ephemeral-storage` limits, and
a prune loop in the entrypoint — with an upstream bead to implement the config key
that already exists.

Note also that the two disk-based retention caps are **off across the whole
fleet** (`is_set="false"` on the live iad-ci instance), and bare integer retention
values mean *months*, not days. Both bounds are set explicitly here.

## Sizing

| | |
|---|---|
| Node | 4 vCPU / ~7.25 GiB / ~96 GiB ephemeral, no taints |
| Observability overhead | ~100m CPU / ~192Mi requested (VictoriaLogs + Vector) |
| Estimated worker footprint | 2–3 GiB each |
| Workers per node | ~2–3 |
| warden ceiling | 10 nodes, `ch.vs1.large-ord`, bid ≤ 0.01 |
| Fleet ceiling | **~20–30 workers**, ≈ $0.10/hr ≈ $73/month |

Comparable to the EX44's current `max_workers: 21`. The per-node worker density
and the real memory footprint are estimates — measuring them is one of the first
jobs of the initial deployment.

## What the first deployment is meant to teach

This is deliberately an experiment. A single replica against one real repo,
watched, should answer questions no amount of planning will:

- What does spot preemption actually do to an in-flight dispatch, and does the
  drain (or the reaper) recover it cleanly?
- What is a worker's real memory footprint — does 2–3 per node hold?
- How large does the JSONL grow per worker-day in practice?
- Does image pull time matter on a fresh node when warden scales up?
- Do failures surface usefully in VictoriaLogs, or is more structure needed in
  what the worker emits?

Answers feed back into the sizing above and into the coordination design, which
is the one genuinely open question and the gate on scaling past a single replica.
