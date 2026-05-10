## Vault

### Зачем нужен

Vault — центральное хранилище секретов для кластера и приложений:
- единое место хранения паролей/ключей/API-токенов
- разграничение доступа через policies
- аудит доступа (audit devices)
- интеграция с Kubernetes auth (следующий шаг после базового поднятия)

### Как деплоится

Vault разворачивается **строго через Argo CD** (GitOps):
- Argo CD Application: `platform/argocd-apps/secrets/vault/application.yaml`
- Namespace: `vault`
- Helm chart: `hashicorp/vault` версии `0.32.0`

Режим работы:
- **HA + integrated storage (raft)**: 3 реплики
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

Запускать только на одной реплике (например, `vault-0`):

```bash
kubectl -n vault exec -it vault-0 -- vault operator init
```

Сохраните выведенные:
- `Initial Root Token`
- `Unseal Key 1..N`

#### 3) Unseal всех реплик

На каждой реплике применить threshold-кол-во ключей (обычно 3):

```bash
kubectl -n vault exec -it vault-0 -- vault operator unseal
kubectl -n vault exec -it vault-1 -- vault operator unseal
kubectl -n vault exec -it vault-2 -- vault operator unseal
```

#### 4) Проверка raft кластера

```bash
kubectl -n vault exec -it vault-0 -- vault status
kubectl -n vault exec -it vault-0 -- vault operator raft list-peers
```

Ожидаемо:
- `Initialized: true`
- `Sealed: false`
- peers = 3

### Как использовать (для других систем)

#### Базовое соглашение по путям (рекомендация)

На старте удобно придерживаться единого нейминга:
- `secret/platform/<service>` — платформенные секреты (Grafana, registry, etc)
- `secret/apps/<app>/<env>` — секреты приложений по окружениям

#### Как приложению получить секреты

На следующем шаге мы добавим:
- Kubernetes auth method в Vault
- (опционально) External Secrets Operator, чтобы синхронизировать секреты в Kubernetes Secret

До этого момента Vault используется вручную (CLI/UI) для создания секретов и проверки доступа.

