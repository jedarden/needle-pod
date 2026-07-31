# Features

What the deployed system needs to actually do, distinct from `plan.md`'s
implementation components. Constraints and open decisions live inline where
they affect the feature; unresolved design questions stay in `plan.md`.

## Elastic worker scaling tied to node scaling

Replica count on the worker Deployment needs to track capacity warden has
actually provisioned, not run ahead of it — more replicas than warden-scaled
nodes just means Pending pods. Whatever ties these two together (manual,
HPA-driven off warden's `/v1/pools`, or something else) is itself a feature,
not just an operational habit.

## Per-worker isolated filesystem

One pod = one clone, unlike bare metal where many workers share one working
directory per repo. This is a genuine upside worth preserving deliberately —
it removes the shared-worktree collision class of bug the lab fleet still
hits ([[feedback_needle_shared_worktree]] in prior memory). Don't reintroduce
sharing at the pod level for the sake of disk savings.

## Bead-claim coordination across pods

The hardest open feature — see `plan.md` Open Questions. Whatever gets
chosen, the feature requirement is: two pods must never both believe they
hold the same bead.

## Roaming vs. cohort-pinned exploration

Bare metal defaults to full roaming (no `-w`, worker explores all registered
workspaces). If worker images end up split by language (see
`dev-environment-tools.md`), each Deployment's `explore.workspaces` needs to
be scoped to only the repos matching that image's toolchain — roaming within
a language cohort, not pinning to one repo, which is the thing that was
explicitly rejected as a default before.

## CI-offload for heavy verification

Extends the existing `cargo-remote` → `rust-verify` pattern (already live on
this box and lab) to other languages. The feature is specifically the *final,
clean-tree, heavy* check (full suite, clippy/lint, fuzz) — not the
interactive loop, which still runs locally. Needs an equivalent
WorkflowTemplate per language before that language's repos are safe to hand
to a needle-pod worker.

## Per-agent-CLI credential injection

Whichever coding-agent CLI a worker's adapter shells out to needs its own
auth surfaced as a secret, not baked into the image. Multiple CLIs (see
`dev-environment-tools.md`) implies multiple credential shapes, not one.

## Git push path

Unresolved pending confirmation of NEEDLE's dedicated-committer mechanism
(memory says it exists, implementation never traced). Until that's found,
treat "does every worker pod need its own push credential, or just a central
committer" as unanswered — don't provision N sets of git credentials
preemptively.

## Resource capping per worker pod

Bare metal caps the whole user slice (`MemoryMax=48G` on the host) plus
per-adapter build-parallelism limits (`CARGO_BUILD_JOBS=2`,
`RUST_TEST_THREADS=2`). In a pod, this becomes ordinary
`resources.requests`/`limits` — genuinely simpler, but the *values* (how much
memory a worker actually needs mid-session, including build tooling) still
need to be re-derived for the pod context, not copied from the host-slice
numbers as-is.

## Worker lifecycle vs. Deployment semantics

Bare-metal workers **exit on an empty ready pool** — that's a load-bearing
behavior for the fleet's dispatch model. Inside a Deployment, an exiting
process gets restarted automatically, which would turn "no ready work" into
a restart-loop (and eventually CrashLoopBackOff) rather than the intended
idle/backoff state. The container's entrypoint needs to translate
exit-on-exhaust into an internal sleep/backoff instead of a real process
exit, or the Deployment needs different lifecycle handling — this needs an
explicit decision, it doesn't fall out of the existing bare-metal behavior
for free.

## Observability

FABRIC (existing NEEDLE-telemetry dashboard, lives on lab) is the closest
existing prior art for "what are my workers doing" — worth checking whether
it can point at pod-based workers with no changes, or needs a source added.
Not designed yet either way.
