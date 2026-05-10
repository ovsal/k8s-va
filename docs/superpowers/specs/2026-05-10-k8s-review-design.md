# K8s Platform Review & Cleanup Design

**Date:** 2026-05-10  
**Scope:** Full IaC audit + restructure of `platform/` — remove dead code, fix Vault, add Longhorn monitoring, complete MinIO GitOps.

---

## 1. Structural Cleanup (argocd-apps / apps separation)

**Principle:** `platform/argocd-apps/` contains ONLY ArgoCD Application/AppProject/ApplicationSet definitions. `platform/apps/` contains ONLY Helm values, raw manifests, and ExternalSecrets.

**Files to DELETE:**

```
platform/apps/backup/application.yaml
platform/apps/namespaces/application.yaml
platform/apps/observability/application-loki.yaml
platform/apps/observability/application-prometheus.yaml
platform/apps/observability/application-promtail.yaml
platform/apps/policies/application.yaml
platform/apps/secrets/application-eso.yaml
platform/apps/secrets/application-vault.yaml
platform/apps/storage/application.yaml
platform/apps/storage/storage-classes.yaml      # NFS StorageClasses with placeholder IPs
platform/apps/storage/values.yaml               # NFS CSI Helm values
platform/argocd-apps/app-storage.yaml           # NFS CSI ArgoCD Application
```

`platform/apps/services/applicationset.yaml` stays — it is a microservice generator (ApplicationSet), not an orphaned Application definition.

**Why:** Root-app watches only `platform/argocd-apps/`. Child apps use `directory.include` filters that skip `application*.yaml` files. These files are never applied — pure dead code.

---

## 2. Vault Fixes

### 2.1 vault-bootstrap.sh — TLS bug

Vault listener config has `tls_disable = 1` (plain HTTP on port 8200). Both helper functions use HTTPS, which fails at the protocol level — `VAULT_SKIP_VERIFY=true` does not fall back to HTTP.

**Fix:** Change `v0()` and `vr()` helpers:
```bash
# Before
env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault "$@"

# After
env VAULT_ADDR=http://127.0.0.1:8200 vault "$@"
```

External access remains HTTPS via ingress + cert-manager. ESO ClusterSecretStore already correctly uses `http://vault.vault.svc.cluster.local:8200`.

### 2.2 vault-values.yaml — dead control-plane toleration

```yaml
# REMOVE — control-plane nodes do not have node-pool=storage label.
# nodeAffinity required: node-pool=storage already prevents scheduling on CP.
# This toleration never fires.
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

Vault continues to schedule on worker-1/worker-2 (node-pool=storage). No behavior change.

---

## 3. Namespace & StorageClass Fixes

### 3.1 va-prod ResourceQuota (missing)

Add to `platform/apps/namespaces/manifests/resource-quotas.yaml`:
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: va-prod
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 8Gi
    limits.cpu: "16"
    limits.memory: 16Gi
    persistentvolumeclaims: "40"
    services.loadbalancers: "0"
```

### 3.2 Default StorageClass

After NFS deletion, `nfs-shared` (broken, placeholder IPs) is gone. `longhorn` becomes the default:

In `platform/apps/storage/longhorn-storageclasses.yaml`:
```yaml
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"   # was false
```

`local-path` (Kubespray built-in) remains but loses default priority. Acceptable — used only for small ephemeral PVCs.

---

## 4. Longhorn Monitoring

**New file:** `platform/apps/storage/longhorn-monitoring.yaml`

### ServiceMonitor

Connects Longhorn manager to Prometheus (kube-prometheus-stack). Label `release: kube-prometheus-stack` matches the Prometheus serviceMonitorSelector.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: longhorn
  namespace: longhorn-system
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: longhorn-manager
  endpoints:
    - port: manager
      path: /metrics
```

### PrometheusRule — Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| `LonghornVolumeSpaceLow` | Available < 20% on a volume | warning |
| `LonghornNodeDiskPressure` | Schedulable disk space < 15% | warning |
| `LonghornNodeDiskCritical` | Schedulable disk space < 5% | critical |
| `LonghornVolumeRobustnessNotHealthy` | volume robustness != Healthy for 5+ min | critical |

### longhorn-values.yaml change

```yaml
storageMinimalAvailablePercentage: 15   # was 10
```

### ArgoCD wiring

`platform/argocd-apps/app-longhorn.yaml` — add `longhorn-monitoring.yaml` to `directory.include`:
```yaml
directory:
  include: '{longhorn-storageclasses.yaml,longhorn-monitoring.yaml}'
```

---

## 5. MinIO → Full GitOps

### Problem

`minio-setup-job.yaml` (bucket creation) is applied via `make apply-minio` outside ArgoCD. Not tracked in GitOps.

### Solution: ArgoCD PostSync hook

Add annotations to `platform/apps/storage/minio-setup-job.yaml`:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

Job runs after MinIO StatefulSet is healthy → race condition excluded. Job is already idempotent (`mc mb --ignore-existing`).

### app-minio.yaml change

```yaml
directory:
  include: '{minio-externalsecret.yaml,minio-setup-job.yaml}'
```

### make apply-minio

Bucket step removed from the target. Helm template apply remains (workaround for MinIO chart v5.2.0 post-job race with ArgoCD multi-source sync on first deploy).

---

## Summary of Changes

| File | Action |
|------|--------|
| `platform/apps/*/application*.yaml` (×9) | DELETE |
| `platform/apps/storage/storage-classes.yaml` | DELETE |
| `platform/apps/storage/values.yaml` | DELETE |
| `platform/argocd-apps/app-storage.yaml` | DELETE |
| `platform/bootstrap/vault/vault-bootstrap.sh` | Fix https→http in v0/vr helpers |
| `platform/apps/secrets/vault-values.yaml` | Remove CP toleration |
| `platform/apps/namespaces/manifests/resource-quotas.yaml` | Add va-prod quota |
| `platform/apps/storage/longhorn-storageclasses.yaml` | Set longhorn as default SC |
| `platform/apps/storage/longhorn-values.yaml` | storageMinimalAvailablePercentage 10→15 |
| `platform/apps/storage/longhorn-monitoring.yaml` | NEW: ServiceMonitor + PrometheusRule |
| `platform/argocd-apps/app-longhorn.yaml` | Add longhorn-monitoring.yaml to include |
| `platform/apps/storage/minio-setup-job.yaml` | Add PostSync hook annotations |
| `platform/argocd-apps/app-minio.yaml` | Add minio-setup-job.yaml to include |
| `Makefile` | Update apply-minio comment |
| `CLAUDE.md` | Update to reflect new state |

---

## Out of Scope

- Migrating ArgoCD bootstrap components (MetalLB, ingress-nginx, cert-manager, ArgoCD itself) to GitOps — these require a chicken-and-egg bootstrap by design.
- Enabling Vault TLS internally — HTTP inside cluster is acceptable; external TLS via ingress is sufficient.
- ApplicationSet for microservices (`services/applicationset.yaml`) — placeholder repo URL, needs separate work when va-services repo exists.
