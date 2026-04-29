# Storage & Node Pools — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Развернуть Longhorn (реплицируемый блочный storage) + MinIO (объектное S3-хранилище) на воркерах с 1TB дисками и реализовать IaC-систему нод-пулов через host_vars + Ansible.

**Architecture:** Node labels и taints декларируются в `cluster/inventory/prod/host_vars/<node>.yaml` и применяются playbook'ом. Longhorn и MinIO деплоятся через ArgoCD как отдельные Applications. Существующие stateful-нагрузки (Vault, Loki, Prometheus) мигрируют с `local-path` на Longhorn StorageClasses.

**Tech Stack:** Longhorn v1.7.2 (`https://charts.longhorn.io`), MinIO chart v5.2.0 (`https://charts.min.io/`), Ansible, ArgoCD multi-source Applications.

---

## Карта файлов

| Действие | Файл | Назначение |
|---|---|---|
| Создать | `cluster/inventory/prod/host_vars/worker-1.yaml` | Метки и taint'ы worker-1 |
| Создать | `cluster/inventory/prod/host_vars/worker-2.yaml` | Метки и taint'ы worker-2 |
| Создать | `cluster/playbooks/30-node-labels.yaml` | Playbook применения меток |
| Изменить | `Makefile` | Добавить target `label-nodes` |
| Создать | `platform/apps/storage/longhorn-values.yaml` | Helm values для Longhorn |
| Создать | `platform/apps/storage/longhorn-storageclasses.yaml` | StorageClass'ы longhorn и longhorn-retain |
| Создать | `platform/argocd-apps/app-longhorn.yaml` | ArgoCD Application для Longhorn |
| Создать | `platform/apps/storage/minio-values.yaml` | Helm values для MinIO |
| Создать | `platform/argocd-apps/app-minio.yaml` | ArgoCD Application для MinIO |
| Изменить | `platform/argocd-apps/_root.yaml` | Добавить Longhorn и MinIO в sourceRepos |
| Изменить | `platform/apps/observability/loki-values.yaml` | storageClass → longhorn, nodeAffinity |
| Изменить | `platform/apps/secrets/vault-values.yaml` | storageClass → longhorn-retain, nodeAffinity |
| Изменить | `platform/apps/observability/prometheus-values.yaml` | storageClass → longhorn-retain, nodeAffinity |
| Изменить | `platform/apps/backup/values.yaml` | S3 endpoint → MinIO |

---

## Task 1: host_vars для воркеров

**Files:**
- Create: `cluster/inventory/prod/host_vars/worker-1.yaml`
- Create: `cluster/inventory/prod/host_vars/worker-2.yaml`

- [ ] **Создать `cluster/inventory/prod/host_vars/worker-1.yaml`**

```yaml
node_labels:
  node-pool: storage
  storage.enabled: "true"
node_taints: []
```

- [ ] **Создать `cluster/inventory/prod/host_vars/worker-2.yaml`**

```yaml
node_labels:
  node-pool: storage
  storage.enabled: "true"
node_taints: []
```

- [ ] **Commit**

```bash
git add cluster/inventory/prod/host_vars/
git commit -m "feat: add node pool host_vars for worker-1 and worker-2"
```

---

## Task 2: Playbook 30-node-labels.yaml + Makefile

**Files:**
- Create: `cluster/playbooks/30-node-labels.yaml`
- Modify: `Makefile`

- [ ] **Создать `cluster/playbooks/30-node-labels.yaml`**

