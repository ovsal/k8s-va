## Longhorn

### Зачем нужен

Longhorn — распределённое блочное хранилище (CSI) для Kubernetes. В этом кластере Longhorn используется как **HA StorageClass** для stateful-нагрузок:
- PVC с репликацией между воркерами (переживает потерю одной worker-ноды)
- расширение томов (`allowVolumeExpansion: true`)
- диагностика и операции обслуживания через UI

Ключевая идея: приложения **явно выбирают** StorageClass под требуемый уровень надёжности/стоимости.

### Как деплоится

Longhorn ставится **скриптом** `platform/bootstrap/bootstrap.sh` (Helm) **до** Argo CD — так у Vault и других stateful-сервисов есть StorageClass и CSI до GitOps.

- **Values (как код)**: `platform/bootstrap/longhorn/values.yaml`
- **StorageClass `longhorn-ha`**: `platform/bootstrap/longhorn/storageclass-longhorn-ha.yaml`
- **Ingress UI**: `platform/bootstrap/longhorn/ingress-ui.yaml`
- Namespace: **`longhorn-system`**
- Helm chart: **`longhorn/longhorn`** версии **`1.11.2`**

Важные настройки:
- **dataPath**: на воркерах **`/storage/longhorn`**
- **репликация**: `defaultClassReplicaCount: 2`, **default StorageClass выключен** (`persistence.defaultClass: false`)
- **`preUpgradeChecker.jobEnabled: false`** — чтобы не блокировать установку hook-job (актуально и для Helm из bootstrap)

Подготовка директорий на нодах: `cluster/roles/host-prep/tasks/system.yml` — `/storage/longhorn` при наличии `/storage`.

Подготовка директорий на нодах выполняется `host-prep`:
- `cluster/roles/host-prep/tasks/system.yml` создаёт `/storage/longhorn` (если существует `/storage`)

### Как использовать (для других систем)

#### StorageClass’ы

В кластере есть несколько StorageClass от Longhorn, но для приложений мы используем **явно заданный**:
- **`longhorn-ha`** — основной класс для HA томов (2 реплики)
  - манифест: `platform/bootstrap/longhorn/storageclass-longhorn-ha.yaml`

Дополнительно чарт Longhorn создаёт свои служебные классы (`longhorn`, `longhorn-static`). Их можно использовать, но в этой репе целевой класс для приложений — **`longhorn-ha`**.

#### Пример PVC (рекомендуемый шаблон)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn-ha
  resources:
    requests:
      storage: 10Gi
```

#### Когда выбирать `longhorn-ha`
- БД (PostgreSQL и т.п.), если она разворачивается внутри кластера
- stateful-компоненты, где важна сохранность данных при падении ноды
- любые PVC, которые должны **переехать на другую ноду** без потери данных

#### Что проверить, если PVC «завис» в Pending
- В `longhorn-system` все DaemonSet/Pods должны быть Running:
  - `kubectl -n longhorn-system get pods`
- StorageClass существует:
  - `kubectl get storageclass longhorn-ha`
- На worker-нодах есть доступный путь:
  - `/storage/longhorn` существует и доступен (см. `host-prep`)

### UI Longhorn

#### Зачем нужен

Longhorn предоставляет UI для управления хранилищем:
- просмотр нод/дисков и их ёмкости
- просмотр/диагностика томов и реплик
- операции обслуживания (snapshots, backup target, восстановление, troubleshooting)

#### Как деплоится

UI ставится **вместе с Longhorn** из bootstrap (тот же Helm-релиз).

Для доступа снаружи:
- манифест: `platform/bootstrap/longhorn/ingress-ui.yaml`
- ingress class: `nginx` (ingress-nginx)
- TLS: cert-manager, `ClusterIssuer` = `letsencrypt-prod`
- hostname: `longhorn.k8s.va.atmodev.net`

Требования:
- DNS `longhorn.k8s.va.atmodev.net` должен указывать на внешний IP ingress-nginx
- Порт 80/443 на этом IP должен быть доступен (для HTTP-01 challenge Let's Encrypt)

#### Как использовать (для других систем)

Longhorn UI — это административный интерфейс и обычно не используется приложениями напрямую.

