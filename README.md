# needle-pod

Runs NEEDLE workers as pods on Rackspace Spot compute that
[warden](https://git.ardenone.com/jedarden/warden) elastically scales.

warden solves "how much compute exists"; needle-pod solves "what runs on it."
Two independent scaling axes: warden scales nodes, needle-pod's replica count
scales worker pods on top of them.

One worker per pod, one clone per repo, on an `emptyDir` discarded at restart —
which removes the shared-worktree collision class the bare-metal fleet still
hits.

## Status

The worker runtime image and its entrypoint exist. Nothing has been deployed,
and the image has not yet been built — there is no CI for it, and the target
cluster is not yet registered with ArgoCD.

| Component | State |
|---|---|
| Worker runtime image | Written — `containers/needle-worker/` |
| Provider credential wiring | Written — 7 harnesses, no secret on disk |
| Harness probe | Written — real dispatch, gates version flips |
| Kubernetes manifests | Not started — belongs in `declarative-config` |
| Build pipeline | Not started — `needle-pod-build` on iad-ci |
| Cluster bootstrap (M0) | Not started — agent-sandbox is not ArgoCD-registered |
| Cross-pod bead-claim coordination | **Unsolved** — gates scaling past one replica |

## The image

A single fat image carrying every toolchain, so workers keep NEEDLE's default
cross-repo roaming instead of being pinned to a language cohort. Seven agent
harnesses are wired: **Claude Code, Codex, opencode, pi, droid, goose, aider**.

Providers are described once in environment variables sourced from a Kubernetes
Secret, and fanned out into each harness's native config format. Because a
provider is just `(base_url, token, model, wire protocol)`, subscription plans
served over an Anthropic- or OpenAI-compatible endpoint — the GLM coding plan,
for instance — need no special handling.

```
containers/needle-worker/
├── Dockerfile              needle installed LAST, so a needle bump pushes ~13 MB
├── entrypoint.sh           env -> configured worker -> exec needle run
├── lib/render.py           one credential shape -> seven config formats
├── probe/harness-probe.sh  real end-to-end dispatch; gates every version flip
└── adapters/               one NEEDLE adapter template per harness
```

Details, the verified install matrix, and the environment contract are in
[`docs/notes/worker-image.md`](docs/notes/worker-image.md).

## Structure

- `docs/notes/` — features, constraints, design decisions
- `docs/research/` — external reference material and prior art
- `docs/plan/plan.md` — complete application plan
- `containers/` — buildable artifacts