```yaml
---
# Плейбук: применяет node_labels и node_taints из host_vars на каждую ноду.
# Идемпотентен — безопасно перезапускать.
# Запуск: make label-nodes

- name: Apply node labels and taints
  hosts: localhost
  connection: local
  gather_facts: false
  environment:
    KUBECONFIG: "{{ lookup('env', 'HOME') }}/.kube/config-k8s-va"
  tasks:

    - name: Apply labels to nodes
      vars:
        label_args: >-
          {% for k, v in hostvars[item].get('node_labels', {}).items() %}{{ k }}={{ v }} {% endfor %}
      command: kubectl label node {{ item }} {{ label_args }} --overwrite
      loop: "{{ groups['k8s_cluster'] }}"
      when: hostvars[item].get('node_labels', {}) | length > 0
      changed_when: true

    - name: Apply taints to nodes
      vars:
        taint_args: >-
          {% for t in hostvars[item].get('node_taints', []) %}{{ t.key }}={{ t.value }}:{{ t.effect }} {% endfor %}
      command: kubectl taint node {{ item }} {{ taint_args }} --overwrite
      loop: "{{ groups['k8s_cluster'] }}"
      when: hostvars[item].get('node_taints', []) | length > 0
      changed_when: true
```

- [ ] **Добавить target в `Makefile`** (после строки `post-bootstrap`)

```makefile
label-nodes: ## Apply node labels and taints from host_vars (idempotent)
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/30-node-labels.yaml
```

- [ ] **Commit**

```bash
git add cluster/playbooks/30-node-labels.yaml Makefile
git commit -m "feat: add node label IaC playbook and make target"
```

---

## Task 3: Применить метки на кластер

- [ ] **Убедиться что диски подключены к воркерам, затем запустить**

```bash
export KUBECONFIG=~/.kube/config-k8s-va
make label-nodes
```

Ожидаемый вывод: `ok` или `changed` для worker-1 и worker-2.

- [ ] **Проверить метки**

```bash
kubectl get nodes worker-1 worker-2 --show-labels | grep node-pool
```

Ожидаемый вывод:
```
worker-1  ...  node-pool=storage,storage.enabled=true,...
worker-2  ...  node-pool=storage,storage.enabled=true,...
```

- [ ] **Проверить имена дисков на воркерах**

```bash
# Выполнить на каждом воркере — запомни имя второго диска (sdb, vdb, и т.д.)
ssh ansible@176.113.118.180 lsblk -d -o NAME,SIZE,TYPE | grep disk
ssh ansible@176.113.118.181 lsblk -d -o NAME,SIZE,TYPE | grep disk
```

Ожидаемый вывод (пример):
```
sda   20G disk
sdb  931G disk
```

---

## Task 4: Longhorn — ArgoCD app, values, StorageClasses

**Files:**
- Create: `platform/apps/storage/longhorn-values.yaml`
- Create: `platform/apps/storage/longhorn-storageclasses.yaml`
- Create: `platform/argocd-apps/app-longhorn.yaml`
- Modify: `platform/argocd-apps/_root.yaml`

- [ ] **Создать `platform/apps/storage/longhorn-values.yaml`**

```yaml
defaultSettings:
  defaultReplicaCount: 2
  nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod
  storageMinimalAvailablePercentage: 10
  # Ограничить Longhorn только нодами с меткой node-pool=storage
  systemManagedComponentsNodeSelector: "node-pool:storage"

longhornManager:
  nodeSelector:
    node-pool: storage

longhornDriver:
  nodeSelector:
    node-pool: storage

longhornUI:
  nodeSelector:
    node-pool: storage

persistence:
  defaultClass: false   # используем собственные StorageClass'ы ниже
  defaultClassReplicaCount: 2
  defaultFsType: ext4
  reclaimPolicy: Delete

ingress:
  enabled: true
  ingressClassName: nginx
  host: longhorn.k8s.va.atmodev.net
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls: true
  tlsSecret: longhorn-tls
```

- [ ] **Создать `platform/apps/storage/longhorn-storageclasses.yaml`**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-retain
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
```

- [ ] **Создать `platform/argocd-apps/app-longhorn.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: https://github.com/ovsal/k8s-va.git
      targetRevision: main
      ref: values
    - repoURL: https://charts.longhorn.io
      chart: longhorn
      targetRevision: 1.7.2
      helm:
        valueFiles:
          - $values/platform/apps/storage/longhorn-values.yaml
    - repoURL: https://github.com/ovsal/k8s-va.git
      targetRevision: main
      path: platform/apps/storage
      directory:
        include: 'longhorn-storageclasses.yaml'
  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Добавить Longhorn в `platform/argocd-apps/_root.yaml`** — вставить в список `sourceRepos`:

