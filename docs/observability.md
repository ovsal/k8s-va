# Наблюдаемость (Prometheus, Grafana, Loki, Promtail)

## Что развёрнуто

| Компонент | Как | Namespace |
|-----------|-----|-------------|
| **kube-prometheus-stack** (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, правила) | Argo CD `observability-metrics` | `observability` |
| **Loki** (SingleBinary, filesystem на Longhorn) | Argo CD `observability-loki` | `observability` |
| **Promtail** (DaemonSet) | Argo CD `observability-promtail` | `observability` |

Манифесты: `platform/argocd-apps/observability/`. Порядок синка: namespace → ExternalSecret для OAuth Grafana → метрики (wave 0) → Loki (1) → Promtail (2).

## DNS и TLS

Должны резолвиться (как для Vault/Argo), с записью на ingress:

- **`https://grafana.k8s.va.atmodev.net`** — UI Grafana (TLS через cert-manager `letsencrypt-prod`).
- **`https://vault.k8s.va.atmodev.net`** — уже используется для OIDC (issuer и эндпоинты authorize/token/userinfo).

## Grafana и Vault (OIDC)

1. После появления приложений в Argo выполните **`make vault-bootstrap`** (или `bash platform/bootstrap/vault/vault-bootstrap.sh`), если ещё не делали после добавления OIDC-скрипта. Скрипт **идемпотентно** создаёт:
   - auth **userpass** (если не был включён);
   - пользователя **`grafana-oidc-user`** (пароль из **`GRAFANA_VAULT_USERPASS_PASSWORD`** в `credentials.env` или одноразовый вывод в консоль);
   - identity **entity**, **group `grafana-admins`**, OIDC **client/keys/scopes/provider `grafana`**;
   - запись **`secret/platform/grafana-oidc`** (KV v2) с `client_id` / `client_secret` для ESO.
2. **ExternalSecret** `grafana-vault-oauth` в `observability` подтягивает эти поля в Kubernetes Secret с тем же именем.
3. В Grafana включены **Generic OAuth** эндпоинты на `https://vault.k8s.va.atmodev.net/v1/identity/oidc/provider/grafana/...`, локальная форма входа отключена (`disable_login_form`).
4. Вход: на странице Grafana нажмите **Vault** → редирект на Vault → метод **Username** (userpass) → **`grafana-oidc-user`** и пароль. После успешного входа в Vault браузер вернёт в Grafana. Участники группы **`grafana-admins`** в Vault получают роль **Admin** в Grafana, остальные — **Viewer** (см. `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH` в `kube-prometheus-stack/values.yaml`).

Переопределение публичных URL (если другой домен):

- в `credentials.env` или перед вызовом: **`VAULT_PUBLIC_ISSUER`**, **`GRAFANA_PUBLIC_URL`** (должны совпадать с Ingress и с `redirect_uris` в Vault).

## Доступ к метрикам и логам

- **Prometheus** внутри кластера: `kubectl -n observability port-forward svc/obs-metrics-kube-prometheu-prometheus 9090:9090` (имя сервиса с усечённым `prometheus` — особенность длины имени в Kubernetes).
- **Grafana**: дашборды по умолчанию из чарта; источник **Loki** добавлен в values (`http://loki.observability.svc:3100`).

## Эксплуатация и ограничения

- **Loki** в режиме SingleBinary с **filesystem** — для небольшого объёма логов; при росте нагрузки планируйте **SimpleScalable** и объектное хранилище (S3-совместимое и т.д.).
- Чарт **promtail** помечен deprecated в репозитории Grafana; при появлении замены можно сменить источник в `application.yaml`.
- **Alertmanager** и правила из kube-prometheus включены по умолчанию; при необходимости настройте receivers в Helm values или отдельными манифестами.

## См. также

- `docs/vault.md` — общий поток Vault и `vault-bootstrap`.
- `docs/external-secrets.md` — как ESO читает `secret/platform/...`.
