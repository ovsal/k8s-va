# Наблюдаемость (Prometheus, Grafana, Loki, Promtail)

## Что развёрнуто

| Компонент | Как | Namespace |
|-----------|-----|-------------|
| **kube-prometheus-stack** (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, правила) | Argo CD `observability-metrics` | `observability` |
| **Loki** (SingleBinary, filesystem на Longhorn) | Argo CD `observability-loki` | `observability` |
| **Promtail** (DaemonSet) | Argo CD `observability-promtail` | `observability` |

Манифесты: `platform/argocd-apps/observability/`. Порядок синка Argo: namespace (wave **-2**) → метрики (wave **0**) → Loki (**1**) → Promtail (**2**). **Vault и External Secrets для Grafana не используются.**

## DNS и TLS

- **`https://grafana.k8s.va.atmodev.net`** — UI Grafana (TLS через cert-manager `letsencrypt-prod`).

## Grafana: вход без Vault

Цепочка **Vault → KV → ExternalSecret → OAuth** для этой платформы убрана. Учётные данные администратора хранятся только в **Kubernetes Secret** в namespace `observability`, который вы создаёте сами (он не коммитится в Git).

1. После появления namespace **`observability`** (синк `root-app` / Argo) выполните из корня репозитория:
   ```bash
   make grafana-admin-secret
   ```
   Либо напрямую: `bash platform/bootstrap/observability/grafana-admin-secret.sh`  
   Скрипт создаёт Secret **`grafana-admin-credentials`** с ключами **`admin-user`** и **`admin-password`** (по умолчанию пользователь `admin`, пароль генерируется, если не задан **`GRAFANA_ADMIN_PASSWORD`**).

2. Убедитесь, что Argo синхронизировал **`observability-metrics`**: в Helm values для Grafana указано `grafana.admin.existingSecret: grafana-admin-credentials` — под Grafana читает пароль из этого Secret.

3. Откройте `https://grafana.k8s.va.atmodev.net/login`, введите логин и пароль из шага 1.

Если Secret уже существует, скрипт ничего не перезаписывает: для смены пароля удалите Secret и создайте заново, либо задайте **`GRAFANA_ADMIN_PASSWORD`** при первом создании.

**Vault** в кластере может оставаться для других сценариев (см. `docs/vault.md`, ESO для прочих приложений) — на конфигурацию Grafana в этом репозитории он больше не влияет.

### Опционально: снова связать Grafana с Vault OIDC

Если понадобится прежняя схема, её можно восстановить вручную: выполнить **`bash platform/bootstrap/vault/vault-grafana-oidc.sh`** при настроенном Vault (нужен `credentials.env` с `VAULT_ROOT_TOKEN`), вернуть в Git **ExternalSecret** и блок **Generic OAuth** в `kube-prometheus-stack/values.yaml` — это уже не текущий путь по умолчанию.

## Доступ к метрикам и логам

- **Prometheus** внутри кластера: `kubectl -n observability port-forward svc/obs-metrics-kube-prometheu-prometheus 9090:9090` (имя сервиса с усечённым `prometheus` — особенность длины имени в Kubernetes).
- **Grafana**: дашборды по умолчанию из чарта; источник **Loki** добавлен в values (`http://loki.observability.svc:3100`).

## Эксплуатация и ограничения

- **Loki** в режиме SingleBinary с **filesystem** — для небольшого объёма логов; при росте нагрузки планируйте **SimpleScalable** и объектное хранилище (S3-совместимое и т.д.).
- Чарт **promtail** помечен deprecated в репозитории Grafana; при появлении замены можно сменить источник в `application.yaml`.
- **Alertmanager** и правила из kube-prometheus включены по умолчанию; при необходимости настройте receivers в Helm values или отдельными манифестами.

## См. также

- `docs/vault.md` — Vault как платформа (без обязательной связки с Grafana).
- `docs/external-secrets.md` — ESO для приложений, которым по-прежнему нужен Vault.