```yaml
    - https://charts.longhorn.io
```

- [ ] **Commit**

```bash
git add platform/apps/storage/longhorn-values.yaml \
        platform/apps/storage/longhorn-storageclasses.yaml \
        platform/argocd-apps/app-longhorn.yaml \
        platform/argocd-apps/_root.yaml
git commit -m "feat: add Longhorn replicated storage via ArgoCD"
```

---

## Task 5: Проверить Longhorn

После git push ArgoCD подхватит изменения и задеплоит Longhorn (~2–3 мин).

- [ ] **Проверить поды Longhorn**

```bash
kubectl get pods -n longhorn-system
```

Ожидаемый вывод: все поды в статусе `Running`. Longhorn Manager и Driver должны быть на worker-1 и worker-2.

- [ ] **Проверить StorageClasses**

```bash
kubectl get storageclass
```

Ожидаемый вывод — присутствуют `longhorn` и `longhorn-retain`:
```
NAME             PROVISIONER          ...
local-path       rancher.io/local-path
longhorn         driver.longhorn.io
longhorn-retain  driver.longhorn.io
nfs-fast         nfs.csi.k8s.io
nfs-shared       nfs.csi.k8s.io
```

- [ ] **Проверить что Longhorn видит диски воркеров**

```bash
kubectl get nodes.longhorn.io -n longhorn-system
```

Ожидаемый вывод: worker-1 и worker-2 в статусе `Ready`, с дисками.

- [ ] **Проверить тестовым PVC**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-test
  namespace: default
spec:
  storageClassName: longhorn
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc longhorn-test -n default
```

Ожидаемый статус: `Bound`.

```bash
kubectl delete pvc longhorn-test -n default
```

---

## Task 6: MinIO credentials

- [ ] **Сгенерировать пароль для MinIO admin**

```bash
openssl rand -base64 24
# Сохрани вывод — это будет MINIO_ROOT_PASSWORD
```

- [ ] **Записать credentials в Vault**

```bash
export KUBECONFIG=~/.kube/config-k8s-va
ROOT_TOKEN="<VAULT_ROOT_TOKEN>"  # получить из vault-init.json

kubectl exec -n vault vault-0 -- sh -c "
cat > /tmp/minio.hcl << 'EOF'
path \"secret/data/platform/minio\" { capabilities = [\"read\",\"list\"] }
path \"secret/metadata/platform/minio\" { capabilities = [\"read\",\"list\"] }
EOF
" 

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${ROOT_TOKEN} \
  vault kv put secret/platform/minio \
  root_user="minio-admin" \
  root_password="<СГЕНЕРИРОВАННЫЙ_ПАРОЛЬ>"
```

- [ ] **Создать Kubernetes Secret для MinIO chart**

```bash
kubectl create namespace minio
kubectl create secret generic minio-credentials \
  --namespace minio \
  --from-literal=rootUser=minio-admin \
  --from-literal=rootPassword="<СГЕНЕРИРОВАННЫЙ_ПАРОЛЬ>"
```

---

## Task 7: MinIO — ArgoCD app и values

**Files:**
- Create: `platform/apps/storage/minio-values.yaml`
- Create: `platform/argocd-apps/app-minio.yaml`
- Modify: `platform/argocd-apps/_root.yaml`

- [ ] **Создать `platform/apps/storage/minio-values.yaml`**

```yaml
mode: standalone

existingSecret: minio-credentials

persistence:
  enabled: true
  storageClass: longhorn-retain
  size: 500Gi

resources:
  requests:
    memory: 512Mi
    cpu: 250m
  limits:
    memory: 2Gi
    cpu: "1"

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-pool
              operator: In
              values:
                - storage

ingress:
  enabled: true
  ingressClassName: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
  hosts:
    - host: minio.k8s.va.atmodev.net
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: minio-tls
      hosts:
        - minio.k8s.va.atmodev.net

