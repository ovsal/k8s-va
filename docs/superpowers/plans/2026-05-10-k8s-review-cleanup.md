# K8s Platform Review & Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all dead code (NFS CSI, orphaned Application manifests), fix Vault TLS bug, add namespace quotas, wire Longhorn monitoring, and complete MinIO GitOps via ArgoCD PostSync hook.

**Architecture:** Pure IaC changes — YAML edits, bash fix, new manifest. No application code. All changes land in `platform/` and `cluster/` directories. After merge ArgoCD self-heals the cluster to the new state.

**Tech Stack:** Kubernetes 1.34, ArgoCD 2.11, Longhorn 1.7.2, Vault 0.28 (Helm), kube-prometheus-stack 61.7.1, ExternalSecrets 0.10.0.

**Verification approach:** `kubectl apply --dry-run=client -f <file>` validates YAML schema locally. `bash -n <script>` validates bash syntax. No unit tests — IaC correctness verified via ArgoCD sync after deploy.

---

## File Map

| File | Action |
|------|--------|
| `platform/apps/backup/application.yaml` | DELETE |
| `platform/apps/namespaces/application.yaml` | DELETE |
| `platform/apps/observability/application-loki.yaml` | DELETE |
| `platform/apps/observability/application-prometheus.yaml` | DELETE |
| `platform/apps/observability/application-promtail.yaml` | DELETE |
| `platform/apps/policies/application.yaml` | DELETE |
| `platform/apps/secrets/application-eso.yaml` | DELETE |
| `platform/apps/secrets/application-vault.yaml` | DELETE |
| `platform/apps/storage/application.yaml` | DELETE |
| `platform/apps/storage/storage-classes.yaml` | DELETE |
| `platform/apps/storage/values.yaml` | DELETE |
| `platform/argocd-apps/app-storage.yaml` | DELETE |
| `platform/bootstrap/vault/vault-bootstrap.sh` | MODIFY — fix https→http in all VAULT_ADDR occurrences |
| `platform/apps/secrets/vault-values.yaml` | MODIFY — remove CP toleration block |
| `platform/apps/namespaces/manifests/resource-quotas.yaml` | MODIFY — add va-prod quota |
| `platform/apps/storage/longhorn-storageclasses.yaml` | MODIFY — set longhorn as default SC |
| `platform/apps/storage/longhorn-values.yaml` | MODIFY — storageMinimalAvailablePercentage 10→15 |
| `platform/apps/storage/longhorn-monitoring.yaml` | CREATE — ServiceMonitor + PrometheusRule |
| `platform/argocd-apps/app-longhorn.yaml` | MODIFY — add longhorn-monitoring.yaml to include |
| `platform/apps/storage/minio-setup-job.yaml` | MODIFY — add PostSync hook annotations |
| `platform/argocd-apps/app-minio.yaml` | MODIFY — add minio-setup-job.yaml to include |
| `Makefile` | MODIFY — update apply-minio comment |
| `CLAUDE.md` | MODIFY — reflect new platform state |

---

## Task 1: Remove NFS CSI app and all orphaned Application manifests

These files are never applied by ArgoCD (root-app watches `platform/argocd-apps/` only; child apps use `directory.include` filters). Dead code — safe to delete.

**Files:** Delete 12 files listed below.

- [ ] **Step 1: Delete orphaned files**

```bash
git rm \
  platform/apps/backup/application.yaml \
  platform/apps/namespaces/application.yaml \
  platform/apps/observability/application-loki.yaml \
  platform/apps/observability/application-prometheus.yaml \
  platform/apps/observability/application-promtail.yaml \
  platform/apps/policies/application.yaml \
  platform/apps/secrets/application-eso.yaml \
  platform/apps/secrets/application-vault.yaml \
  platform/apps/storage/application.yaml \
  platform/apps/storage/storage-classes.yaml \
  platform/apps/storage/values.yaml \
  platform/argocd-apps/app-storage.yaml
```

- [ ] **Step 2: Verify no remaining references to NFS or deleted files**

