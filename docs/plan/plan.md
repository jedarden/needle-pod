# needle-pod Plan

## Overview

Runs NEEDLE workers as pods on Rackspace Spot compute that [warden](https://git.ardenone.com/jedarden/warden) elastically scales. warden solves "how much compute exists"; needle-pod solves "what runs on it."

This is deliberately an experiment. The first deployment exists to find out how NEEDLE workers actually behave in Kubernetes — under preemption, restart, and memory pressure — not to reach scale quickly. Observability is therefore sequenced *ahead* of the first worker rather than after it.

## Architecture

Two independent scaling axes that have to work together:

- **warden** scales node **capacity** — VM count on the `agent-sandbox` cloudspace's node pool, within its policy envelope (max 10 nodes, `ch.vs1.large-ord`, bid ≤ 0.01, confirmed matching the real pool).
- **needle-pod** scales worker **pods** on top of that capacity. More replicas without more warden-scaled capacity just means pods stuck Pending.

Target cluster: `agent-sandbox` (Rackspace Spot, ORD, org `apexalgo-agent`). It is Ready and reachable — access from the EX44 is credential-free, via an exec-credential kubeconfig that mints a 24h token from OpenBao per invocation. What it is **not** is a GitOps-managed cluster: it has no ArgoCD registration, no Tailscale operator, no external-secrets. Full observed state in `../research/agent-sandbox-cluster-state.md`.

Deployment shape: a `Deployment` running `needle run` as the long-lived internal process (never `Job`/`CronJob` — banned repo-wide). One worker per pod, rather than one worker per tmux session sharing a host's disk and process tree. That eliminates the shared-worktree collision class that plagues the lab fleet, at the cost of the free claim atomicity a single shared SQLite file provides — see Open Questions.

## Components

1. **Cluster bootstrap** (prerequisite; blocks everything else)
   Registration with rs-manager ArgoCD, Tailscale operator, external-secrets against rs-manager OpenBao, cert-manager, and Traefik as the cluster's single ingress connection point. Concrete deliverables, ordering, and the one-time credential steps are in `../notes/cluster-bootstrap-deliverables.md`; the fleet patterns being copied are catalogued in `../research/fleet-bootstrap-patterns.md`.

2. **Observability** (before the first worker)
   A local VictoriaLogs instance behind Traefik, with NEEDLE's existing JSONL telemetry routed to stdout for the bundled Vector agent to collect. Rotation is bounded at four layers. See `../notes/deployment-shape-and-lifecycle.md`.

3. **Worker runtime image**
   A single fat image — needle, `claude`, `git`, `bf`, and toolchains — with versions baked as a floor and declared as a ceiling in a ConfigMap. Built by a `needle-pod-build` WorkflowTemplate on iad-ci, digest-pinned, rebuilt nightly with no version-detection CI. Full rationale in `../notes/image-and-update-strategy.md`.

4. **Credential wiring**
   Agent CLI auth and a git push path via OpenBao + `ExternalSecret`, using the Kubernetes-auth pattern already proven on this cluster. Plus a Docker Hub `imagePullSecret`.

5. **Bead-store / claim coordination across pods**
   The one genuinely unsolved problem. No chosen design. See Open Questions.

6. **NEEDLE's committer path**
   Whether worker pods need their own git push credentials depends on how commits actually reach a remote. The 07-30 fleet audit found pushing delegated to the dispatched agent by prompt text alone, with a verification gate whose data source nothing writes — so assume workers need push credentials until proven otherwise.

7. **Per-language CI verification templates**
   Only `rust-verify` exists today. Equivalents for Go/Node/Python are needed before those repos' beads are safe to hand to a worker, *if* the offload strategy is extended.

## Data Models

None invented here — needle-pod consumes NEEDLE's existing bead schema (`.beads/beads.db` / `issues.jsonl`) as-is. Anything Component 5 changes belongs in NEEDLE's repo, not this one.

## Implementation Phases

Sequenced so that the first worker runs against working telemetry, and so that the unsolved coordination problem blocks only scale-out.

- [ ] **M0 — Bootstrap `agent-sandbox` as a GitOps cluster.** ArgoCD registration (with the real cluster CA, not `insecure`), ApplicationSet, app-of-apps, Tailscale operator, external-secrets, cert-manager, Traefik.
- [ ] **M1 — Observability, before any worker.** Local VictoriaLogs behind Traefik with time *and* disk bounded retention; worker JSONL to stdout; OTLP disabled initially. Verify from the EX44 that a throwaway pod's events are queryable *before* M4.
- [ ] **M2 — Worker runtime image + CI pipeline.**
- [ ] **M3 — Credential wiring.**
- [ ] **M4 — One worker, watched.** Single replica, `emptyDir`, one real repo. Requires the empty-pool idle loop and a decision on SIGTERM drain first.
- [ ] **M5 — Scale out.** Multiple replicas, warden node scaling under real load. **Gated on the coordination model.**

Manifests already written into `declarative-config` (`k8s/agent-sandbox/`): `traefik/`, `cert-manager/`, `monitoring/`. They are inert until the M0 ApplicationSet and app-of-apps exist.

## Open Questions

### Resolved

- **Single fat worker image, or per-language cohorts?** → **Fat image.** Nodes carry ~96 GiB ephemeral, so image size is affordable, and cross-repo roaming — NEEDLE's standing default — is preserved. Cohort-splitting stays available as a later optimization.

- **Does agent-sandbox need Traefik/cert-manager at all?** → **Yes, both.** The earlier reasoning — that workers are outbound-only, so no ingress stack is needed — was wrong. Traefik is the cluster's *single ingress connection point*: one path to control and monitor, and everything else multiplexes behind it. Exposing a service directly with `tailscale.com/expose` spends the cluster's one exposure and forces a second, separately-monitored proxy the moment anything else needs ingress. Every `vpn` IngressRoute then requires a real Certificate — no wildcard fallback exists in this fleet — which makes cert-manager, the ClusterIssuer, the Cloudflare DNS01 token, and therefore external-secrets all mandatory.

- **How to keep needle / claude / codex current without a rebuild treadmill?** → Baked floor, ConfigMap-declared ceiling, Reloader-triggered restart, nightly scheduled rebuild. No version-detection CI. needle self-updates through its existing hot-reload; the agent CLIs update by probe-gated symlink flip. See `../notes/image-and-update-strategy.md`.

### Still open

- **Bead claim coordination with no shared local disk.** The hard one, and the gate on M5. Confirmed empirically rather than assumed: `~/.needle/fabric.db` is telemetry only (sessions, metrics, error history), so claim atomicity today comes *entirely* from every worker on a host opening the same `.beads/beads.db`. One-worker-per-pod destroys that and nothing in NEEDLE compensates. Candidate directions, in current order of preference:
  1. **Partition by workspace** — each pod owns a disjoint repo set, so cross-pod claims never arise. Cheapest, ships immediately, costs roaming.
  2. **External claim broker** — a small service outside the pods. This is what every product surveyed in `../research/isolated-agent-dev-images.md` converged on: coordination in the control plane, never inside the isolated boundary.
  3. **Git-as-database** (Gas Town) — most interesting, but eventually-consistent claims would worsen the already-documented duplicate-claim races.

- **How far does CI-offload actually reduce the local toolchain requirement?** Partially informed: `cargo-remote` only auto-submits on a clean tree, which a worker mid-edit rarely satisfies. Offload narrows what must be baked into the image for *final* verification; it does not remove the need for a real local toolchain in the edit-compile-test loop.

- **Does `mend.max_log_files` get implemented upstream, or does needle-pod bound logs itself?** The config key exists in `config.yaml` but appears nowhere in NEEDLE's source; nothing prunes worker JSONL (2,046 files / 80 MB in ~3 days on the EX44). Short term, bound it at the pod. Long term this belongs in NEEDLE.