consoleIngress:
  enabled: true
  ingressClassName: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: minio-console.k8s.va.atmodev.net
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: minio-console-tls
      hosts:
        - minio-console.k8s.va.atmodev.net
```

- [ ] **Создать `platform/argocd-apps/app-minio.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: minio
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: https://github.com/ovsal/k8s-va.git
      targetRevision: main
      ref: values
    - repoURL: https://charts.min.io/
      chart: minio
      targetRevision: 5.2.0
      helm:
        valueFiles:
          - $values/platform/apps/storage/minio-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: minio
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false   # namespace создан вручную с секретом
```

- [ ] **Добавить MinIO в `platform/argocd-apps/_root.yaml`**

```yaml
    - https://charts.min.io/
```

- [ ] **Commit**

```bash
git add platform/apps/storage/minio-values.yaml \
        platform/argocd-apps/app-minio.yaml \
        platform/argocd-apps/_root.yaml
git commit -m "feat: add MinIO object storage via ArgoCD"
```

- [ ] **Проверить MinIO**

```bash
kubectl get pods -n minio
kubectl get pvc -n minio
```

Ожидаемый вывод: под `Running`, PVC `Bound` на `longhorn-retain`.

---

## Task 8: Настроить MinIO — бакеты и доступ для Velero

- [ ] **Сгенерировать пароль для Velero**

```bash
openssl rand -base64 20
# Сохрани вывод — это будет VELERO_PASSWORD
```

- [ ] **Создать бакет и access key через MinIO API**

```bash
# Используем DNS-имя MinIO внутри кластера — переменные подставляются в локальном shell
MINIO_PASS="<MINIO_ROOT_PASSWORD из Task 6>"
VELERO_PASS="<VELERO_PASSWORD из шага выше>"

kubectl run mc-setup \
  --image=minio/mc:latest \
  --rm --restart=Never \
  --env="MINIO_PASS=${MINIO_PASS}" \
  --env="VELERO_PASS=${VELERO_PASS}" \
  -- sh -c '
    mc alias set local http://minio.minio.svc.cluster.local:9000 minio-admin "$MINIO_PASS"
    mc mb local/k8s-velero-backup
    mc admin user add local velero-user "$VELERO_PASS"
    mc admin policy attach local readwrite --user velero-user
    echo Done
  '
```

- [ ] **Сохранить velero credentials в Vault**

```bash
ROOT_TOKEN="<VAULT_ROOT_TOKEN>"  # получить из vault-init.json
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=${ROOT_TOKEN} \
  vault kv put secret/platform/velero \
  access_key="velero-user" \
  secret_key="<VELERO_ПАРОЛЬ>"
```

- [ ] **Создать Secret `velero-credentials` в namespace velero**

```bash
kubectl create secret generic velero-credentials \
  --namespace velero \
  --from-literal=cloud="[default]
aws_access_key_id=velero-user
aws_secret_access_key=<VELERO_ПАРОЛЬ>"
```

---

## Task 9: Обновить Velero — указать MinIO как S3 backend

**File:** `platform/apps/backup/values.yaml`

- [ ] **Обновить S3-конфиг в `platform/apps/backup/values.yaml`**

Заменить секцию `configuration.backupStorageLocation`:

```yaml
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: k8s-velero-backup
      config:
        region: us-east-1
        s3Url: http://minio.minio.svc.cluster.local:9000
        s3ForcePathStyle: "true"
        insecureSkipTLSVerify: "true"