```bash
grep -r "nfs-csi\|nfs-shared\|nfs-fast\|csi-driver-nfs\|app-storage" platform/ --include="*.yaml" --include="*.sh"
```

Expected: no output (zero references remaining).

- [ ] **Step 3: Verify `platform/argocd-apps/` still has all needed apps**

```bash
ls platform/argocd-apps/
```

Expected output (12 files, no `app-storage.yaml`):
```
_root.yaml
app-backup.yaml
app-eso.yaml
app-loki.yaml
app-longhorn.yaml
app-minio.yaml
app-namespaces.yaml
app-policies.yaml
app-prometheus.yaml
app-promtail.yaml
app-vault.yaml
```

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: remove NFS CSI app and orphaned Application manifests

NFS was placeholder-only (server IP 10.0.0.50 never configured).
All application.yaml files in platform/apps/*/ were dead code —
never applied by ArgoCD due to directory.include filters."
```

---

## Task 2: Fix Vault bootstrap script — TLS bug

`tls_disable = 1` in vault HCL config means Vault serves plain HTTP. All `VAULT_ADDR=https://` calls in the script fail at protocol level. Fix: use `http://` and drop the now-redundant `VAULT_SKIP_VERIFY=true`.

**Files:** Modify `platform/bootstrap/vault/vault-bootstrap.sh`

- [ ] **Step 1: Fix `v0()` helper (line 24–27)**

Replace:
```bash
v0() {
  kubectl exec -n vault vault-0 -- \
    env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault "$@"
}
```

With:
```bash
v0() {
  kubectl exec -n vault vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 vault "$@"
}
```

- [ ] **Step 2: Fix `vr()` helper (line 30–34)**

Replace:
```bash
vr() {
  kubectl exec -n vault vault-0 -- \
    env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
        VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault "$@"
}
```

With:
```bash
vr() {
  kubectl exec -n vault vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault "$@"
}
```

- [ ] **Step 3: Fix `unseal_pod()` — all three `kubectl exec` calls inside the function (lines 40–55)**

Replace the entire `unseal_pod()` function body. Old:
```bash
unseal_pod() {
  local pod=$1
  kubectl get pod "${pod}" -n vault &>/dev/null || return 0
  local sealed
  sealed=$(kubectl exec -n vault "${pod}" -- \
    env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
    vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','true'))" \
    2>/dev/null || echo "true")
  if [[ "${sealed}" == "true" ]]; then
    echo "    Unsealing ${pod}..."
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault operator unseal "${VAULT_UNSEAL_KEY_1}" >/dev/null
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault operator unseal "${VAULT_UNSEAL_KEY_2}" >/dev/null
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault operator unseal "${VAULT_UNSEAL_KEY_3}" >/dev/null
  else
    echo "    ${pod} already unsealed"
  fi
```

New:
```bash
unseal_pod() {
  local pod=$1
  kubectl get pod "${pod}" -n vault &>/dev/null || return 0
  local sealed
  sealed=$(kubectl exec -n vault "${pod}" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 \
    vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','true'))" \
    2>/dev/null || echo "true")
  if [[ "${sealed}" == "true" ]]; then
    echo "    Unsealing ${pod}..."
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=http://127.0.0.1:8200 \
      vault operator unseal "${VAULT_UNSEAL_KEY_1}" >/dev/null
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=http://127.0.0.1:8200 \
      vault operator unseal "${VAULT_UNSEAL_KEY_2}" >/dev/null
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=http://127.0.0.1:8200 \
      vault operator unseal "${VAULT_UNSEAL_KEY_3}" >/dev/null
  else
    echo "    ${pod} already unsealed"
  fi
```

- [ ] **Step 4: Verify no `https://` remains in the script**

```bash
grep "https://" platform/bootstrap/vault/vault-bootstrap.sh
```

Expected: no output.

- [ ] **Step 5: Verify bash syntax**

```bash
bash -n platform/bootstrap/vault/vault-bootstrap.sh && echo "OK"
```

Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add platform/bootstrap/vault/vault-bootstrap.sh
git commit -m "fix: vault-bootstrap.sh use http:// — tls_disable=1 means plain HTTP

VAULT_ADDR=https:// with tls_disable=1 fails at protocol level.
VAULT_SKIP_VERIFY=true does not fall back to HTTP."
```

---

## Task 3: Remove dead control-plane toleration from Vault values

The toleration for `node-role.kubernetes.io/control-plane` is unreachable — CP nodes don't have `node-pool=storage` label which the required nodeAffinity demands.

**Files:** Modify `platform/apps/secrets/vault-values.yaml`

- [ ] **Step 1: Remove the `tolerations` block**

In `platform/apps/secrets/vault-values.yaml`, find and delete:
```yaml
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
```

The remaining `server:` section should have `affinity:`, `dataStorage:`, `ingress:`, `resources:` — no `tolerations:` key.

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('platform/apps/secrets/vault-values.yaml'))" && echo "OK"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add platform/apps/secrets/vault-values.yaml
git commit -m "fix: remove dead control-plane toleration from vault values

CP nodes lack node-pool=storage label required by nodeAffinity,
so this toleration was unreachable."
```

---

## Task 4: Add va-prod ResourceQuota + set longhorn as default StorageClass

**Files:**
- Modify: `platform/apps/namespaces/manifests/resource-quotas.yaml`
- Modify: `platform/apps/storage/longhorn-storageclasses.yaml`

- [ ] **Step 1: Add va-prod ResourceQuota**

Append to the end of `platform/apps/namespaces/manifests/resource-quotas.yaml`:

```yaml
---
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

- [ ] **Step 2: Validate quota manifest**

```bash
kubectl apply --dry-run=client -f platform/apps/namespaces/manifests/resource-quotas.yaml
```

Expected: 3 lines like `resourcequota/compute-quota configured (dry run)` — one per namespace.

- [ ] **Step 3: Set longhorn StorageClass as default**

In `platform/apps/storage/longhorn-storageclasses.yaml`, find the `longhorn` StorageClass `metadata:` block and add the annotation:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"   # changed from "false"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
```

Leave `longhorn-retain` without `is-default-class` annotation (no annotation = not default).

- [ ] **Step 4: Validate StorageClass manifest**

```bash
kubectl apply --dry-run=client -f platform/apps/storage/longhorn-storageclasses.yaml
```

Expected: `storageclass.storage.k8s.io/longhorn configured (dry run)` and `storageclass.storage.k8s.io/longhorn-retain configured (dry run)`.

- [ ] **Step 5: Commit**

```bash
git add platform/apps/namespaces/manifests/resource-quotas.yaml \
        platform/apps/storage/longhorn-storageclasses.yaml
git commit -m "feat: add va-prod ResourceQuota; set longhorn as default StorageClass

va-prod was the only environment without a quota.
nfs-shared (broken, placeholder IPs) was the previous default — removed in task 1."
```

---

## Task 5: Add Longhorn monitoring (ServiceMonitor + PrometheusRule)

Longhorn manager exposes Prometheus metrics on port 9500 (named `manager`). `serviceMonitorSelectorNilUsesHelmValues: false` in prometheus-values means Prometheus picks up ALL ServiceMonitors cluster-wide — no label filter required.

**Files:**
- Create: `platform/apps/storage/longhorn-monitoring.yaml`
- Modify: `platform/apps/storage/longhorn-values.yaml`
- Modify: `platform/argocd-apps/app-longhorn.yaml`

- [ ] **Step 1: Create `platform/apps/storage/longhorn-monitoring.yaml`**

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: longhorn
  namespace: longhorn-system
spec:
  selector:
    matchLabels:
      app: longhorn-manager
  endpoints:
    - port: manager
      path: /metrics
      interval: 30s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: longhorn-alerts
  namespace: longhorn-system
spec:
  groups:
    - name: longhorn.storage
      rules:
        - alert: LonghornVolumeSpaceLow
          expr: |
            (longhorn_volume_capacity_bytes - longhorn_volume_actual_size_bytes)
            / longhorn_volume_capacity_bytes < 0.20
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Longhorn volume {{ $labels.volume }} space below 20%"
            description: "Volume {{ $labels.volume }} has less than 20% free space. Current: {{ $value | humanizePercentage }}"

        - alert: LonghornNodeDiskPressure
          expr: |
            longhorn_node_storage_schedulable_bytes
            / longhorn_node_storage_capacity_bytes < 0.15
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Longhorn node {{ $labels.node }} disk schedulable space below 15%"
            description: "Node {{ $labels.node }} has less than 15% schedulable disk space. Current: {{ $value | humanizePercentage }}"

        - alert: LonghornNodeDiskCritical
          expr: |
            longhorn_node_storage_schedulable_bytes
            / longhorn_node_storage_capacity_bytes < 0.05
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Longhorn node {{ $labels.node }} disk schedulable space CRITICAL (below 5%)"
            description: "Node {{ $labels.node }} has less than 5% schedulable disk space. Current: {{ $value | humanizePercentage }}"

        - alert: LonghornVolumeRobustnessNotHealthy
          expr: longhorn_volume_robustness > 1
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Longhorn volume {{ $labels.volume }} is not healthy"
            description: "Volume {{ $labels.volume }} robustness is {{ $labels.robustness }} (expected: healthy)"
```

- [ ] **Step 2: Validate manifest**

```bash
kubectl apply --dry-run=client -f platform/apps/storage/longhorn-monitoring.yaml
```

Expected: `servicemonitor.monitoring.coreos.com/longhorn created (dry run)` and `prometheusrule.monitoring.coreos.com/longhorn-alerts created (dry run)`.

If CRDs not available locally, check YAML syntax instead:
```bash
python3 -c "import yaml,sys; list(yaml.safe_load_all(open('platform/apps/storage/longhorn-monitoring.yaml')))" && echo "OK"
```

- [ ] **Step 3: Update `storageMinimalAvailablePercentage` in longhorn-values.yaml**

In `platform/apps/storage/longhorn-values.yaml`, change:
```yaml
  storageMinimalAvailablePercentage: 10
```
to:
```yaml
  storageMinimalAvailablePercentage: 15
```

- [ ] **Step 4: Wire monitoring file into ArgoCD in `app-longhorn.yaml`**

In `platform/argocd-apps/app-longhorn.yaml`, find the third source block (the `path: platform/apps/storage` source) and update `directory.include`:

```yaml
    - repoURL: https://github.com/ovsal/k8s-va.git
      targetRevision: main
      path: platform/apps/storage
      directory:
        include: '{longhorn-storageclasses.yaml,longhorn-monitoring.yaml}'
```

- [ ] **Step 5: Validate app-longhorn.yaml**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('platform/argocd-apps/app-longhorn.yaml'))" && echo "OK"
```

Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add platform/apps/storage/longhorn-monitoring.yaml \
        platform/apps/storage/longhorn-values.yaml \
        platform/argocd-apps/app-longhorn.yaml
git commit -m "feat: add Longhorn ServiceMonitor and PrometheusRule alerts

Monitors volume space, node disk pressure, and volume robustness.
Raises storageMinimalAvailablePercentage 10→15 to align with warning threshold."
```

---

## Task 6: MinIO bucket setup job → ArgoCD PostSync GitOps

`minio-setup-job.yaml` currently applied outside ArgoCD via `make apply-minio`. Adding `PostSync` hook runs it after MinIO StatefulSet is healthy, eliminating the race condition.

**Files:**
- Modify: `platform/apps/storage/minio-setup-job.yaml`
- Modify: `platform/argocd-apps/app-minio.yaml`
- Modify: `Makefile`

- [ ] **Step 1: Add PostSync hook annotations to `minio-setup-job.yaml`**

In `platform/apps/storage/minio-setup-job.yaml`, update the `metadata:` block to add annotations:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-setup
  namespace: minio
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  ttlSecondsAfterFinished: 600
  # ... rest unchanged
```

- [ ] **Step 2: Validate**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('platform/apps/storage/minio-setup-job.yaml'))" && echo "OK"
```

Expected: `OK`

- [ ] **Step 3: Update `app-minio.yaml` directory.include**

In `platform/argocd-apps/app-minio.yaml`, find the third source (path: `platform/apps/storage`) and update `directory.include`:

```yaml
    - repoURL: https://github.com/ovsal/k8s-va.git
      targetRevision: main
      path: platform/apps/storage
      directory:
        include: '{minio-externalsecret.yaml,minio-setup-job.yaml}'
```

- [ ] **Step 4: Update Makefile `apply-minio` target comment**

In `Makefile`, find the `apply-minio` target and update its comment and body. Remove the bucket setup job step since ArgoCD now handles it:

```makefile
apply-minio: ## Deploy MinIO via helm template (workaround: ArgoCD race condition with chart post-job on first deploy). Bucket creation handled by ArgoCD PostSync hook.
	@export KUBECONFIG=$(KUBECONFIG_PATH); \
	helm template minio minio/minio --version 5.2.0 --namespace minio \
	  --values $(PLATFORM_DIR)/apps/storage/minio-values.yaml 2>/dev/null | \
	kubectl apply -n minio -f -
```

- [ ] **Step 5: Validate app-minio.yaml**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('platform/argocd-apps/app-minio.yaml'))" && echo "OK"
```

Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add platform/apps/storage/minio-setup-job.yaml \
        platform/argocd-apps/app-minio.yaml \
        Makefile
git commit -m "feat: move MinIO bucket setup into ArgoCD PostSync hook

Job runs after MinIO StatefulSet is healthy — eliminates race condition.
make apply-minio now only handles the Helm template apply workaround."
```

---

## Task 7: Update CLAUDE.md

Reflect the new platform state after all changes.

**Files:** Modify `CLAUDE.md`

- [ ] **Step 1: Update Platform components table**

Remove the NFS CSI row from the components table. Update Longhorn row to note monitoring is active. Update MinIO row to note bucket setup is via ArgoCD PostSync.

Find the Platform components table and make these changes:

| Component | Change |
|-----------|--------|
| Remove `nfs-csi` row | NFS CSI is deleted |
| Longhorn row | Add: `Monitoring: ServiceMonitor + PrometheusRule in longhorn-system` |
| MinIO row | Update notes: `Bucket setup via ArgoCD PostSync hook (minio-setup-job)` |

- [ ] **Step 2: Update Known gotchas**

Remove the `app-storage.yaml` / NFS references. Add a note about Vault TLS:

```markdown
- **Vault TLS:** `tls_disable = 1` in vault HCL — Vault serves plain HTTP on 8200 internally. `vault-bootstrap.sh` and ESO ClusterSecretStore both use `http://`. External access is HTTPS via ingress + cert-manager only.
```

- [ ] **Step 3: Update Full cluster rebuild sequence**

The `make apply-minio` step note: "ArgoCD PostSync hook creates buckets automatically after MinIO is healthy. No manual bucket step needed."

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md — reflect NFS removal, Vault TLS, Longhorn monitoring, MinIO GitOps"
```

---

## Self-Review Checklist

### Spec Coverage

| Spec section | Tasks covering it |
|---|---|
| 1. Structural cleanup — delete 12 files | Task 1 ✓ |
| 2.1 Vault TLS fix (https→http) | Task 2 ✓ |
| 2.2 Remove dead CP toleration | Task 3 ✓ |
| 3.1 va-prod ResourceQuota | Task 4 ✓ |
| 3.2 Default StorageClass → longhorn | Task 4 ✓ |
| 4. Longhorn ServiceMonitor + PrometheusRule | Task 5 ✓ |
| 4. storageMinimalAvailablePercentage 10→15 | Task 5 ✓ |
| 4. ArgoCD wiring for monitoring | Task 5 ✓ |
| 5. MinIO PostSync hook | Task 6 ✓ |
| 5. app-minio.yaml directory.include | Task 6 ✓ |
| 5. Makefile update | Task 6 ✓ |
| CLAUDE.md update | Task 7 ✓ |

All spec sections covered. No gaps.
