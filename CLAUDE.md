# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GitOps-managed Kubernetes homelab. Talos Linux (8-node cluster, IPs 10.1.20.11–.18) with Flux CD for GitOps, Cilium as CNI, Envoy Gateway (Gateway API) for ingress, Rook-Ceph for storage, and app groups spanning media, home automation, game servers (Agones + Gameplane), LLM tooling, and observability.

**Stack:** Talos Linux → Kubernetes → Flux CD → Helm/Kustomize

**Hosting:** primary repo is self-hosted Forgejo (`git.noms.tv/Homelab/Home-Ops`), mirrored to GitHub. Use the `tea` CLI for Forgejo operations, not `gh`.

## Common Commands

All commands use `just` (task runner) — run `just -l` to list available recipes. `.justfile` at the repo root includes `bootstrap` and `kube` (from `kubernetes/mod.just`) modules.

### Bootstrap (initial cluster setup)

```bash
just bootstrap cluster        # Full end-to-end bootstrap (base manifests + CRDs -> core apps via helmfile)
```

Internally this chains: waiting for nodes to register, applying `bootstrap/kustomize/apps` (namespaces, External Secrets) + CRDs from `bootstrap/helmfile/crds.yaml`, then `helmfile sync` on `bootstrap/helmfile/apps.yaml` for the core apps Flux itself depends on (CNI, etc.) before Flux takes over. Talos node provisioning/config management is not handled from this repo.

### Kubernetes Operations (`just kube ...`)

```bash
just kube apply-ks <ns> <ks>        # Render (via flux-local) and apply a local Flux Kustomization
just kube delete-ks <ns> <ks>       # Render and delete a local Flux Kustomization
just kube sync <resource> [ns] [name]  # Force-reconcile hr|ks|gitrepo|ocirepo|es
just kube browse-pvc <ns> <claim>   # Scale down owner, mount PVC in a throwaway pod, scale back up
just kube debug-node <node>         # kubectl debug into a node
just kube prune-pods                # Delete Failed/Pending/Succeeded pods cluster-wide
just kube restore <ns> <app> [previous]  # Manual VolSync restore of a PVC (suspends ks/hr, scales down, restores, resumes)
just kube snapshot                  # Trigger all VolSync ReplicationSources manually
just kube volsync <suspend|resume>  # Suspend/resume the VolSync controller
just kube view-secret <ns> <secret> # View a decoded Secret
```

## Architecture

```
kubernetes/
├── apps/                    # Application deployments by group (== namespace, one dir per group)
│   ├── cert-manager/        # TLS certificate issuance
│   ├── databases/           # CloudNativePG (shared postgres cluster + pooler)
│   ├── default/             # General-purpose apps (e.g. actual-budget)
│   ├── external-secrets/    # External Secrets Operator + 1Password Connect
│   ├── flux-system/         # Flux operator/instance install
│   ├── forgejo/             # Self-hosted Forgejo + runners
│   ├── games/                # Agones + game server Fleets/GameServers (Gameplane control panel)
│   ├── home/                 # Home automation
│   ├── kopiur-system/        # Backup/snapshot system (kopiur)
│   ├── kube-system/          # Cilium, CoreDNS, metrics-server
│   ├── llm/                   # LLM-related workloads
│   ├── media/                 # Media stack
│   ├── network/               # Envoy Gateway, external-dns, etc.
│   ├── observability/         # Prometheus/Grafana-style stack
│   ├── rook-ceph/             # Ceph storage (ceph-block StorageClass)
│   ├── security/              # Security tooling
│   └── virtualization/        # KubeVirt/virtualization
├── components/               # Reusable Kustomize components
│   ├── anubis/                # (proof-of-work bot-mitigation proxy component)
│   ├── cluster-secrets/       # Cluster-wide ExternalSecret (e.g. SECRET_DOMAIN substitution)
│   ├── kopiur/                 # backup/, secret/ — wired into app-template PVCs
│   ├── oidc/                   # Shared OIDC wiring
│   ├── postgres/               # base/, cert/, pass/ — per-app CNPG Database/DatabaseRole provisioning
│   └── zeroscaler/             # Scale-to-zero component
└── flux/cluster/ks.yaml       # Root Flux Kustomization -> ./kubernetes/apps

bootstrap/
├── helmfile/                 # helmfile-driven CRDs + core apps installed before Flux exists
│   ├── crds.yaml
│   ├── apps.yaml
│   └── defaults.yaml
├── kustomize/apps/            # Namespaces + External Secrets applied before Flux bootstraps
└── mod.just                   # `just bootstrap` recipes

Scripts/
├── Kubernetes/                 # PVC migration/extraction helper scripts
└── Renovate/                    # postUpgradeTasks scripts (e.g. regen-agones-crds.sh)
```

## Key Patterns

**App directory layout** — `kubernetes/apps/<group>/<app>/`:

```
kubernetes/apps/<group>/<app>/
├── ks.yaml              # Flux Kustomization: metadata.namespace=<group>,
│                         # spec.targetNamespace=<namespace the app deploys into>,
│                         # spec.path=./kubernetes/apps/<group>/<app>/app
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    ├── ocirepository.yaml or helmrepository.yaml
    ├── httproute.yaml        # only for non-app-template charts (see below)
    └── externalsecret.yaml   # only if the app needs secrets
```

Each `<group>` also has a `namespace.yaml` (with `kustomize.toolkit.fluxcd.io/prune: disabled`) and a `kustomization.yaml` with `namespace: <group>` and a `resources:` list of `./namespace.yaml` followed by every app's `./<app>/ks.yaml`. Add a new app by creating its directory and appending its `ks.yaml` to that list.

