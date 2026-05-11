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

### Loki: почему не применяется новый размер диска в Git и как увеличить PVC

**Почему синк «ломается» или зависает в OutOfSync на StatefulSet `loki`:** размер тома задаётся в **`spec.volumeClaimTemplates`** StatefulSet. В Kubernetes это поле **по сути неизменяемо** после создания StatefulSet: API не даст подменить шаблон PVC под уже существующий `loki-0`. Helm/Argo при смене `singleBinary.persistence.size` в `values.yaml` генерируют новый шаблон, кластер его **не принимает** — желаемое состояние в Git и фактическое расходятся навсегда, пока вы не расширите том **самим PVC** и не дадите Argo **игнорировать** этот путь (в репозитории для `observability-loki` включён `ignoreDifferences` на `/spec/volumeClaimTemplates`).

**Как увеличить диск по факту (Longhorn, StorageClass `longhorn-ha` с `allowVolumeExpansion: true`):**

1. Убедиться в имени PVC у пода Loki (часто **`storage-loki-0`** в `observability`):
   ```bash
   kubectl -n observability get pvc -l app.kubernetes.io/name=loki
   ```
2. Запросить новый размер (пример — **80Gi**):
   ```bash
   kubectl -n observability patch pvc storage-loki-0 --type merge \
     -p '{"spec":{"resources":{"requests":{"storage":"80Gi"}}}}'
   ```
3. Дождаться статуса **Bound** и завершения resize у Longhorn (`kubectl -n observability describe pvc storage-loki-0`).
4. Держать в Git в `platform/argocd-apps/observability/loki/values.yaml` тот же целевой размер (**документация и новые инсталляции**); для уже живого кластера именно **patch PVC** даёт реальные гигабайты.

Уменьшить PVC «вниз» так же просто нельзя — только миграция данных на новый том или переустановка с потерей данных по осторожному runbook.
- Чарт **promtail** помечен deprecated в репозитории Grafana; при появлении замены можно сменить источник в `application.yaml`.
- **Alertmanager** и правила из kube-prometheus включены по умолчанию; при необходимости настройте receivers в Helm values или отдельными манифестами.

### После удаления namespace `observability`

1. Снова создайте Secret админа Grafana: **`make grafana-admin-secret`** (namespace создастся скриптом при необходимости).
2. Если Argo приложение **`observability-metrics`** зависло в **`Running`** с текстом **`waiting for healthy state of … obs-metrics-grafana`**, а Deployment Grafana в кластере нет: это известный сбой синка (часто после prune + удаления ns). Выполните:
   ```bash
   kubectl patch application observability-metrics -n argocd --type=json -p='[{"op":"remove","path":"/operation"}]'
   kubectl -n argocd annotate application observability-metrics argocd.argoproj.io/refresh=hard --overwrite
   ```
   В манифесте приложения включён **`PruneLast`**, чтобы prune не мешал появлению рабочих нагрузок.

## См. также

- `docs/vault.md` — Vault как платформа (без обязательной связки с Grafana).
- `docs/external-secrets.md` — ESO для приложений, которым по-прежнему нужен Vault.