```

- [ ] **Commit**

```bash
git add platform/apps/backup/values.yaml
git commit -m "feat: configure Velero to use MinIO as S3 backend"
```

- [ ] **Проверить Velero**

```bash
kubectl get pods -n velero
```

Ожидаемый вывод: под `Running` (init контейнер завершён, основной контейнер запущен).

```bash
kubectl get backupstoragelocations -n velero
```

Ожидаемый вывод: `default` в статусе `Available`.

---

## Task 10: Миграция Loki → Longhorn

> StatefulSet volumeClaimTemplates неизменяемы — нужно удалить StatefulSet (не PVC), дать ArgoCD пересоздать его, старый PVC удалить вручную.

**File:** `platform/apps/observability/loki-values.yaml`

- [ ] **Обновить storageClass и nodeAffinity в `loki-values.yaml`**

Заменить секцию `singleBinary.persistence`:

```yaml
singleBinary:
  replicas: 1
  persistence:
    storageClass: longhorn
    size: 50Gi
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-pool
                operator: In
                values:
                  - storage
```

- [ ] **Commit и дождаться ошибки ArgoCD**

```bash
git add platform/apps/observability/loki-values.yaml
git commit -m "feat: migrate Loki to Longhorn storage with nodeAffinity"
```

ArgoCD попытается обновить StatefulSet и получит ошибку `volumeClaimTemplates is immutable`. Это ожидаемо.

- [ ] **Удалить StatefulSet (без удаления PVC)**

```bash
kubectl delete statefulset loki -n monitoring --cascade=orphan
```

ArgoCD немедленно пересоздаст StatefulSet с новым PVC на `longhorn`.

- [ ] **Проверить новый PVC**

```bash
kubectl get pvc -n monitoring storage-loki-0
```

Ожидаемый вывод: новый PVC в статусе `Bound`, `STORAGECLASS: longhorn`.

- [ ] **Удалить старый PVC на local-path**

```bash
# Убедиться что новый PVC уже Bound и под Running перед удалением старого
# Старый PVC имел то же имя storage-loki-0 на local-path — ArgoCD уже создал новый.
# Если имя совпадает, старый PVC был заменён автоматически.
# Проверить что loki-0 Running:
kubectl get pod loki-0 -n monitoring
```

---

## Task 11: Миграция Vault → Longhorn + Retain

**File:** `platform/apps/secrets/vault-values.yaml`

> После миграции Vault будет пересоздан с нуля — потребуется повторный unseal.

- [ ] **Обновить storageClass и nodeAffinity в `vault-values.yaml`**

Заменить секцию `server.dataStorage` и добавить affinity:

```yaml
server:
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: longhorn-retain

  affinity: |
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: vault
                component: server
            topologyKey: kubernetes.io/hostname
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-pool
                operator: In
                values:
                  - storage
```

- [ ] **Commit**

```bash
git add platform/apps/secrets/vault-values.yaml
git commit -m "feat: migrate Vault to longhorn-retain storage with nodeAffinity"
```

- [ ] **Удалить Vault StatefulSet и старые PVC**

```bash
kubectl delete statefulset vault -n vault --cascade=orphan
kubectl delete pvc data-vault-0 data-vault-1 data-vault-2 -n vault
```

ArgoCD пересоздаст StatefulSet с новыми PVC на `longhorn-retain`.

- [ ] **Проверить новые PVC**

```bash
kubectl get pvc -n vault
```

Ожидаемый вывод: data-vault-0/1/2 в статусе `Bound`, `STORAGECLASS: longhorn-retain`.

- [ ] **Повторить unseal Vault** (данные потеряны, vault новый)

```bash
export KUBECONFIG=~/.kube/config-k8s-va
ROOT_TOKEN="<VAULT_ROOT_TOKEN>"  # получить из vault-init-new.json

# Инициализировать заново
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init-new.json

# Сохранить vault-init-new.json в надёжное место!

# Unseal всех трёх реплик (используя первые 3 ключа из нового vault-init-new.json)
for pod in vault-0 vault-1 vault-2; do
  for i in 0 1 2; do
    key=$(jq -r ".unseal_keys_b64[$i]" vault-init-new.json)
    kubectl exec -n vault $pod -- vault operator unseal $key
  done
done
```

- [ ] **Восстановить конфигурацию Vault (KV, kubernetes auth, ESO policy)**

```bash
NEW_ROOT=$(jq -r '.root_token' vault-init-new.json)

# KV v2
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$NEW_ROOT \
  vault secrets enable -path=secret kv-v2

