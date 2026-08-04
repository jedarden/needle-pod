# agent-sandbox — Observed Cluster State

Empirical probe, 2026-08-03. Everything here was read off the live cluster via
`~/.kube/agent-sandbox.kubeconfig`. Re-verify before relying on it — Spot
cloudspaces change under you.

## Identity and reachability

| | |
|---|---|
| API server | `https://hcp-98f6bac3-8e10-4def-a5c6-ce0364d836d8.spot.rackspace.com` |
| Org | `apexalgo-agent` (`org-knyiltp8zznvkz5g`) |
| Region | ORD |
| Kubernetes | v1.34.9 |
| Phase | Ready / Healthy |

Access from the EX44 is **credential-free and regenerate-on-demand**. The
kubeconfig holds only the server address and an exec-credential reference to
`~/.kube/agent-sandbox-credential.py`, which reads a Spot refresh token from
OpenBao using a least-privilege token (`~/.kube/agent-sandbox-vault-token`,
policy `agent-sandbox-spot-ro`) and mints a fresh 24h `id_token` per invocation.
No cluster credential is written to disk.

> The plan's Component 1 step 1 ("fetch a kubeconfig from the Spot UI") and the
> Architecture section's claim that no kubeconfig exists are both **superseded**
> as of 2026-08-02.

## Node shape

One worker node, `prod-instance-17851864681050006`, Ready 6d22h at probe time.

| Resource | Capacity |
|---|---|
| CPU | 4 |
| Memory | 7608292Ki (~7.25 GiB) |
| Ephemeral storage | 101430960Ki (~96.7 GiB) |
| Max pods | 110 |

- OS: Ubuntu 22.04, kernel 6.8.0-134, containerd 2.2.1
- Labels: `node.kubernetes.io/instance-type=compute1-8`,
  `topology.kubernetes.io/region=ORD`,
  `nodepool.ngpc.rxt.io/name=88c5e399-70ac-4825-a40f-7348395daf52`,
  `topology.cinder.csi.openstack.org/zone=nova`
- **No taints** — workloads schedule without tolerations.

Allocated at probe time: CPU requests 1050m (30%) / limits 4500m (128%);
memory requests 916Mi (14%) / limits 2632Mi (41%).

The ~96 GiB of ephemeral storage is the single most useful number here — it
makes a fat multi-toolchain worker image affordable on disk, and makes
`emptyDir` a viable alternative to per-pod PVCs.

## Storage classes

| Name | Provisioner | Notes |
|---|---|---|
| `sata` | `cinder.csi.openstack.org` | use this |
| `sata-large` | `cinder.csi.openstack.org` | use this |
| `ssd` | `cinder.csi.openstack.org` | **cluster default — must override explicitly** |
| `ssd-large` | `cinder.csi.openstack.org` | avoid |
| `spot-ceph` | `rbd.csi.ceph.com` | present, unevaluated |

All are `Delete` / `Immediate` / no volume expansion. Cinder classes are
effectively ReadWriteOnce.

Known constraint from the OpenBao experiment on this cluster: **Rackspace Spot
`sata` PVCs must be 5–20 GB.** A 2Gi request is rejected with
`Invalid input: 'size' parameter must be between 5 and 20`.

Because `ssd` is the cluster default, every PVC must set `storageClassName`
explicitly or it silently lands on the wrong class.

## What is NOT installed

No CRDs matched `tailscale|external-secret|argo|sealed|keda|cert-manager|snapshot`.
Namespaces present are only: `calico-apiserver`, `calico-system`, `default`,
`kube-node-lease`, `kube-public`, `kube-system`, `needle-pod`,
`openbao-experiment`, `projectsveltos`, `tigera-operator`.

So: CNI and projectsveltos, and nothing else. No Tailscale operator, no
external-secrets, no ArgoCD agent, no cert-manager, no VolumeSnapshot CRDs.

## Not registered with ArgoCD

Checked against rs-manager's ArgoCD via the read-only proxy: **0 of 107
Applications** target this cluster, and no `cluster-agent-sandbox` secret exists
in the `argocd` namespace. The registered clusters are `iad-ci`, `iad-kalshi`,
`iad-options`, and `ord-devimprint`.

There is also no `k8s/agent-sandbox/` directory in `declarative-config`.

Consequence: under the standing rule that all cluster changes go through
declarative-config + ArgoCD, **there is currently no sanctioned way to deploy
anything here.** Registration is the gating prerequisite, not a nicety.

## Cluster CA — resolves the TLS gap and supplies ArgoCD's `caData`

The kubeconfig currently sets `insecure-skip-tls-verify: true`, because the
public `POST /apis/auth.ngpc.rxt.io/v1/generate-kubeconfig` endpoint's request
body contract was never established (returned 400 for every tried variant).

**Verified 2026-08-03:** the CA in the in-cluster `kube-root-ca.crt` ConfigMap
validates the HCP endpoint directly.

```
subject=CN=kubernetes  issuer=CN=kubernetes
notBefore=Jul 23 14:22:45 2026 GMT   notAfter=Jul 20 14:27:45 2036 GMT

curl --cacert <that CA> https://hcp-98f6bac3-....spot.rackspace.com/version  → 200
curl               (system CA store)                                          → exit 60
```

This one value does two jobs:

1. Drops `insecure-skip-tls-verify` from the local kubeconfig.
2. Supplies the base64 `caData` that the ArgoCD cluster `ExternalSecret`
   requires (see `fleet-bootstrap-patterns.md`).

## Existing occupants

- `openbao-experiment/openbao-0` — the throwaway OpenBao declarative-migration
  rehearsal rig (helm `openbao/openbao` 0.26.1, OpenBao 2.5.1, `file` storage on
  a 10Gi `sata` PVC). Holds a PVC; tear down with
  `helm uninstall openbao -n openbao-experiment && kubectl delete ns openbao-experiment`
  when the rehearsal is finished.
- `needle-pod/bao-test` — a leftover from that experiment's k8s-auth validation,
  **not** a real needle-pod deployment. Its 15 restarts are benign: exit code 0,
  reason `Completed`, on a 1-hour sleep with `restartPolicy: Always`. The
  namespace name is coincidental and should not be mistaken for progress.

## Capacity envelope

warden's deployed config (`k8s/rs-manager/warden/deployment.yaml`) allows
`ch.vs1.large-ord` — a comment confirms this matches the real agent-sandbox
pool, resolving the class-mismatch question — with a max bid of `0.01` and a
node cap of 10.

Working estimate: a worker (agent CLI + toolchain + clone) plausibly needs
2–3 GiB, so **2–3 workers per node, ~20–30 workers at the 10-node ceiling**.
That is comparable to the EX44's current `max_workers: 21`. Fully scaled,
10 × $0.01/hr ≈ **$0.10/hr ≈ $73/month**.

Both the per-node worker density and the real memory footprint are estimates
and are among the first things the initial deployment should measure.
