# Phase 0 — Concrete Bootstrap Deliverables

What must exist before anything can be deployed to `agent-sandbox` the sanctioned
way. Patterns to copy are catalogued in
`../research/fleet-bootstrap-patterns.md`; observed cluster state is in
`../research/agent-sandbox-cluster-state.md`.

## Why this gates everything

All cluster changes go through `declarative-config` + ArgoCD. agent-sandbox is
**not registered** — 0 of 107 Applications target it, no `cluster-agent-sandbox`
secret exists in rs-manager's `argocd` namespace. Until registration lands there
is no sanctioned path to deploy a worker at all.

The one-time actions below (creating a cluster-admin ServiceAccount, writing to
OpenBao) are the standard bootstrap exception every other cluster went through.
They need explicit human go-ahead — they are live, and they mint a credential.

## Ordering is load-bearing

Not a checklist to work in any order; each step's prerequisite is real:

```
tailscale operator → external-secrets (+ OpenBao egress)
                   → cert-manager + ClusterIssuer  (needs the Cloudflare token via ESO)
                   → traefik                       (vpn entrypoint needs a real Certificate)
                   → VictoriaLogs reachable
                   → worker pods
```

An earlier version of this plan proposed skipping Traefik and cert-manager on the
grounds that workers are outbound-only. That was wrong: **Traefik is the cluster's
single ingress connection point**, so anything that ever needs to be reached goes
behind it, and every `vpn` IngressRoute requires a real Certificate — which drags
cert-manager, the ClusterIssuer, the Cloudflare DNS01 token, and therefore ESO
back in. See `deployment-shape-and-lifecycle.md` for the rationale in full.

## One-time actions on the cluster

```bash
kubectl create serviceaccount argocd-manager -n argocd-manager
kubectl create clusterrolebinding argocd-manager \
  --clusterrole=cluster-admin --serviceaccount=argocd-manager:argocd-manager
TOKEN=$(kubectl create token argocd-manager -n argocd-manager --duration=8760h)
```

Then write to rs-manager OpenBao:

| Path | Contents |
|---|---|
| `secret/rs-manager/agent-sandbox/cluster` | `server`, `token` |
| `secret/rs-manager/agent-sandbox/cloudflare/api` | `CF_API_TOKEN` (DNS01 solver) |

And extend the ESO policy on rs-manager OpenBao:

```
path "secret/data/rs-manager/agent-sandbox/*"     { capabilities = ["read"] }
path "secret/metadata/rs-manager/agent-sandbox/*" { capabilities = ["read", "list"] }
```

## Files in declarative-config

### `k8s/rs-manager/`

| File | Purpose |
|---|---|
| `argocd/agent-sandbox-cluster-externalsecret.yml` | Registers the cluster. Use the real CA (below) — `insecure: false` |
| `argocd/agent-sandbox-applicationset.yml` | `manifest-appset-agent-sandbox` over `k8s/agent-sandbox/*` |
| `agent-sandbox-application.yml` | App-of-apps for `*application.yml` |
| `tailnet-external-dns/dnsendpoints.yaml` | **post-deploy** — A record for `victorialogs-agent-sandbox-ts.ardenone.com` |

The DNSEndpoint is necessarily last: its target is the Tailscale IP the operator
assigns to `traefik-agent-sandbox`, which does not exist until Traefik is up.

### `k8s/agent-sandbox/`

| Directory | Status |
|---|---|
| `tailscale/` | to write — operator + authkey secret template |
| `external-secrets/` | to write — namespace, Application, `openbao-egress.yml`, `ClusterSecretStore` |
| `cert-manager/` | **written** — Application 1.20.0, `letsencrypt-cloudflare` ClusterIssuer, namespace |
| `traefik/` | **written** — Application 39.0.6, `tailscale-service.yml` (the single exposure), `victorialogs-ingressroute.yml`, namespace |
| `monitoring/` | **written** — VictoriaLogs with bounded retention, namespace |
| `CLAUDE.md` | to write — node shape and per-pod ceilings, per fleet convention |
| `needle-pod/` | Phase 4 |

Everything already written is **inert** until the ApplicationSet and app-of-apps
exist — nothing currently globs `k8s/agent-sandbox/*`.

## Use the real cluster CA — do not carry `insecure-skip-tls-verify`

Verified 2026-08-03: the CA in the in-cluster `kube-root-ca.crt` ConfigMap
validates the HCP endpoint (`curl --cacert` → 200; the system CA store fails with
exit 60). The local kubeconfig currently sets `insecure-skip-tls-verify: true`
only because the Spot `generate-kubeconfig` endpoint's request contract was never
established.

That single value does two jobs: it retires the flag locally, and it supplies the
base64 `caData` the ArgoCD cluster ExternalSecret needs. There is no reason to
register the cluster with `insecure: true` and fix it later.

## Deliberately out of scope for Phase 0

- **`devpod-observer` / kubectl-proxy.** kubectl access already works via the
  OpenBao-minted exec-credential kubeconfig. The Traefik `kubectl-tcp` entrypoint
  is provisioned anyway, so adding the observer later needs no ingress change.
- **The OpenBao experiment rig.** `openbao-experiment` is a throwaway migration
  rehearsal holding a 10Gi `sata` PVC. Tear it down when that work concludes:
  `helm uninstall openbao -n openbao-experiment && kubectl delete ns openbao-experiment`.
- **The `needle-pod` namespace currently on the cluster.** It holds only
  `bao-test`, a leftover from the OpenBao k8s-auth validation. The name is
  coincidental; it is not a deployment.