# Kubernetes auth
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$NEW_ROOT \
  vault auth enable kubernetes

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$NEW_ROOT \
  vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# ESO policy
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$NEW_ROOT sh -c "
cat > /tmp/eso-policy.hcl << 'EOF'
path \"secret/data/*\" { capabilities = [\"read\",\"list\"] }
path \"secret/metadata/*\" { capabilities = [\"read\",\"list\"] }
EOF
vault policy write eso-policy /tmp/eso-policy.hcl"

# ESO role
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$NEW_ROOT \
  vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names="external-secrets" \
  bound_service_account_namespaces="external-secrets" \
  policies="eso-policy" \
  ttl="1h"

# Восстановить secrets
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$NEW_ROOT \
  vault kv put secret/platform/minio \
  root_user="minio-admin" \
  root_password="<MINIO_ПАРОЛЬ>"

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$NEW_ROOT \
  vault kv put secret/platform/velero \
  access_key="velero-user" \
  secret_key="<VELERO_ПАРОЛЬ>"
```

- [ ] **Перезапустить ESO для подхвата нового Vault**

```bash
kubectl rollout restart deployment/external-secrets -n external-secrets
# Подождать 15 секунд
kubectl get clustersecretstore vault-backend
```

Ожидаемый вывод: `STATUS: Valid`.

---

## Task 12: Миграция Prometheus + Alertmanager → Longhorn

**File:** `platform/apps/observability/prometheus-values.yaml`

- [ ] **Обновить storageSpec в `prometheus-values.yaml`**

Найти и заменить оба блока `storageClassName: local-path`:

```yaml
# Блок prometheus (storageSpec):
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn-retain
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 50Gi

# Блок alertmanager (storage):
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn-retain
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 5Gi
```

Добавить nodeAffinity в секцию `prometheus` и `alertmanager`:

```yaml
prometheus:
  prometheusSpec:
    nodeSelector:
      node-pool: storage

alertmanager:
  alertmanagerSpec:
    nodeSelector:
      node-pool: storage
```

- [ ] **Commit**

```bash
git add platform/apps/observability/prometheus-values.yaml
git commit -m "feat: migrate Prometheus and Alertmanager to longhorn-retain with nodeAffinity"
```

- [ ] **Удалить StatefulSets и PVC**

```bash
kubectl delete statefulset prometheus-kube-prometheus-stack-prometheus -n monitoring --cascade=orphan
kubectl delete statefulset alertmanager-kube-prometheus-stack-alertmanager -n monitoring --cascade=orphan
kubectl delete pvc prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 -n monitoring
kubectl delete pvc alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0 -n monitoring
```

- [ ] **Проверить новые PVC**

```bash
kubectl get pvc -n monitoring
```

Ожидаемый вывод: все PVC в статусе `Bound`, `STORAGECLASS: longhorn-retain`.

---

## Task 13: Финальная проверка

- [ ] **Проверить все поды**

```bash
kubectl get pods -A | grep -v "Running\|Completed"
```

Ожидаемый вывод: пустой или только system поды.

- [ ] **Проверить ArgoCD applications**

```bash
kubectl get applications -n argocd
```

Ожидаемый: longhorn и minio — `Synced/Healthy`. Vault, Loki, Prometheus — `Synced/Healthy`.

- [ ] **Проверить Longhorn реплики**

```bash
kubectl get volumes.longhorn.io -n longhorn-system
```

Каждый том должен показывать `robustnessStatus: Healthy` и `2/2` реплики.

- [ ] **Проверить Velero backup**

```bash
kubectl create -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: test-backup
  namespace: velero
spec:
  includedNamespaces:
    - default
  storageLocation: default
  ttl: 1h
EOF
kubectl get backup test-backup -n velero
```

Ожидаемый вывод: `STATUS: Completed`.

- [ ] **Обновить CLAUDE.md** — добавить `label-nodes` в секцию команд и отметить Longhorn + MinIO в таблице компонентов.

- [ ] **Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with Longhorn, MinIO and label-nodes"
```
