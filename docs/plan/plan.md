# needle-pod Plan

## Overview

Runs NEEDLE workers as pods on Rackspace Spot compute that [warden](https://git.ardenone.com/jedarden/warden) elastically scales. warden solves "how much compute exists"; needle-pod solves "what runs on it."

## Architecture

Two independent scaling axes that have to work together:

- **warden** scales node **capacity** — VM count on the `agent-sandbox` cloudspace's node pool, within its policy envelope (max 10 nodes, `ch.vs1.large-ord`, bid ≤ 0.01).
- **needle-pod** scales worker **pods** on top of that capacity — a Deployment's replica count. More replicas without more warden-scaled capacity just means pods stuck Pending.

Target cluster: `agent-sandbox` (Rackspace Spot, us-central-ord-1, org `apexalgo-agent`, class `ch.vs1.large-ord`). It already exists as a bare cloudspace — warden already manages its node pool — but it is **not yet bootstrapped** as a GitOps-managed cluster in the sense every other cluster in this fleet is. No kubeconfig for it exists on this box yet; that's the literal first blocker.

Deployment shape: a `Deployment` (never `Job`/`CronJob` — hard-banned repo-wide) running `needle run` as the long-lived internal process, mirroring the existing bare-metal tmux pattern conceptually. The difference from bare metal: one worker = one pod, not one worker = one tmux session sharing a host's disk and process tree with every other worker. That's a real upside — it eliminates the shared-worktree collision class of bugs that plagues the lab fleet today, at the cost of losing the free atomicity a single shared SQLite file gives claims (see Open Questions).

## Components

1. **Cluster bootstrap** (prerequisite, not really this repo's code, but blocking everything else)
   - Fetch/generate a kubeconfig for `agent-sandbox` from the Spot UI.
   - Deploy the Tailscale operator (needs its own OAuth client/authkey secret).
   - Deploy external-secrets + a `ClusterSecretStore` pointed at OpenBao, via the same tailnet-egress-Service pattern `ord-devimprint`/`iad-ci`/`iad-options` already use to reach `traefik-rs-manager:8200`.
   - Register the cluster with rs-manager's ArgoCD (bearer token in OpenBao + `ExternalSecret`, matching the existing `cluster-<name>` pattern in `k8s/rs-manager/argocd/`).
   - Decide whether Traefik/cert-manager are needed at all — workers are outbound-only agents, not services being served, so this cluster may not need an ingress path the way every other cluster does.
   - Write `k8s/agent-sandbox/CLAUDE.md` with real node-shape/allocatable numbers per the fleet-wide "Cluster Sizing" convention, once the cluster is reachable.

2. **Worker runtime image** — no image exists today (only NEEDLE's own CI-build Dockerfiles, not a worker runtime). Needs: `needle` binary, an agent adapter config, the coding-agent CLI(s) the adapter shells out to (`claude`, and potentially `codex`/`opencode`/`pi`/`goose`), git, and a local toolchain that's "fast enough to iterate" — not full, since heavy/final verification should route through iad-ci the same way `cargo-remote` already does for Rust today (see Open Questions on how far that pattern extends). Built the same way warden was: `VERSION` file, WorkflowTemplate on iad-ci, kaniko build, semver tag, `imagePullSecrets`.

3. **Credential wiring** — per-agent-CLI auth (Anthropic subscription, GLM proxy token, and whatever `codex`/`opencode`/`goose` each require) via OpenBao + `ExternalSecret`, same shape as warden's. Git push credentials TBD pending Component 5.

4. **Bead-store / claim coordination across pods** — the hardest unsolved problem, no chosen design yet. See Open Questions.

5. **NEEDLE's dedicated-committer mechanism** — memory says NEEDLE already routes commits through a dedicated committer rather than every worker pushing directly, but the actual implementation was never found/documented. Needs tracing down in the NEEDLE source before deciding whether worker pods need their own git push credentials at all.

6. **Per-language CI verification templates** — only `rust-verify` exists today (the one `cargo-remote` submits to). If the offload-heavy-verification-to-iad-ci strategy is adopted for other languages, equivalent templates need to be built for Go/Node/Python before those repos' beads are safe to hand to a needle-pod worker.

## Data Models

None invented here — needle-pod consumes NEEDLE's existing bead schema (`.beads/beads.db` / `issues.jsonl`) as-is. Whatever changes if Component 4 lands a new coordination model belongs in NEEDLE's own repo, not here.

## Implementation Phases

- [ ] Phase 0: Bootstrap `agent-sandbox` as a full GitOps cluster (tailnet, ArgoCD registration, ESO/OpenBao) — see Component 1
- [ ] Phase 1: Resolve the bead-store coordination model — blocking; nothing past a single-worker proof-of-concept is safe without this
- [ ] Phase 2: Build the worker runtime image + its CI pipeline
- [ ] Phase 3: Credential wiring (agent CLIs + git push path)
- [ ] Phase 4: First Deployment manifest in `declarative-config` (`k8s/agent-sandbox/needle-pod/`), single replica, prove one worker end-to-end against a real repo
- [ ] Phase 5: Scale out — multiple replicas, exercise warden's node scaling under real load, extend CI-offload to additional languages as needed

## Open Questions

- **Single fat worker image, or per-language-cohort images?** A single image (node+go+rust+python) preserves full cross-repo roaming — NEEDLE's standing default, not an incidental preference — at the cost of image size. Splitting by language keeps images small but requires pinning each Deployment's `explore.workspaces` to that language's repo subset, sacrificing cross-language roaming. Leaning toward cohort-pinning unless cross-language roaming turns out to matter more than image size in practice.
- **Bead claim coordination with no shared local disk.** Rackspace Spot's Cinder-backed storage classes are effectively ReadWriteOnce (worth directly verifying, not just assuming), so a shared-mount SQLite file across pods is unlikely to work, and SQLite over a network filesystem is a known corruption risk regardless. The alternative — each pod clones its own repo + local `beads.db`, reconciling via git sync — trades instant-atomic claims for eventually-consistent ones, which would make the *already-documented* duplicate-claim races (two workers claiming the same bead) worse, not better. No design chosen yet.
- **How far does CI-offload actually reduce the local toolchain requirement?** The existing `cargo-remote` wrapper only auto-submits to iad-ci on a clean tree with no uncommitted changes — a condition a worker mid-edit almost never satisfies. So offload helps with a final, heavy verification pass, but the interactive edit-compile-test loop still needs a real local toolchain. Offloading narrows what has to be baked into the image; it doesn't eliminate the need.
- **Does agent-sandbox need Traefik/cert-manager at all?** Workers are outbound-only (dial out to git, OpenBao, agent APIs) — unless a status/metrics dashboard is wanted later, this cluster may not need the ingress stack every other cluster carries.
