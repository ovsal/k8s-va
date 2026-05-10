## Longhorn UI

### Зачем нужен

Longhorn предоставляет UI для управления хранилищем:
- просмотр нод/дисков и их ёмкости
- просмотр/диагностика томов и реплик
- операции обслуживания (snapshots, backup target, восстановление, troubleshooting)

### Как деплоится

UI разворачивается **вместе с Longhorn** (через Argo CD приложение `storage-longhorn`).

Для доступа снаружи кластера используется Ingress:
- манифест: `platform/argocd-apps/storage/longhorn/ingress-ui.yaml`
- ingress class: `nginx` (ingress-nginx)
- TLS: cert-manager, `ClusterIssuer` = `letsencrypt-prod`
- hostname: `longhorn.k8s.va.atmodev.net`

Требования:
- DNS `longhorn.k8s.va.atmodev.net` должен указывать на внешний IP ingress-nginx: **`176.113.118.185`**
- Порт 80/443 на этом IP должен быть доступен (для HTTP-01 challenge Let's Encrypt)

### Как использовать (для других систем)

Longhorn UI — это административный интерфейс и обычно не используется приложениями напрямую.

Связанные сущности, которые используют другие системы:
- **StorageClass**:
  - `longhorn-ha` — HA тома (репликация, `numberOfReplicas=2`)
  - `longhorn` / `longhorn-static` — создаются самим чартом Longhorn (по умолчанию)

Рекомендованный способ использования в приложениях:
- **явно указывать** `storageClassName: longhorn-ha` в PVC/чартах для stateful-компонентов, где нужна отказоустойчивость.

