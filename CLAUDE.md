# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All Ansible commands must run from `cluster/` (uses `ansible.cfg` there for inventory, SSH key, etc.):

```bash
# Always export kubeconfig before kubectl/helm commands
export KUBECONFIG=~/.kube/config-k8s-va

# Stage 1 – prepare nodes (system ansible ok)
make host-prep
# equivalent: cd cluster && ansible-playbook -i inventory/prod/hosts.yaml playbooks/00-host-prep.yaml

# Stage 2 – bootstrap cluster (Kubespray, ~20–40 min)
# REQUIRES cluster/.venv with ansible-core 2.17.x — Kubespray v2.30 hard-blocks 2.18+
make bootstrap

# Stage 3 – fetch kubeconfig to ~/.kube/config-k8s-va (system ansible ok)
make post-bootstrap

# Stage 4 – MetalLB → ingress-nginx → cert-manager → Argo CD
make bootstrap-platform

# Apply node labels and taints from host_vars (idempotent, run after adding/changing host_vars)
make label-nodes

# DESTRUCTIVE: tear down cluster (5-second pause then runs kubespray reset)
make reset

# Lint Ansible playbooks and microservice Helm chart
make lint
```

Create the venv once (only needed for `make bootstrap`):
```bash
cd cluster
python3 -m venv .venv
.venv/bin/pip install ansible==10.7.0 jmespath netaddr cryptography
```

Ad-hoc Ansible:
```bash
cd cluster && ansible -i inventory/prod/hosts.yaml all -m ping
cd cluster && ansible -i inventory/prod/hosts.yaml all -m shell -a "systemctl is-active containerd"
```

## Environment / toolchain

- **Ansible**: system ansible (`brew install ansible`, ansible-core 2.18) for all steps **except** `make bootstrap`. For bootstrap, Kubespray v2.30 hard-requires ansible-core `2.17.3 ≤ x < 2.18.0` — use `cluster/.venv` (see above).
- **SSH key**: hardcoded in `cluster/ansible.cfg` → `ssh_args` → `-i /Users/ai_ovsyannikov/.ssh/id_rsa_ansible2`
- **Kubespray**: git submodule at `cluster/kubespray/` (branch v2.30.0). Init with `git submodule update --init --recursive`.

## Architecture overview

### Infrastructure (Proxmox VMs, Ubuntu 24.04)

| Nodes | IPs | Role |
|---|---|---|
| cp-1/2/3 | 176.113.118.177–179 | control-plane (stacked etcd) |
| worker-1/2 | 176.113.118.180–181 | workers |
| kube-vip VIP | 176.113.118.190 | API server HA endpoint |
| MetalLB pool | 176.113.118.185–189 | LoadBalancer IPs (ingress-nginx got .185) |

Kubernetes 1.34.3 · Calico CNI (VXLAN, `interface=eth0`) · IPVS kube-proxy · containerd 2.2.x

### GitOps: App-of-Apps pattern

```
platform/bootstrap/argocd/root-app.yaml   ← applied once by bootstrap.sh
  └─ watches: platform/argocd-apps/        ← FLAT directory, no recurse
       ├─ _root.yaml                        ← AppProject "platform" (lists all allowed Helm repos)
       ├─ app-storage.yaml      (nfs-csi)
       ├─ app-longhorn.yaml     (Longhorn block storage)
       ├─ app-minio.yaml        (MinIO object storage)
       ├─ app-vault.yaml
       ├─ app-eso.yaml
       ├─ app-prometheus.yaml
       ├─ app-loki.yaml
       ├─ app-promtail.yaml
       ├─ app-backup.yaml
       ├─ app-namespaces.yaml
       └─ app-policies.yaml

platform/apps/<component>/                 ← Helm values files referenced by argocd-apps/
```

Adding a new ArgoCD app: create `platform/argocd-apps/app-<name>.yaml` (Application resource) and put values under `platform/apps/<name>/`. Do NOT use `directory.recurse: true` on the argocd-apps path — it causes ArgoCD to pick up unrelated manifests.

When using multi-source Applications (`sources:` array), always add the github repo with `ref: values` as the first source so Helm valueFiles can reference `$values/platform/apps/...`.

### Platform components

| Component | Namespace | Chart version | Notes |
|---|---|---|---|
| MetalLB | metallb-system | 0.14.5 | L2 mode |
| ingress-nginx | ingress-nginx | 4.10.1 | |
| cert-manager | cert-manager | 1.15.1 | ServiceMonitor disabled until Prometheus ready |
| Argo CD | argocd | 7.3.4 (v2.11) | |
| kube-prometheus-stack | monitoring | 61.7.1 | ServerSideApply=true required for large CRDs |
| Loki | monitoring | — | SingleBinary mode; read/write/backend replicas: 0 |
| Vault | vault | 0.28.0 | 3-replica Raft HA; injector disabled (use ESO) |
| External Secrets Operator | external-secrets | — | Connects to Vault |
| Velero | velero | — | Requires `velero-credentials` secret; S3 backend → MinIO |
| local-path-provisioner | kube-system | v0.0.30 | Fallback for small ephemeral PVCs |
| **Longhorn** | longhorn-system | 1.7.2 | Replicated block storage on worker 1TB disks; StorageClasses: `longhorn` (Delete) and `longhorn-retain` (Retain) |
| **MinIO** | minio | 5.2.0 | S3-compatible object storage; standalone → distributed when 4+ storage nodes |

