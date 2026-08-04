# Fleet Patterns to Copy When Bootstrapping agent-sandbox

Surveyed from `declarative-config` on 2026-08-03/04. Nothing here is novel — the
point of this document is that **Phase 0 is pattern-copying, not design.**
`iad-options` is the most recent full bootstrap and the cleanest template.

## Reference tree — `k8s/iad-options/`

```
cert-manager/     cert-manager-application.yml, clusterissuer.yml, namespace.yml
devpod-observer/  kubectl-proxy.yml, namespace.yml, rbac.yml
external-secrets/ cluster-secret-store.yml, external-secrets-application.yml,
                  namespace.yml, openbao-egress.yml,
                  openbao-eso-token-secret.yml.template
tailscale/        deployment-application.yml, namespace.yml,
                  tailscale-secret.yml.template
traefik/          namespace.yml, tailscale-service.yml, traefik-application.yml
```

## ArgoCD cluster registration

The cluster is registered by an `ExternalSecret` in `k8s/rs-manager/argocd/`
(see `iad-kalshi-cluster-externalsecret.yml`), which builds a secret labelled
`argocd.argoproj.io/secret-type: cluster`.

One-time setup on the target cluster:

```bash
kubectl create serviceaccount argocd-manager -n argocd-manager
kubectl create clusterrolebinding argocd-manager \
  --clusterrole=cluster-admin --serviceaccount=argocd-manager:argocd-manager
TOKEN=$(kubectl create token argocd-manager -n argocd-manager --duration=8760h)

bao kv put secret/rs-manager/<cluster>/cluster server="https://hcp-....spot.rackspace.com" token="$TOKEN"
```

The ESO policy on rs-manager OpenBao must then grant:

```
path "secret/data/rs-manager/<cluster>/*"     { capabilities = ["read"] }
path "secret/metadata/rs-manager/<cluster>/*" { capabilities = ["read", "list"] }
```

The `config` field embeds `caData` inline. For agent-sandbox that CA is already
known — see `agent-sandbox-cluster-state.md`; the in-cluster `kube-root-ca.crt`
validates the HCP endpoint, so `insecure: false` is achievable from day one
rather than being carried as debt.

## Two-tier ArgoCD sync

Both tiers are needed; each alone does nothing useful.

1. **ApplicationSet** `manifest-appset-<cluster>` — git generator over
   `k8s/<cluster>/*`, `include: {*.yaml,*.yml}`,
   `exclude: {ignore/*,*application.yml}`, naming apps `{{path.basename}}-ns-<cluster>`,
   `syncPolicy.automated` with `prune`, `selfHeal`, `allowEmpty`, and
   `CreateNamespace=true`.
2. **App-of-apps** `<cluster>-application.yml` at `k8s/rs-manager/` level — syncs
   only `*application.yml` files into the ArgoCD namespace.

This is why any Helm chart must be named `*-application.yml`: the ApplicationSet
*excludes* that pattern and the app-of-apps *includes* it. A misnamed file is
silently never deployed.

## Reaching rs-manager OpenBao from a managed cluster

A selector-less Service annotated with the tailnet FQDN, plus a
`ClusterSecretStore` pointed at it:

```yaml
# external-secrets/openbao-egress.yml
metadata:
  name: openbao
  namespace: external-secrets
  annotations:
    tailscale.com/tailnet-fqdn: traefik-rs-manager.tail1b1987.ts.net
spec:
  ports: [{ name: http, port: 8200, targetPort: 8200 }]
```

```yaml
# external-secrets/cluster-secret-store.yml
provider:
  vault:
    server: "http://openbao.external-secrets.svc.cluster.local:8200"
    path: "secret"
    version: "v2"
    auth:
      tokenSecretRef: { name: openbao-eso-token, namespace: external-secrets, key: token }
```

The bootstrap token is a periodic 720h token created by hand. `iad-ci` has since
migrated to Kubernetes auth, and the `iad-options` file carries a comment showing
the target shape — worth adopting directly for agent-sandbox, since the k8s-auth
pattern was already proven on that cluster during the OpenBao experiment.

## Ingress — Traefik is the single connection point

Not "one exposure to spend": Traefik is *the* ingress, and everything else routes
through it, so there is one path to control and one to monitor.

- **Traefik**: chart `39.0.6`, `service.type: ClusterIP` (no LoadBalancers on
  Spot), entrypoints `web` (unexposed), `websecure` 8443, `kubectl-tcp` 8001,
  `vpn` 8444, plus `--entrypoints.vpn.http.tls=true`. Set
  `providers.kubernetesCRD.allowCrossNamespace: true` when an IngressRoute must
  target a service in another namespace.
- **The one exposure**: a `traefik-tailscale` Service in the `traefik` namespace
  with `tailscale.com/expose: "true"` and `tailscale.com/hostname: traefik-<cluster>`,
  publishing ports 8444 and 8001.
