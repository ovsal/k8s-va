# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All Ansible commands must run from `ansible/` using the `.venv` Python environment:

```bash
# Always export kubeconfig before kubectl/helm commands
export KUBECONFIG=~/.kube/config-k8s-va

# Stage 1 – prepare nodes
make host-prep
# equivalent: cd ansible && .venv/bin/ansible-playbook -i inventory/prod/hosts.yaml playbooks/00-host-prep.yaml

# Stage 2 – bootstrap cluster (Kubespray, ~20–40 min)
make bootstrap

# Stage 3 – fetch kubeconfig to ~/.kube/config-k8s-va
make post-bootstrap

# Stage 4 – MetalLB → ingress-nginx → cert-manager → Argo CD
make bootstrap-platform

# DESTRUCTIVE: tear down cluster (5-second pause then runs kubespray reset)
make reset

# Lint Ansible playbooks and microservice Helm chart
make lint
```

Ad-hoc Ansible:
```bash
cd ansible && .venv/bin/ansible -i inventory/prod/hosts.yaml all -m ping
cd ansible && .venv/bin/ansible -i inventory/prod/hosts.yaml all -m shell -a "systemctl is-active containerd"
```

## Environment / toolchain

- **Ansible**: must use `.venv/bin/ansible-playbook` (ansible-core 2.17.14, installed via `pip install ansible==10.7.0`). The system/Homebrew ansible is a different incompatible version.
- **SSH key**: hardcoded in `ansible/ansible.cfg` → `ssh_args` → `-i /Users/ai_ovsyannikov/.ssh/id_rsa_ansible2`
- **Kubespray**: git submodule at `ansible/kubespray/` (branch v2.30.0). Init with `git submodule update --init --recursive`.

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
       ├─ app-storage.yaml
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
| Velero | velero | — | Requires `velero-credentials` secret from ESO |
| local-path-provisioner | kube-system | v0.0.30 | **Temporary** storage until NFS/Longhorn available |

### Storage

Current default StorageClass is `local-path` (Rancher local-path-provisioner). This is temporary — planned replacement with Longhorn or NFS. When migrating stateful workloads to a different StorageClass, StatefulSet `volumeClaimTemplates` are immutable: you must **delete the StatefulSet** and let ArgoCD recreate it. Deleting the StatefulSet alone does not delete PVCs — delete those separately before re-sync if you need the new StorageClass.

### Vault initialization (manual, one-time)

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json
# Save vault-init.json outside the repo

for pod in vault-0 vault-1 vault-2; do
  for i in 1 2 3; do
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
| `ansible/inventory/prod/hosts.yaml` | Node IPs and groups |
| `ansible/inventory/prod/group_vars/all/vars.yml` | kube-vip VIP, container runtime |
| `ansible/inventory/prod/group_vars/k8s_cluster/k8s-cluster.yml` | K8s version, CNI, proxy mode |
| `ansible/inventory/prod/group_vars/k8s_cluster/k8s-net-calico.yml` | Calico VXLAN, interface binding |
| `platform/bootstrap/metallb/resources.yaml` | MetalLB IP pool |
| `platform/bootstrap/cert-manager/cluster-issuers.yaml` | Let's Encrypt email |
| `platform/bootstrap/argocd/root-app.yaml` | Git repo URL for ArgoCD |
| `platform/argocd-apps/_root.yaml` | AppProject (must list all Helm chart repos in sourceRepos) |

## Known gotchas

- **MetalLB helm upgrade conflict**: CRD caBundle annotation causes conflicts on re-upgrade. `bootstrap.sh` skips MetalLB upgrade if already installed.
- **post-bootstrap playbook**: Uses `slurp` on cp-1 + `delegate_to: localhost` with `become: false` — do not add `connection: local` at play level, it breaks the become/delegate combination.
- **ArgoCD AppProject sourceRepos**: Every Helm chart repo used in child Applications must be listed in `platform/argocd-apps/_root.yaml` under `sourceRepos`.
- **Loki SingleBinary**: When `deploymentMode: SingleBinary`, must set `read.replicas: 0`, `write.replicas: 0`, `backend.replicas: 0` or chart validation fails.
- **Credentials**: `ansible/inventory/prod/credentials/` is gitignored. Vault init JSON must never be committed.
