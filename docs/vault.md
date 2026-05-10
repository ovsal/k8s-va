## Vault

### Зачем нужен

Vault — центральное хранилище секретов для кластера и приложений:
- единое место хранения паролей/ключей/API-токенов
- разграничение доступа через policies
- аудит доступа (audit devices)
- интеграция с Kubernetes auth (для ESO и приложений в кластере)

### Как деплоится

Vault разворачивается **строго через Argo CD** (GitOps):
- Argo CD Application: `platform/argocd-apps/secrets/vault/application.yaml`
- Namespace: `vault`
- Helm chart: `hashicorp/vault` версии `0.32.0`

Режим работы:
- **HA + integrated storage (raft)**: сейчас 2 реплики (пока 2 worker-ноды); при добавлении `worker-3+` увеличим до 3
- Данные: PVC на `StorageClass` **`longhorn-ha`**

Доступ снаружи (для администрирования/UI):
- Ingress: `platform/argocd-apps/secrets/vault/ingress-ui.yaml`
- hostname: `vault.k8s.va.atmodev.net`
- TLS: `cert-manager` (`ClusterIssuer` = `letsencrypt-prod`)

Требования к DNS:
- `vault.k8s.va.atmodev.net` должен указывать на внешний IP ingress-nginx (см. `kubectl -n ingress-nginx get svc ingress-nginx-controller`).

### Init / Unseal (ручная процедура)

Важно:
- **kubectl apply/helm install не используем** — только GitOps.
- Но `init/unseal` — это операционная процедура Vault и выполняется вручную.
- Root token и unseal keys нужно хранить **вне кластера** (в защищённом месте).

#### 1) Проверить, что поды Vault поднялись

```bash
kubectl -n vault get pods -o wide
```

#### 2) Инициализация (один раз)

Запускать только на одной реплике (например, `secrets-vault-0`):

```bash
kubectl -n vault exec -it secrets-vault-0 -- vault operator init
```

Сохраните выведенные:
- `Initial Root Token`
- `Unseal Key 1..N`

#### 3) Unseal всех реплик

На каждой реплике применить threshold-кол-во ключей (обычно 3):

```bash
kubectl -n vault exec -it secrets-vault-0 -- vault operator unseal
kubectl -n vault exec -it secrets-vault-1 -- vault operator unseal
```

#### 4) Проверка raft кластера

```bash
kubectl -n vault exec -it secrets-vault-0 -- vault status
kubectl -n vault exec -it secrets-vault-0 -- vault operator raft list-peers
```

Ожидаемо:
- `Initialized: true`
- `Sealed: false`
- peers = 2 (сейчас) или 3 (когда добавим третью реплику)

### Как использовать (для других систем)

#### Базовое соглашение по путям (рекомендация)

На старте удобно придерживаться единого нейминга:
- `secret/platform/<service>` — платформенные секреты (Grafana, registry, etc)
- `secret/apps/<app>/<env>` — секреты приложений по окружениям

#### Как приложению получить секреты

Основной способ выдачи секретов в Kubernetes — **External Secrets Operator (ESO)** (см. `docs/external-secrets.md`):
- Vault (KV v2, `secret/`) → ESO → Kubernetes `Secret`

Пошагово для новых приложений (манифесты `ExternalSecret`, шаблоны, `dataFrom`, проверки): **`docs/external-secrets.md`**.

#### Kubernetes auth + ESO (операционная настройка)

В GitOps лежит только RBAC, чтобы Vault мог валидировать JWT Kubernetes:
- `platform/argocd-apps/secrets/vault/kubernetes-auth-delegator.yaml` — `ClusterRoleBinding` на `system:auth-delegator` для SA `secrets-vault`.

Дальше **один раз** из пода `secrets-vault-0` (с действующим root token):

```bash
export VAULT_TOKEN="…"

# Если движок KV ещё не включали:
vault secrets enable -path=secret kv-v2

vault auth enable kubernetes

vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

vault policy write eso-policy - <<'EOF'
path "secret/data/platform/*" {
  capabilities = ["read"]
}
path "secret/metadata/platform/*" {
  capabilities = ["list", "read"]
}
EOF

vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=secrets-external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=1h
```

Пример секрета для демо ESO: `vault kv put secret/platform/example demo=my-value`.

Для ручной проверки доступа без ESO используйте UI/CLI Vault.