- **Per-service routes**: an `IngressRoute` on the `vpn` entrypoint. Every one
  needs a real `Certificate` — there is no wildcard or default fallback in this
  fleet, which is why cert-manager is mandatory rather than optional.
- **cert-manager**: chart `1.20.0`, `installCRDs=true`,
  `startupapicheck.enabled=false`, with a `letsencrypt-cloudflare` ClusterIssuer
  using a DNS01 solver whose token comes from OpenBao via ESO.
- **DNS**: `tailnet-external-dns` on rs-manager holds an explicit `DNSEndpoint`
  per hostname (`k8s/rs-manager/tailnet-external-dns/dnsendpoints.yaml`), each an
  A record pointing at a Tailscale IP. The IP isn't known until the operator
  creates the proxy, so this entry is necessarily a **post-deploy** step.

Ordering that falls out of the above:

```
tailscale operator → external-secrets (+ OpenBao egress)
                   → cert-manager + ClusterIssuer
                   → traefik (vpn TLS)
                   → any service reachable
```

## Observability — VictoriaLogs

- Chart `victoria-logs-single` `0.11.17`, image `v1.36.1-scratch`. Deployed on
  ardenone-manager and iad-kalshi; iad-ci has the IngressRoute pattern.
- The chart **bundles Vector** as a DaemonSet agent (`kubernetes_logs` source →
  remap transform adding `cluster`/`app`/`namespace` → elasticsearch bulk sink at
  `http://vlogs-server:9428/insert/elasticsearch`).
- `fullnameOverride: vlogs` is used fleet-wide despite the repo's general
  no-override rule — it is load-bearing, because the Vector sink URL addresses
  `vlogs-server` by that name.

### Retention units — a real trap

Chart docs: *"Possible units character: h(ours), d(ays), w(eeks), y(ears), **if no
unit character specified - month**."*

So bare integers in this repo mean **months**:

| Cluster | Value | Actually means |
|---|---|---|
| ardenone-manager | `retentionPeriod: 1` | 1 month |
| iad-ci | `retentionPeriod: 7` | **7 months** |

And confirmed against the live iad-ci instance, both disk caps are off fleet-wide:

```
flag{name="retention.maxDiskSpaceUsageBytes", value="0", is_set="false"}
flag{name="retention.maxDiskUsagePercent",    value="0", is_set="false"}
```

Always write an explicit unit, and set `retentionDiskSpaceUsage` (renders to
`--retention.maxDiskSpaceUsageBytes`, default unit GiB) as a hard second bound.

## Scheduled work and image promotion

- **CronWorkflows already run on iad-ci** — `armor-drift-check-daily`,
  `hoop-security-scan-weekly`, `pdftract-nightly-fuzz`,
  `profile-readme-stats-sync-daily`. Argo CronWorkflows are not Kubernetes
  CronJobs, so the repo-wide Job/CronJob ban does not apply to them.
- **Build-and-bump exists** — `telegram-claude-bridge-build` and
  `news-trader-build` build an image *and commit the new digest back into
  declarative-config*. The manual equivalent shows up in the log as
  `chore(spaxel): bump image to 0.2.2`.

Together these mean a nightly image rebuild that promotes itself is a template
copy, not new machinery — and no version-detection CI is required anywhere.

## Reloader — ConfigMap change triggers rollout

Stakater Reloader, chart `2.2.9`, is deployed on rs-manager and ardenone-manager
with roughly six consumers. Annotate a workload with
`reloader.stakater.com/auto: "true"` (or name specific secrets/configmaps) and a
ConfigMap edit restarts it — no live `kubectl` mutation needed, so a version
declared in a ConfigMap becomes a GitOps-native update mechanism.

## Storage constraints on Rackspace Spot

- Always `sata` / `sata-large`, always with `storageClassName` set explicitly —
  the cluster default is `ssd`, which is not permitted.
- **`sata` PVCs must be 5–20 GB.** A 2Gi request is rejected with
  `Invalid input: 'size' parameter must be between 5 and 20`.
- Cinder classes are effectively ReadWriteOnce.

## Working in declarative-config

The repo is written concurrently by workers on multiple machines. Its own
`CLAUDE.md` mandates `git pull --rebase origin main` before touching anything and
an immediate push after each commit — never merge, never force-push.

In practice a dirty tree from another worker is normal, so
`git pull --rebase --autostash` is the reliable form. Beware of masking the pull's
exit code behind a pipe (`git pull ... | tail`) — the pipeline reports `tail`'s
status, so a failed pull silently proceeds to commit on a stale base.

Pre-commit hooks (plaintext-Secret rejection, gitleaks) are **not** propagated by
clone; run `pre-commit install` once per clone or that clone is unprotected.
