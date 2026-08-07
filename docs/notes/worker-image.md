# Worker Image — Built Artifacts

What now exists under `containers/needle-worker/`, the contract it expects from
Kubernetes, and the upstream findings that changed the design while building it.

Written 2026-08-06. Install methods and package identities were verified against
the live registries on that date rather than carried over from documentation —
several were wrong in the earlier notes. Re-verify before assuming any of it
still holds.

## Layout

```
containers/needle-worker/
├── Dockerfile              fat multi-toolchain image; needle installed LAST
├── VERSION                 semver, per fleet convention
├── entrypoint.sh           env -> configured worker -> exec needle run
├── bin/record-versions.sh  build-time; freezes the baked floor to versions.json
├── lib/
│   ├── common.sh           JSON logging, env helpers
│   ├── render.py           provider credentials -> 7 harness config formats
│   ├── needle-config.sh    renders ~/.needle/config.yaml
│   ├── workspaces.sh       git identity, push credential, repo clones
│   ├── telemetry.sh        JSONL -> stdout, plus a size-bounded prune sweep
│   └── versions.sh         declared-vs-baked reconcile, probe-gated flip
├── probe/harness-probe.sh  real end-to-end dispatch probe; gates every flip
└── adapters/*.yaml.tmpl    one NEEDLE adapter template per harness
```

## The seven harnesses, as verified

| Harness | Install | Binary | Non-interactive | Provider config |
|---|---|---|---|---|
| Claude Code | `npm i -g @anthropic-ai/claude-code` | `claude` | `--print --output-format stream-json` | env `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` |
| Codex | `npm i -g @openai/codex` | `codex` | `codex exec` | `~/.codex/config.toml` → `model_providers`, `env_key` |
| opencode | `npm i -g opencode-ai` | `opencode` | `opencode run` | `~/.config/opencode/opencode.json`, `{env:VAR}` |
| pi | `npm i -g --ignore-scripts @earendil-works/pi-coding-agent` | `pi` | `pi -p`, `--mode json` | conventional provider env vars |
| droid | `curl -fsSL https://app.factory.ai/cli \| sh` | `droid` | `droid exec` | `~/.factory/settings.json` → `customModels`, `${VAR}` |
| goose | `curl -fsSL .../block/goose/releases/download/stable/download_cli.sh \| bash` | `goose` | `goose run --text` | `~/.config/goose/config.yaml` + `GOOSE_*` env |
| aider | `uv tool install --python 3.12 aider-chat` | `aider` | `--message --yes-always` | `~/.aider.conf.yml` + provider env vars |

Traps worth keeping written down, all of which cost time to establish:

- **pi is `@earendil-works/pi-coding-agent`, not `@mariozechner/pi`.** The latter
  is an unrelated vLLM pod manager that installs a `pi-pods` binary. The project
  moved scope; `@mariozechner/pi-coding-agent` also still exists at an older
  version, so two of the three plausible names are wrong.
- **Codex is `@openai/codex` (scoped).** The unscoped `codex` is an unrelated
  package from 2012.
- **goose and opencode have both changed GitHub orgs** — `aaif-goose/goose` and
  `anomalyco/opencode`. The documented installer URLs still redirect correctly
  and are verified to return 200; the underlying repos are not where the older
  notes say.
- **Node ≥22.19 is the real floor**, set by pi. Claude Code requires ≥22. The
  image uses Node 24.
- **aider requires Python ≥3.10,<3.13**, so `uv` installs it against a pinned
  3.12 rather than the system interpreter.
- **`bf` has no public binary release anywhere.** The Forgejo API refuses
  anonymous calls (403) and the GitHub mirror has no release assets, so the
  image builds it from source off the public mirror. Anonymous `git clone` from
  Forgejo does work, if that is ever preferred.

## Credential model

One shape in, seven shapes out. A provider is described once in environment
variables sourced from a Kubernetes Secret:

```
NEEDLE_POD_PROVIDERS=glm,anthropic
NEEDLE_POD_DEFAULT_PROVIDER=glm

NEEDLE_PROVIDER_GLM_KIND=anthropic          # anthropic | openai (wire protocol)
NEEDLE_PROVIDER_GLM_BASE_URL=https://api.z.ai/api/anthropic
NEEDLE_PROVIDER_GLM_TOKEN=<from Secret>
NEEDLE_PROVIDER_GLM_MODEL=glm-5
NEEDLE_PROVIDER_GLM_SMALL_MODEL=glm-4.7     # optional
```

`render.py` fans that out into every harness's native format and writes one
NEEDLE adapter per `(harness, provider)` pair — 7 harnesses × 2 providers = 14
adapters, named `<harness>-<provider>`.

**No credential is ever written to disk.** Every harness supports indirection to
an environment variable, so rendered configs carry the variable's *name*:
`env_key` for Codex, `{env:VAR}` for opencode, `${VAR}` for droid, and direct
env reads for the rest. Verified by rendering with sentinel tokens and grepping
the whole home directory for the values — nothing matched. That property is
worth preserving: it means a dumped filesystem, or an emptyDir surviving into a
debug container, leaks nothing.

Because base URL is just another field, pointing a provider at the existing
`zai-proxy` instead of upstream is a one-value change. That matters more at
scale than it looks: monthly subscription plans are rate-limited rather than
metered, and N pods holding the same key with no shared backoff will collide.
zai-proxy already does adaptive rate limiting (EWMA ceiling discovery, 429
retry). Direct keys were chosen first because the proxy is only reachable over
Tailscale, which agent-sandbox does not have until M0 lands.

## Upstream findings that changed the design

Three claims in the existing plan documents turned out to be wrong or stale.