**HelmRelease shapes** — two patterns coexist:

1. **bjw-s app-template** (default for most regular apps). `OCIRepository` pointed at `oci://ghcr.io/bjw-s-labs/helm/app-template`; `HelmRelease` uses `chartRef`. `values.route.<name>` auto-generates the HTTPRoute — no hand-written `httproute.yaml` needed. Example: `kubernetes/apps/default/actual-budget/`.
2. **Native/foreign chart** (the app ships its own chart). Prefer `OCIRepository` + `chartRef` when the chart is published as an OCI artifact (Renovate-friendly, tracked as a `docker` datasource) — e.g. `kubernetes/apps/games/gameplane/`; fall back to `HelmRepository` + `chart.spec.version` for classic chart repos — e.g. `kubernetes/apps/games/agones/`. These don't generate a Gateway API route — write `httproute.yaml` by hand against whatever Service the chart creates.

**Ingress / Gateway API** — Gateway API via Envoy Gateway only; there is no ingress-nginx and no `kind: Ingress` anywhere in this repo. Two shared `Gateway`s in `kubernetes/apps/network/envoy-gateway/app/`: `envoy-internal` (internal only) and `envoy-external` (internet-exposed). Both terminate TLS with one shared wildcard cert (cert-manager + Cloudflare DNS-01) — apps never need their own cert-manager annotations. An app just adds:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>
spec:
  hostnames:
    - <app>.${SECRET_DOMAIN}
  parentRefs:
    - name: envoy-internal   # or envoy-external, or both
      namespace: network
      sectionName: https
  rules:
    - backendRefs:
        - name: <service>
          port: <port>
```

Default to `envoy-internal` only for anything with admin/privileged capabilities; add `envoy-external` only when the app is meant to be public. `${SECRET_DOMAIN}` is substituted cluster-wide via the `cluster-secrets` component.

**Secrets** — External Secrets Operator + 1Password Connect for all app secrets:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
spec:
  secretStoreRef: { kind: ClusterSecretStore, name: onepassword-connect }
  dataFrom:
    - extract: { key: <1Password item name> }
```

**Storage** — Rook-Ceph provides `ceph-block` (RBD, RWO); set `storageClassName: ceph-block` explicitly on hand-declared PVCs. app-template apps typically use `persistence.<name>.existingClaim: "{{ .Release.Name }}"` combined with the `components/kopiur/backup` component instead of declaring the PVC directly.

**Database** — one shared CloudNativePG cluster (`postgres`, namespace `databases`) plus a pooler Service; apps do not run their own CNPG `Cluster`. The `components/postgres/{base,cert,pass}` Kustomize components provision a per-app `Database`/`DatabaseRole` and a `<app>-postgres` secret (`url`/`dsn` keys) declaratively.

**Backups** — `kopiur` (namespace `kopiur-system`) via the `components/kopiur/backup` Kustomize component, wired for app-template's `persistence.<name>.existingClaim` pattern; VolSync also runs cluster-wide for PVC replication/snapshots (see `just kube restore` / `just kube snapshot`).

**Renovate** — `.renovaterc.json5` extends `home-operations/renovate-presets`; auto-discovers `HelmRelease`/`HelmRepository`/`OCIRepository` with no extra config as long as the shapes above are followed. A few packages have custom `postUpgradeTasks` (e.g. Agones CRDs regenerated via `Scripts/Renovate/regen-agones-crds.sh`).

**Game servers** (`kubernetes/apps/games/`) — Agones manages `Fleet`/`GameServer` objects in the `games` namespace (`gameservers.namespaces: [games]`). Raw UDP/TCP game traffic uses `type: LoadBalancer` Services with Cilium LB-IPAM annotations (`lbipam.cilium.io/ips: <ip>`) — this bypasses Gateway API entirely, which is HTTP(S)-only. Gameplane's control plane (operator/api/web) also runs in `games`, but its own `GameServer` CRD workloads land in a separate `gameplane-games` namespace (`values.gamesNamespace`) so its default-deny `NetworkPolicies` don't affect Agones-managed pods sharing `games`.

**GitOps Flow** — push to `main` → Flux (`flux-system`, watching `GitRepository: flux-system`) reconciles the root `Kustomization` in `kubernetes/flux/cluster/ks.yaml` → cascades through every app's `ks.yaml`.

## Validation

There is no pre-commit config or CI lint workflow in this repo currently (`.forgejo/workflows/` only has `renovate.yaml` and `image-pull.yaml`). Before proposing changes as done, validate manually:

```bash
kubectl kustomize kubernetes/apps/<group>/<app>/app   # Kustomize build for one app
kubectl kustomize kubernetes/apps/<group>              # Kustomize build for a whole group
```

`kubernetes/mod.just`'s private `render-local-ks` recipe uses `flux-local` (via Docker) to render a Flux Kustomization the way Flux itself would, for `apply-ks`/`delete-ks`.

## Conventions

- Every manifest starts with `---` followed by a `# yaml-language-server: $schema=...` comment pinning the resource's JSON schema (mostly `kubernetes-schemas.pages.dev`, some `k8s-schemas.home-operations.com`, and app-template HelmReleases use the bjw-s chart's own schema).
- No repo-enforced field-ordering convention beyond following the style of neighboring files — match the nearest existing example rather than inventing a new layout.
- Avoid YAML anchors/aliases (`&anchor`/`*alias`) in new manifests — write values out literally, even when it duplicates a value. Some older files still use them; don't propagate the pattern into new ones.

There's also a `memory/` directory at the repo root (git-tracked, separate from Claude's global memory store) holding a couple of standing project notes for Claude sessions working in this repo — check it alongside this file.