### Node pools

Nodes are labeled via `cluster/inventory/prod/host_vars/<node>.yaml` and applied with `make label-nodes`.

| Pool | Label | Taint | Workloads |
|---|---|---|---|
| storage | `node-pool=storage` | none | Longhorn, MinIO, Vault, Loki, Prometheus, platform |
| compute | `node-pool=compute` | `dedicated=compute:NoSchedule` | transcoding workers, stateless API pods |

Adding a new node: create `cluster/inventory/prod/host_vars/<node>.yaml` with `node_labels` and `node_taints`, then `make label-nodes`.

### Storage

StorageClasses in use: `longhorn` (Delete, 2 replicas) and `longhorn-retain` (Retain, 2 replicas) for stateful workloads. `local-path` kept for small ephemeral PVCs. When migrating stateful workloads to a different StorageClass, StatefulSet `volumeClaimTemplates` are immutable: you must **delete the StatefulSet** and let ArgoCD recreate it. Deleting the StatefulSet alone does not delete PVCs — delete those separately before re-sync if you need the new StorageClass.

### Vault initialization (manual, one-time)

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json
# Save vault-init.json outside the repo

for pod in vault-0 vault-1 vault-2; do
  for i in 0 1 2; do
    key=$(jq -r ".unseal_keys_b64[$i]" vault-init.json)
    kubectl exec -n vault $pod -- vault operator unseal $key
  done
done
```

### Domain / TLS

Domain pattern: `*.k8s.va.atmodev.net`. cert-manager uses Let's Encrypt HTTP-01 (requires port 80 reachable). ClusterIssuers: `letsencrypt-staging` and `letsencrypt-prod`.

## Key configuration files

| File | Purpose |
|---|---|
| `cluster/inventory/prod/hosts.yaml` | Node IPs and groups |
| `cluster/inventory/prod/group_vars/all/vars.yml` | kube-vip VIP, container runtime |
| `cluster/inventory/prod/group_vars/k8s_cluster/k8s-cluster.yml` | K8s version, CNI, proxy mode |
| `cluster/inventory/prod/group_vars/k8s_cluster/k8s-net-calico.yml` | Calico VXLAN, interface binding |
| `platform/bootstrap/metallb/resources.yaml` | MetalLB IP pool |
| `platform/bootstrap/cert-manager/cluster-issuers.yaml` | Let's Encrypt email |
| `platform/bootstrap/argocd/root-app.yaml` | Git repo URL for ArgoCD |
| `platform/argocd-apps/_root.yaml` | AppProject (must list all Helm chart repos in sourceRepos) |

## Core principles (IaC)

**Everything as code — no manual `kubectl` or `helm` commands on the cluster.**

- Namespaces → created by ArgoCD via `CreateNamespace=true` in syncOptions, or as manifest in `platform/apps/<component>/`
- Kubernetes Secrets → always via ExternalSecret (ESO pulls from Vault); never `kubectl create secret`
- Vault secrets population is the only accepted "manual" step (one-time seeding of credentials that cannot be stored in git)
- Node labels/taints → `cluster/inventory/prod/host_vars/<node>.yaml` + `make label-nodes`
- All cluster state changes must be representable as a git commit; if you can't express it in a file, find a way that allows it

## Known gotchas

- **MetalLB helm upgrade conflict**: CRD caBundle annotation causes conflicts on re-upgrade. `bootstrap.sh` skips MetalLB upgrade if already installed.
- **post-bootstrap playbook**: Uses `slurp` on cp-1 + `delegate_to: localhost` with `become: false` — do not add `connection: local` at play level, it breaks the become/delegate combination.
- **ArgoCD AppProject sourceRepos**: Every Helm chart repo used in child Applications must be listed in `platform/argocd-apps/_root.yaml` under `sourceRepos`.
- **Loki SingleBinary**: When `deploymentMode: SingleBinary`, must set `read.replicas: 0`, `write.replicas: 0`, `backend.replicas: 0` or chart validation fails.
- **Credentials**: `cluster/inventory/prod/credentials/` is gitignored. Vault init JSON must never be committed.
- **Ubuntu 24.04 + apt race**: `unattended-upgrades` starts immediately after VM boot and holds `/var/lib/apt/extended_states`, causing `apt-mark mkstemp EACCES` during Kubespray bootstrap. Fixed via `ubuntu_stop_unattended_upgrades: true` in `kubespray-all.yml` — Kubespray stops it before any apt operations.
- **Makefile INVENTORY**: path is relative to `cluster/` (where all targets cd before running ansible). If overriding: `make host-prep INVENTORY=inventory/prod/hosts.yaml`, not the full `cluster/inventory/...` path.
