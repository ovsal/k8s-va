## Vault

### Зачем нужен

Vault — центральное хранилище секретов для кластера и приложений:
- единое место хранения паролей/ключей/API-токенов
- разграничение доступа через policies
- аудит доступа (audit devices)
- интеграция с Kubernetes auth (для ESO и приложений в кластере)

### Как деплоится

Vault **не** управляется Argo CD: он ставится **скриптом** `platform/bootstrap/bootstrap.sh` (Helm) **до** установки Argo CD, чтобы у stateful-платформы был стабильный порядок: Longhorn → PVC → Vault → GitOps.

- **Helm**: `hashicorp/vault`, chart версии **0.32.0**, релиз **`secrets-vault`**, namespace **`vault`**
- **Values (как код)**: `platform/bootstrap/vault/values.yaml`
- **Ingress UI**: `platform/bootstrap/vault/ingress-ui.yaml` (применяется `kubectl apply` из bootstrap)
- **RBAC для Kubernetes auth**: `platform/bootstrap/vault/kubernetes-auth-delegator.yaml`

Режим работы:
- **HA + integrated storage (raft)**: **3 реплики** при **3+ worker-нодах**; `podAntiAffinity` **required** по `kubernetes.io/hostname` (не более одного server-пода на ноду). Если воркеров меньше трёх — уменьшите `server.ha.replicas` и ослабьте anti-affinity, иначе поды останутся в Pending.
- Данные: PVC на `StorageClass` **`longhorn-ha`**

Доступ снаружи (UI/API):
- hostname: `vault.k8s.va.atmodev.net`
- TLS: `cert-manager` (`ClusterIssuer` = `letsencrypt-prod`)

Требования к DNS:
- `vault.k8s.va.atmodev.net` должен указывать на внешний IP ingress-nginx.

### Init / Unseal / Kubernetes auth + ESO (операционно)

Автоматизировано скриптом **`platform/bootstrap/vault/vault-bootstrap.sh`** (также: `make vault-bootstrap`).

**Первый запуск** (пустой storage после `make bootstrap-platform`):

1. Скрипт выполняет `vault operator init`, печатает **root token** и **unseal keys** и завершается с кодом **11**.
2. Скопируйте вывод в файл **`credentials.env`** в **корне репозитория** (файл в `.gitignore`). Шаблон: `platform/bootstrap/vault/credentials.env.example`.
3. Снова выполните: **`make vault-bootstrap`**

**Второй и последующие запуски** (при наличии `credentials.env`):

- распечатывает все реплики server;
- включает **KV v2** на `secret/`;
- настраивает **`auth/kubernetes`**, политику **`eso-policy`**, роль **`eso-role`** для SA **`secrets-external-secrets`** (namespace `external-secrets`).

Argo CD после этого синхронизирует **ESO** и **`ClusterSecretStore`** из Git — они начнут работать, когда Vault распечатан и настроен.

Root token и unseal keys храните **вне кластера** (не коммитьте в Git).

#### Ручной режим (альтернатива скрипту)

Если нужно только проверить статус или сделать шаг вручную — на реплике `secrets-vault-0`:

```bash
kubectl -n vault exec -it secrets-vault-0 -- vault status
kubectl -n vault exec -it secrets-vault-0 -- vault operator init   # только если ещё не инициализирован
kubectl -n vault exec -it secrets-vault-0 -- vault operator unseal
```

Список пиров raft (нужен root token в окружении пода):

```bash
kubectl -n vault exec -it secrets-vault-0 -- sh -lc 'export VAULT_TOKEN="…"; vault operator raft list-peers'
```

Ожидаемо после полной настройки:
- `Initialized: true`
- `Sealed: false`
- peers = 3 (три реплики raft)

### Как использовать (для других систем)

#### Базовое соглашение по путям (рекомендация)

На старте удобно придерживаться единого нейминга:
- `secret/platform/<service>` — платформенные секреты (Grafana, registry, etc)
- `secret/apps/<app>/<env>` — секреты приложений по окружениям

#### Как приложению получить секреты

Основной способ выдачи секретов в Kubernetes — **External Secrets Operator (ESO)** (см. `docs/external-secrets.md`):
- Vault (KV v2, `secret/`) → ESO → Kubernetes `Secret`

Пошагово для новых приложений (манифесты `ExternalSecret`, шаблоны, `dataFrom`, проверки): **`docs/external-secrets.md`**.

#### Kubernetes auth + ESO (дублирование вручную)

Обычно всё уже сделано **`make vault-bootstrap`**. Если поднимаете второй кластер или восстанавливаете конфиг вручную, те же шаги, что выполняет скрипт:

В репозитории лежит RBAC для TokenReview:
- `platform/bootstrap/vault/kubernetes-auth-delegator.yaml`

Команды Vault (из пода `secrets-vault-0`, с `VAULT_TOKEN`):

```bash
export VAULT_TOKEN="…"
vault secrets enable -path=secret kv-v2 2>/dev/null || true
vault auth enable kubernetes 2>/dev/null || true
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
# далее policy eso-policy и роль eso-role — см. platform/bootstrap/vault/vault-bootstrap.sh
```

Проверка KV из CLI: `vault kv put secret/platform/<сервис> <ключ>=<значение>` (см. `docs/external-secrets.md`).