**1. The idle/backoff loop is not needed.** `deployment-shape-and-lifecycle.md`
calls an entrypoint idle loop "a prerequisite for the first deployment," on the
grounds that workers exit on an empty ready pool. `IdleAction::Wait` is now
NEEDLE's default (`src/types/mod.rs:937`) and is wired through
`worker.idle_action`. The entrypoint sets it explicitly — a default can be
flipped upstream, and a silent flip would reintroduce CrashLoopBackOff — but
there is no loop to build.

**2. JSONL log growth is partly already solved.** The notes say
`mend.max_log_files` is a dead config key, which is true. But
`telemetry.file_sink.retention_days` is a *different* key that is genuinely
implemented: `src/strand/mod.rs:126` reads it and hands it to the mend strand,
which prunes agent log files by age. It is set to 3 days here. A size-bounded
sweep still runs alongside it, because day granularity is too coarse to protect
a bounded emptyDir from a single bad day.

**3. A native stdout sink already exists — but does not solve the problem.**
The plan lists "a native stdout sink in NEEDLE" as the proper fix and `tail -F`
as the stopgap. `telemetry.stdout_sink` is in fact fully implemented
(`src/telemetry/mod.rs:2477-2691`). It is still not usable here: its only
formats are `Minimal`/`Normal`/`Verbose`, all human-readable text, and Vector's
remap needs structured JSON. So the tail stays, and the upstream ask shrinks
from "build a sink" to "add a `json` variant to `StdoutFormat`" — a much smaller
change that would delete `telemetry.sh` entirely.

The one gap that is **not** closed: SIGTERM still does not drain. The supervisor
sets a flag and breaks its loop without awaiting in-flight dispatch children, so
a preemption mid-dispatch orphans the bead until the stale reaper releases it.
The entrypoint mitigates only by lowering `heartbeat_max_age` from 3600 to 900.
On `ch.vs1.large-ord` at a 0.01 bid this path fires routinely, so it remains the
most valuable upstream fix — and it lives in the NEEDLE repo, not this one.

## The probe

NEEDLE's own `run_probe` (`src/dispatch/mod.rs:1549-1562`) runs
`agent_cli --help` with both streams discarded and checks the exit code. A
breaking release passes that trivially, and an output-format change fails
*silently* — mis-parsed results rather than an error.

`probe/harness-probe.sh` instead runs a real one-shot dispatch per harness with
a prompt that has exactly one correct answer, and requires that answer back in
the shape the adapter parses (for Claude Code, that means asserting the first
stdout line is valid JSON, not merely that text came back). It gates every
version flip: install alongside → probe → flip the symlink only on pass,
otherwise stay put and emit telemetry.

`NEEDLE_POD_PROBE_ON_START=true` also runs it for every harness at startup. It
is off by default — a real dispatch per harness costs tokens and wall-clock on
every restart, which is the wrong trade on a preemptible node.

## Environment contract

| Variable | Default | Purpose |
|---|---|---|
| `NEEDLE_POD_PROVIDERS` | *required* | Providers to configure |
| `NEEDLE_POD_DEFAULT_PROVIDER` | first listed | Provider for the default adapter |
| `NEEDLE_POD_HARNESSES` | all seven | Harnesses to configure |
| `NEEDLE_POD_DEFAULT_HARNESS` | first listed | Harness for the default adapter |
| `NEEDLE_POD_WORKSPACES` | — | Repos to clone (names or full URLs) |
| `NEEDLE_POD_PINNED_WORKSPACES` | empty | Pin list; **empty preserves roaming** |
| `NEEDLE_POD_GIT_TOKEN` | — | Forgejo push credential |
| `NEEDLE_POD_CLONE_DEPTH` | `1` | `0` for full history |
| `NEEDLE_POD_LOG_RETENTION_DAYS` | `3` | `file_sink.retention_days` |
| `NEEDLE_POD_LOG_MAX_MB` | `512` | Size ceiling for the prune sweep |
| `NEEDLE_POD_HEARTBEAT_MAX_AGE` | `900` | Stale-claim reaper window |
| `NEEDLE_POD_HARNESS_VERSIONS` | — | Declared ceiling, `name=version`; `latest` is refused |
| `NEEDLE_POD_PROBE_ON_START` | `false` | Probe every harness at startup |

`NEEDLE_POD_PINNED_WORKSPACES` deserves care. Empty means recursive discovery
under the workspace root, which is the fleet default and what preserves roaming.
Non-empty disables auto-discovery, and NEEDLE emits a WARN naming the pinned
repos precisely so this is visible rather than discovered through missing beads.

## What is deliberately not here

Per the agreed scope, this pass covers repo artifacts only:

- **No `k8s/agent-sandbox/needle-pod/` manifests** — Deployment, ConfigMap and
  ExternalSecrets belong in `declarative-config`.
- **No `needle-pod-build` WorkflowTemplate** — iad-ci CI, also declarative-config.
- **No SIGTERM drain** — that is a NEEDLE change.

## Not yet validated

Everything above is verified by construction, static parsing, or registry
lookup. **The image has never been built** — there is no CI to build it yet, and
no cluster registration to run it on. Specifically unproven:

- that all seven harnesses install cleanly in one image
- the real image size, and pull time on a cold spot node
- that each harness's non-interactive invocation works against a BYOK endpoint
  (the `droid --auto high`, `goose --no-session` and `codex exec` flag sets are
  from current documentation, not from a run)
- pi's custom-provider path beyond conventional env vars; its `models.json`
  shape was not established

What *is* validated: `render.py` produces 14 adapters that parse as YAML with no
unsubstituted placeholders; the emitted TOML, JSON and YAML all parse; no token
value reaches disk; and every shell script passes `bash -n` with the helper
functions exercised directly.
