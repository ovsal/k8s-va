## Longhorn

### Зачем нужен

Longhorn — распределённое блочное хранилище (CSI) для Kubernetes. В этом кластере Longhorn используется как **HA StorageClass** для stateful-нагрузок:
- PVC с репликацией между воркерами (переживает потерю одной worker-ноды)
- расширение томов (`allowVolumeExpansion: true`)
- диагностика и операции обслуживания через UI

Ключевая идея: приложения **явно выбирают** StorageClass под требуемый уровень надёжности/стоимости.

### Как деплоится

Longhorn разворачивается через Argo CD (App-of-Apps):
- Argo CD Application: `platform/argocd-apps/storage/longhorn/application.yaml`
- Namespace: `longhorn-system`
- Helm chart: `longhorn/longhorn` версии `1.11.2`

Важные настройки, которые у нас включены:
- **dataPath**: Longhorn хранит данные на воркерах в `**/storage/longhorn**`
- **репликация по умолчанию для default-класса чарта**: `defaultClassReplicaCount: 2`, при этом **default StorageClass выключен** (`persistence.defaultClass: false`)
- **GitOps-особенность**: отключён `preUpgradeChecker.jobEnabled` (иначе установка может блокироваться hook-job’ой при GitOps)

Подготовка директорий на нодах выполняется `host-prep`:
- `cluster/roles/host-prep/tasks/system.yml` создаёт `/storage/longhorn` (если существует `/storage`)

### Как использовать (для других систем)

#### StorageClass’ы

В кластере есть несколько StorageClass от Longhorn, но для приложений мы используем **явно заданный**:
- **`longhorn-ha`** — основной класс для HA томов (2 реплики)
  - манифест: `platform/argocd-apps/storage/longhorn/storageclass-longhorn-ha.yaml`

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

UI описан отдельно в `docs/longhorn-ui.md` (зачем, как деплоится, доступ по Ingress/TLS).

