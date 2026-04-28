# Архитектура хранилища и нод-пулов

**Дата:** 2026-04-28
**Статус:** Утверждено

---

## Контекст

Кластер: Kubernetes 1.34.3, 3 control-plane + 2 воркера (176.113.118.180–181).
Текущее хранилище: `local-path` (временное, node-local). StorageClass'ы NFS есть, но NFS-сервер не настроен.
Планируется: добавить по второму диску 1 ТБ на каждый воркер, постепенно расширять кол-во воркеров по необходимости.
Нужно: реплицируемое блочное хранилище + S3-совместимое объектное хранилище + предсказуемое размещение нагрузки.

---

## Цели

1. Реплицируемое блочное хранилище (RWO) для stateful-приложений — переживает потерю одного воркера.
2. S3-совместимое объектное хранилище для видеофайлов и бэкапов Velero.
3. Система нод-пулов описана как IaC — без ручных `kubectl label` в продакшне.
4. Чёткие и расширяемые правила размещения: каждая нагрузка знает в какой пул она идёт.

---

## Архитектура хранилища

### Слой 1 — Longhorn (реплицируемое блочное хранилище)

**Что это:** распределённое блочное хранилище из экосистемы CNCF, работает как DaemonSet на помеченных нодах. Управляет сырыми дисками напрямую и реплицирует тома между нодами на блочном уровне.

**Подготовка диска:** на каждой storage-ноде появляется второй диск (1 ТБ). Longhorn использует его как есть — разбивка на разделы и файловая система не нужны. Имя устройства (`/dev/sdb`, `/dev/vdb` и т.д.) зависит от гипервизора — проверить через `lsblk` на каждом воркере до установки.

**Деплой:** Helm-чарт через ArgoCD, настроен на работу только на нодах с меткой `node-pool=storage`. При добавлении новой storage-ноды Longhorn обнаруживает её автоматически.

**StorageClass'ы:**

| Имя | Реплики | Reclaim | Назначение |
|---|---|---|---|
| `longhorn` | 2 | Delete | Обычные stateful-приложения (Loki и др.) |
| `longhorn-retain` | 2 | Retain | Критичные данные (Vault, Prometheus) |

Количество реплик начинается с 2 (соответствует двум текущим storage-воркерам). При появлении третьей storage-ноды поднять до 3 — одно изменение в Longhorn UI или values.

**Замена `local-path`:** Vault и Loki мигрируют на Longhorn StorageClass'ы (см. план миграции). `local-path` остаётся для небольших эфемерных PVC (кеши, временные данные).

### Слой 2 — MinIO (S3-совместимое объектное хранилище)

**Что это:** S3-совместимое объектное хранилище. Запускается как StatefulSet на storage-нодах, данные хранятся на Longhorn PVC — таким образом репликация обеспечивается Longhorn на блочном уровне.

**Начальный режим (2 ноды):** standalone — один экземпляр, персистентность через репликацию Longhorn.

**Масштабирование (4+ storage-ноды с дисками):** переход в distributed-режим с erasure coding. API-эндпоинт и учётные данные не меняются — прозрачно для потребителей.

**Заменяет:**
- Плейсхолдер Velero `s3.company.com` → эндпоинт MinIO
- В будущем: chunk storage для Loki на S3 вместо filesystem
- Основное хранилище видеофайлов платформы

**Деплой:** standalone Helm-чарт (`minio/minio`), управляется ArgoCD, namespace `minio`. При переходе в distributed-режим — тот же чарт, другое значение `mode`. Сервис доступен через ClusterIP + Ingress (API и консоль на отдельных поддоменах).

---

## Архитектура нод-пулов

### Определение пулов

| Пул | Метка | Taint | Назначение |
|---|---|---|---|
| `storage` | `node-pool=storage` | нет | Stateful-приложения, Longhorn, MinIO, платформа |
| `compute` | `node-pool=compute` | `dedicated=compute:NoSchedule` | Транскодирование видео, stateless API-воркеры |

Storage-ноды **не тейнтятся** — они являются дефолтными для кластера и размещают как платформенные компоненты, так и stateful-нагрузки. Compute-ноды тейнтятся, чтобы гарантировать их эксклюзивность для вычислительных задач.

