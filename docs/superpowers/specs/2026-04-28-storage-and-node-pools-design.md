# Storage & Node Pool Architecture

**Date:** 2026-04-28
**Status:** Approved

---

## Context

Cluster: Kubernetes 1.34.3, 3 control-plane + 2 workers (176.113.118.180–181).
Current storage: `local-path` (temporary, node-local). NFS StorageClasses exist but NFS server not configured.
Planned: add 1TB second disk to each worker, expand workers gradually as needed.
Need: replicated block storage + S3-compatible object storage + predictable workload placement.

---

## Goals

1. Replicated block storage (RWO) for stateful applications — survives loss of one worker.
2. S3-compatible object storage for video files and Velero backups.
3. Node pool system defined as IaC — no manual `kubectl label` in production.
4. Clear, extensible placement rules: each workload knows which pool it targets.

---

## Storage Architecture

### Layer 1 — Longhorn (replicated block storage)

**What it is:** CNCF distributed block storage, runs as DaemonSet on labeled nodes. Manages raw disks directly and replicates volumes across nodes at the block level.

**Disk setup:** each storage node gets a second disk (1TB). Longhorn uses it as-is — no partitioning or filesystem needed. The device name (`/dev/sdb`, `/dev/vdb`, etc.) depends on the hypervisor — verify with `lsblk` on each worker before setup.

**Deployment:** Helm chart via ArgoCD, configured to schedule only on `node-pool=storage` nodes. Longhorn automatically discovers new storage nodes when they join.

**StorageClasses:**

| Name | Replicas | Reclaim | Use case |
|---|---|---|---|
| `longhorn` | 2 | Delete | General stateful apps (Loki, etc.) |
| `longhorn-retain` | 2 | Retain | Critical data (Vault, Prometheus) |

Replica count starts at 2 (matches current 2 storage workers). Raise to 3 when a third storage node joins — one setting change in Longhorn UI or values.

**Replacing `local-path`:** Vault and Loki migrate to Longhorn StorageClasses (see Migration section). `local-path` remains available for small ephemeral PVCs (caches, tmp).

### Layer 2 — MinIO (S3-compatible object storage)

**What it is:** S3-compatible object storage. Runs as StatefulSet on storage nodes, backed by a Longhorn PVC — so the data itself is replicated by Longhorn at the block level.

**Initial mode (2 nodes):** MinIO standalone — single instance, persistence handled by Longhorn replication.

**Scale-out (4+ storage nodes with disks):** switch to MinIO distributed mode with erasure coding across nodes. API endpoint and credentials do not change — transparent to consumers.

**Replaces:**
- Velero placeholder `s3.company.com` → MinIO ClusterIP or LoadBalancer endpoint
- Future: Loki chunk storage on S3 instead of filesystem (improves scalability)
- Primary storage for video archive files

**Deployment:** standalone Helm chart (`minio/minio`), ArgoCD-managed, namespace `minio`. Initially single-instance; when 4+ storage nodes are available, redeploy as distributed StatefulSet — same chart, different `mode` value. Service exposed via ClusterIP + Ingress (API and console on separate subdomains).

---

## Node Pool Architecture

### Pool definitions

| Pool | Label | Taint | Purpose |
|---|---|---|---|
| `storage` | `node-pool=storage` | none | Stateful apps, Longhorn, MinIO, platform |
| `compute` | `node-pool=compute` | `dedicated=compute:NoSchedule` | Video transcoding, stateless API workers |

Storage nodes are **not tainted** — they serve as the cluster default and host both platform components and stateful workloads. Compute nodes are tainted to guarantee they remain exclusive to compute workloads.

### Workload placement

```
node-pool=storage (worker-1, worker-2 today):
  ├── Longhorn storage manager       ← nodeSelector: node-pool=storage
  ├── MinIO                          ← requiredAffinity: node-pool=storage
  ├── Vault (StatefulSet)            ← requiredAffinity: node-pool=storage
  ├── Loki (StatefulSet)             ← requiredAffinity: node-pool=storage
  ├── Prometheus (StatefulSet)       ← requiredAffinity: node-pool=storage
  └── ArgoCD, ingress-nginx, etc.    ← no affinity (land here by default)

node-pool=compute (future workers):
  ├── video transcoding workers      ← requiredAffinity + toleration: dedicated=compute
  └── va-dev/stage/prod API pods     ← preferredAffinity: node-pool=compute
```

### Node labels as IaC

Labels and taints are declared in `host_vars`, one file per node:

```
cluster/inventory/prod/host_vars/
  worker-1.yaml
  worker-2.yaml
  worker-3.yaml   ← add when new node joins
  ...
```

**File format:**

```yaml
# cluster/inventory/prod/host_vars/worker-1.yaml
node_labels:
  node-pool: storage
  storage.enabled: "true"
node_taints: []
```

```yaml
# cluster/inventory/prod/host_vars/worker-3.yaml  (example: future compute node)
node_labels:
  node-pool: compute
node_taints:
  - key: dedicated
    value: compute
    effect: NoSchedule
```

Additional application-level labels (zone, hardware type, GPU presence, etc.) go in the same `node_labels` map — no schema restrictions.

### Playbook: `cluster/playbooks/30-node-labels.yaml`

Reads `node_labels` and `node_taints` from each host's `host_vars`, applies them idempotently via `kubectl label` and `kubectl taint` on localhost. Runs against the current inventory — safe to re-run after any label change.

**Makefile target:**
```bash
make label-nodes
# → cd cluster && ansible-playbook -i inventory/prod/hosts.yaml playbooks/30-node-labels.yaml
```

**Adding a label to a node** = PR that edits `host_vars/<node>.yaml` + `make label-nodes`. No direct cluster access needed.

---

## Migration Plan

Existing workloads use `local-path`. Migration order:

1. **Attach disks + apply node labels** — добавить диски в Proxmox, проверить `lsblk` на нодах, затем `make label-nodes`. Это обязательный первый шаг — Longhorn ищет ноды по метке.
2. **Install Longhorn** (ArgoCD app) — Longhorn обнаруживает storage-ноды и диски, StorageClasses появляются.
3. **Install MinIO** (ArgoCD app) — объектное хранилище готово, обновить Velero S3 config.
4. **Migrate Loki** — обновить `storageClass: longhorn` в loki-values.yaml. Удалить PVC, ArgoCD пересоздаёт StatefulSet. История логов теряется — допустимо.
5. **Migrate Vault** — обновить `storageClass: longhorn-retain`. Удалить StatefulSet + PVC, ArgoCD пересоздаёт. Повторить init + unseal (ключи сохранены). Повторить kubernetes auth config.
6. **Migrate Prometheus + Alertmanager** — обновить storageClass. История метрик теряется — допустимо.
7. **Add nodeAffinity** — добавить `nodeAffinity: required node-pool=storage` в values Vault, Loki, Prometheus, MinIO.

Шаги 2–3 неразрушительные. Шаги 4–6 требуют планового даунтайма компонента.

Steps 1–2 are non-destructive. Steps 3–5 require planned downtime per component.

---

## Open Questions

- **Velero bucket name and MinIO credentials** — need to be decided when MinIO is deployed and stored in Vault at `secret/platform/minio`.
- **MinIO ingress** — internal only (ClusterIP) or external (LoadBalancer + domain `minio.k8s.va.atmodev.net`)?
- **Longhorn UI** — expose via Ingress at `longhorn.k8s.va.atmodev.net` or internal only?