### Размещение нагрузок

```
node-pool=storage (worker-1, worker-2 сейчас):
  ├── Longhorn storage manager       ← nodeSelector: node-pool=storage
  ├── MinIO                          ← requiredAffinity: node-pool=storage
  ├── Vault (StatefulSet)            ← requiredAffinity: node-pool=storage
  ├── Loki (StatefulSet)             ← requiredAffinity: node-pool=storage
  ├── Prometheus (StatefulSet)       ← requiredAffinity: node-pool=storage
  └── ArgoCD, ingress-nginx и др.   ← без affinity (попадают сюда по умолчанию)

node-pool=compute (будущие воркеры):
  ├── воркеры транскодирования видео ← requiredAffinity + toleration: dedicated=compute
  └── API-поды va-dev/stage/prod     ← preferredAffinity: node-pool=compute
```

### Метки нод как IaC

Метки и taint'ы описываются в `host_vars` — по одному файлу на ноду:

```
cluster/inventory/prod/host_vars/
  worker-1.yaml
  worker-2.yaml
  worker-3.yaml   ← добавляется при появлении новой ноды
  ...
```

**Формат файла:**

```yaml
# cluster/inventory/prod/host_vars/worker-1.yaml
node_labels:
  node-pool: storage
  storage.enabled: "true"
node_taints: []
```

```yaml
# cluster/inventory/prod/host_vars/worker-3.yaml  (пример: будущая compute-нода)
node_labels:
  node-pool: compute
node_taints:
  - key: dedicated
    value: compute
    effect: NoSchedule
```

Дополнительные метки для приложений (зона, тип железа, наличие GPU и т.д.) добавляются в тот же `node_labels` — никаких ограничений на структуру.

### Плейбук `cluster/playbooks/30-node-labels.yaml`

Читает `node_labels` и `node_taints` из `host_vars` каждой ноды, применяет идемпотентно через `kubectl label` и `kubectl taint` на localhost. Безопасно перезапускать при любом изменении меток.

**Make-таргет:**
```bash
make label-nodes
# → cd cluster && ansible-playbook -i inventory/prod/hosts.yaml playbooks/30-node-labels.yaml
```

**Добавить метку на ноду** = PR с изменением `host_vars/<нода>.yaml` + `make label-nodes`. Прямой доступ к кластеру не нужен.

---

## План миграции

Текущие нагрузки используют `local-path`. Порядок миграции:

1. **Подключить диски + применить метки нод** — добавить диски в Proxmox, проверить `lsblk` на нодах, затем `make label-nodes`. Обязательный первый шаг — Longhorn ищет ноды по метке.
2. **Установить Longhorn** (ArgoCD app) — Longhorn обнаруживает storage-ноды и диски, StorageClass'ы появляются.
3. **Установить MinIO** (ArgoCD app) — объектное хранилище готово, обновить S3-конфиг Velero.
4. **Мигрировать Loki** — обновить `storageClass: longhorn` в loki-values.yaml. Удалить PVC, ArgoCD пересоздаёт StatefulSet. История логов теряется — допустимо.
5. **Мигрировать Vault** — обновить `storageClass: longhorn-retain`. Удалить StatefulSet + PVC, ArgoCD пересоздаёт. Повторить init + unseal (ключи сохранены). Повторить настройку kubernetes auth.
6. **Мигрировать Prometheus + Alertmanager** — обновить storageClass. История метрик теряется — допустимо.
7. **Добавить nodeAffinity** — прописать `nodeAffinity: required node-pool=storage` в values Vault, Loki, Prometheus, MinIO.

Шаги 2–3 неразрушительные. Шаги 4–6 требуют планового даунтайма компонента.

---

## Открытые вопросы

- **Имя бакета и учётные данные MinIO для Velero** — определить при деплое MinIO, сохранить в Vault по пути `secret/platform/minio`.
- **Ingress для MinIO** — только внутренний (ClusterIP) или внешний (`minio.k8s.va.atmodev.net`)?
- **Longhorn UI** — через Ingress на `longhorn.k8s.va.atmodev.net` или только внутри кластера?
