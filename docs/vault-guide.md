# Руководство по HashiCorp Vault

Этот документ объясняет как устроен Vault в кластере, почему именно так, и как с ним работать — от ежедневных операций до интеграции приложений.

---

## Раздел 1 — Что такое Vault и зачем он нужен

### Проблема: где хранить секреты

В любом проекте есть секреты — пароли к базам данных, API-ключи, токены доступа к внешним сервисам. Типичные подходы и их проблемы:

| Подход | Проблема |
|---|---|
| Хранить в коде | Секрет попадает в git, виден всем кто имеет доступ к репозиторию |
| `.env` файл на сервере | Нет версионирования, нет аудита, забывают бэкапить |
| Kubernetes Secret напрямую | Secret в K8s хранится в etcd в base64 (не шифровании!), легко читается через kubectl |
| Переменные в CI/CD | Разбросаны по разным системам, нет единого места |

Vault решает все эти проблемы:

- **Единое место хранения** — все секреты в одном месте, не разбросаны по системам
- **Шифрование** — данные зашифрованы на диске ключами которые Vault генерирует при инициализации
- **Аудит** — каждое чтение/запись секрета логируется: кто, когда, какой секрет
- **Версионирование** — каждое изменение секрета создаёт новую версию, можно откатиться
- **Политики доступа** — приложение A может читать только свои секреты, не чужие
- **Автоматическая ротация** — Vault умеет генерировать временные credentials (например, к БД) которые истекают через N часов

### Ключевые понятия

**Secrets Engine** — плагин внутри Vault который умеет хранить или генерировать секреты определённого типа. В вашем кластере используется `KV v2` (Key-Value version 2) — простое хранилище «ключ → значение» с версионированием.

**Auth Method** — способ аутентификации в Vault. В вашем кластере настроен `kubernetes` auth: Pod предъявляет свой Service Account токен, Vault проверяет его через Kubernetes API и выдаёт временный Vault-токен.

**Policy** — правило доступа. Описывает: какой путь в Vault (`secret/platform/*`) и какие операции (`read`, `list`) разрешены. Токен без нужной политики получит 403.

**Lease** — аренда. Каждый выданный токен или секрет имеет TTL (время жизни). После истечения токен становится невалидным. ESO автоматически обновляет токены, поэтому это прозрачно.

**Seal / Unseal** — Vault запускается в «запечатанном» состоянии (sealed). Он хранит мастер-ключ шифрования разбитым на N частей (у вас: 5 частей, нужно 3). Пока не введены 3 ключа — Vault не расшифровывает данные и не отвечает на запросы. Это защита от физической кражи сервера. `make vault-bootstrap` автоматически вводит ключи при старте.

---

## Раздел 2 — Как Vault устроен в вашем кластере

### Компоненты и их роли

```
┌─────────────────────────────────────────────────────────────┐
│  Локальная машина                                           │
│  credentials.env  ──► make vault-bootstrap                  │
└───────────────────────────────┬─────────────────────────────┘
                                │ засевает секреты
                                ▼
┌─────────────────────────────────────────────────────────────┐
│  Vault (namespace: vault)                                   │
│  3 реплики Raft HA                                          │
│  secret/platform/grafana    { admin_user, admin_password }  │
│  secret/platform/minio      { root_user, root_password }    │
│  secret/platform/velero     { access_key, secret_key }      │
│  secret/platform/registry   { url, username, password }     │
│  secret/platform/<app>      { ... }                         │
└──────────────────┬──────────────────────────────────────────┘
                   │ Kubernetes auth (Service Account JWT)
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  External Secrets Operator (namespace: external-secrets)    │
│  ClusterSecretStore "vault-backend"                         │
│  Читает секреты из Vault по политике eso-policy             │
└──────────────────┬──────────────────────────────────────────┘
                   │ создаёт/обновляет
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  Kubernetes Secret  (в нужном namespace)                    │
│  Обычный K8s Secret — приложение читает его как env var     │
└──────────────────┬──────────────────────────────────────────┘
                   │ env var / mounted file
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  Pod / Приложение                                           │
│  Не знает что такое Vault. Видит только переменную среды.   │
└─────────────────────────────────────────────────────────────┘
```

### Почему именно такая схема

Vault напрямую доступен только ESO. Приложения не знают о существовании Vault — они читают обычные Kubernetes Secrets. Это даёт:

1. **Независимость приложений от Vault** — можно заменить Vault на другой провайдер без изменения кода приложений
2. **Единая точка политик** — вся логика «кто что может читать» в Vault и в ExternalSecret манифестах, не размазана по коду
3. **GitOps совместимость** — ExternalSecret это YAML-манифест в git, изменения проходят через ArgoCD

### Структура секретов в вашем Vault

Все секреты платформы живут по пути `secret/platform/`:

```
secret/
  platform/
    grafana/        # Grafana admin credentials
    minio/          # MinIO root credentials
    velero/         # Velero S3 credentials
    argocd/         # ArgoCD admin password
    registry/       # Docker registry pull credentials
    <ваши-приложения>/
```

ESO имеет доступ только к `secret/platform/*` (политика `eso-policy`). Если нужно изолировать секреты приложений от платформенных — можно добавить отдельный путь и политику.

---

## Раздел 3 — Паттерн A: приложение не знает про Vault

Это основной паттерн в вашем кластере. Приложение получает секреты как обычные переменные среды, ничего не зная о Vault.

### Полный цикл: от секрета до приложения

**Шаг 1. Засеять секрет в Vault**

```bash
export KUBECONFIG=~/.kube/config-k8s-va
source credentials.env

kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/platform/myapp \
    db_password="super-secret-pass" \
    api_key="abc123xyz"
```

Также добавить в `credentials.env` на локальной машине (для rebuild кластера):
```bash
MYAPP_DB_PASSWORD="super-secret-pass"
MYAPP_API_KEY="abc123xyz"
```

И добавить в `make vault-bootstrap` строку:
```bash
vr kv put secret/platform/myapp \
  db_password="${MYAPP_DB_PASSWORD}" \
  api_key="${MYAPP_API_KEY}"
```

**Шаг 2. Создать ExternalSecret манифест в git**

Файл `platform/apps/myapp/externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secret
  namespace: va-dev
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-secret       # имя K8s Secret который будет создан
    creationPolicy: Owner    # ESO удалит Secret если ExternalSecret удалён
  data:
    - secretKey: db-password  # ключ в K8s Secret
      remoteRef:
        key: platform/myapp   # путь в Vault (без "secret/")
        property: db_password # поле в Vault
    - secretKey: api-key
      remoteRef:
        key: platform/myapp
        property: api_key
```

**Шаг 3. ArgoCD применяет манифест**

ArgoCD замечает новый файл в git и создаёт ExternalSecret ресурс в кластере. ESO подхватывает его, идёт в Vault, читает секрет, создаёт Kubernetes Secret `myapp-secret` в namespace `va-dev`.

Проверить статус:
```bash
kubectl get externalsecret myapp-secret -n va-dev
# READY: True означает что секрет синхронизирован

kubectl get secret myapp-secret -n va-dev -o jsonpath='{.data.db-password}' | base64 -d
# выведет реальный пароль
```

**Шаг 4. Использовать Secret в Pod**

В манифесте Deployment:
```yaml
spec:
  containers:
    - name: myapp
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: myapp-secret
              key: db-password
        - name: API_KEY
          valueFrom:
            secretKeyRef:
              name: myapp-secret
              key: api-key
```

Или смонтировать как файл:
```yaml
      volumeMounts:
        - name: secrets
          mountPath: /secrets
          readOnly: true
  volumes:
    - name: secrets
      secret:
        secretName: myapp-secret
```

### Ротация пароля без перезапуска

Когда нужно сменить пароль:

```bash
# 1. Обновить в Vault (создаёт новую версию)
source credentials.env
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/platform/myapp \
    db_password="new-secret-pass" \
    api_key="abc123xyz"

# 2. Обновить в credentials.env на локальной машине
# MYAPP_DB_PASSWORD="new-secret-pass"

# 3. ESO обновит K8s Secret автоматически в течение 1 часа (refreshInterval)
# Или форсировать немедленно:
kubectl annotate externalsecret myapp-secret -n va-dev \
  force-sync="$(date +%s)" --overwrite
```

После обновления K8s Secret приложение получит новый пароль **при следующем чтении переменной**. Если приложение кэширует env vars при старте (большинство приложений) — нужен rolling restart:
```bash
kubectl rollout restart deployment myapp -n va-dev
```

### Несколько окружений (va-dev, va-stage, va-prod)

Если секреты одинаковые для всех окружений — один путь в Vault, три ExternalSecret:

```yaml
# va-dev/externalsecret.yaml
metadata:
  namespace: va-dev
spec:
  data:
    - remoteRef:
        key: platform/myapp
---
# va-stage/externalsecret.yaml
metadata:
  namespace: va-stage
spec:
  data:
    - remoteRef:
        key: platform/myapp
```

Если секреты разные (prod БД другая чем dev) — разные пути в Vault:

```
secret/platform/myapp-dev/   { db_password: "dev-pass" }
secret/platform/myapp-prod/  { db_password: "prod-pass" }
```

---

## Раздел 4 — Паттерн B: приложение само ходит в Vault

### Когда ESO недостаточно

Паттерн A отлично работает для статических секретов (пароли, API-ключи). Но есть сценарии где нужно больше:

- **Динамические credentials** — Vault генерирует временные логин/пароль к PostgreSQL специально для вашего приложения, и они истекают через 1 час. Даже если злоумышленник их получит — через час они уже недействительны.
- **Секреты «на лету»** — приложение само запрашивает новый токен каждый раз, без перезапуска
- **Шифрование данных через Vault Transit** — приложение просит Vault зашифровать/расшифровать данные, ключи никогда не покидают Vault

### Способ B1: Vault Agent Sidecar (без изменений кода)

Vault Agent — отдельный контейнер (sidecar) в том же Pod, который:
1. Аутентифицируется в Vault через Kubernetes SA токен
2. Читает нужные секреты
3. Кладёт их в файл или переменные среды
4. Автоматически обновляет когда секрет меняется

Приложение по-прежнему читает файл — не знает о Vault.

```yaml
annotations:
  # включить injector (в вашем кластере injector отключён, используйте ESO)
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "myapp-role"
  vault.hashicorp.com/agent-inject-secret-config: "secret/data/platform/myapp"
  vault.hashicorp.com/agent-inject-template-config: |
    {{- with secret "secret/data/platform/myapp" -}}
    export DB_PASSWORD="{{ .Data.data.db_password }}"
    {{- end }}
```

> **Важно**: в вашем кластере Vault injector **отключён** (`injector.enabled: false` в vault-values.yaml). Выбор был сделан в пользу ESO как более простого и GitOps-совместимого решения. Если понадобится Vault Agent — нужно включить injector.

### Способ B2: Vault SDK в коде приложения

Приложение само аутентифицируется в Vault и читает секреты через HTTP API.

**Пример на Python:**
```python
import hvac
import os

# Аутентификация через Kubernetes Service Account
client = hvac.Client(url='https://vault.k8s.va.atmodev.net')

with open('/var/run/secrets/kubernetes.io/serviceaccount/token') as f:
    jwt = f.read()

client.auth.kubernetes.login(
    role='myapp-role',
    jwt=jwt
)

# Чтение секрета
secret = client.secrets.kv.v2.read_secret_version(
    path='platform/myapp',
    mount_point='secret'
)
db_password = secret['data']['data']['db_password']
```

**Пример на Go:**
```go
import vault "github.com/hashicorp/vault/api"

config := vault.DefaultConfig()
config.Address = "https://vault.k8s.va.atmodev.net"

client, _ := vault.NewClient(config)

// Kubernetes auth
token, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
resp, _ := client.Logical().Write("auth/kubernetes/login", map[string]interface{}{
    "role": "myapp-role",
    "jwt":  string(token),
})
client.SetToken(resp.Auth.ClientToken)

// Чтение секрета
secret, _ := client.Logical().Read("secret/data/platform/myapp")
data := secret.Data["data"].(map[string]interface{})
dbPassword := data["db_password"].(string)
```

### Настройка Vault Role для приложения (нужна для обоих B-вариантов)

Чтобы Pod мог аутентифицироваться в Vault, нужно:

**1. Создать политику доступа:**
```bash
source credentials.env
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault policy write myapp-policy - <<'EOF'
path "secret/data/platform/myapp" {
  capabilities = ["read"]
}
path "secret/metadata/platform/myapp" {
  capabilities = ["read"]
}
EOF
```

**2. Создать роль привязанную к Service Account:**
```bash
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault write auth/kubernetes/role/myapp-role \
    bound_service_account_names="myapp" \
    bound_service_account_namespaces="va-dev,va-stage,va-prod" \
    policies="myapp-policy" \
    ttl=1h
```

**3. Создать Service Account в namespace:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myapp
  namespace: va-dev
```

**4. Использовать этот SA в Deployment:**
```yaml
spec:
  serviceAccountName: myapp
```

### Когда выбирать какой паттерн

| Ситуация | Паттерн |
|---|---|
| Пароль к БД, API-ключ — не меняются часто | **A (ESO)** |
| Credentials нужны при старте и потом не меняются | **A (ESO)** |
| Нужна горячая ротация без перезапуска Pod | **B1 (Vault Agent)** |
| Динамические DB credentials с TTL | **B2 (SDK)** |
| Шифрование данных через Vault Transit | **B2 (SDK)** |
| Нет времени менять код приложения | **A (ESO)** или **B1 (Agent)** |

Для вашего текущего стека рекомендую **паттерн A** для всех приложений — он уже настроен, прост в поддержке и хорошо вписывается в GitOps. Паттерн B нужен только при появлении конкретных требований к динамическим credentials или шифрованию.

---

## Раздел 5 — Ежедневные операции

### Доступ к Vault

**Через браузер (UI):**
```
URL: https://vault.k8s.va.atmodev.net
Method: Token
Token: значение VAULT_ROOT_TOKEN из credentials.env
```

В UI: Secrets → secret → platform → выбрать нужный секрет.

**Через CLI (из терминала):**
```bash
export KUBECONFIG=~/.kube/config-k8s-va
source credentials.env

# Алиас для удобства (можно добавить в ~/.zshrc)
alias vault-exec='kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault'
```

### Просмотр секретов

```bash
# Список всех секретов в platform/
vault-exec kv list secret/platform/

# Прочитать конкретный секрет (последняя версия)
vault-exec kv get secret/platform/grafana

# Прочитать конкретное поле
vault-exec kv get -field=admin_password secret/platform/grafana

# Прочитать конкретную версию (история)
vault-exec kv get -version=2 secret/platform/grafana

# Посмотреть метаданные и историю версий
vault-exec kv metadata get secret/platform/grafana
```

### Добавление нового секрета

```bash
# Создать новый секрет
vault-exec kv put secret/platform/newapp \
  key1="value1" \
  key2="value2"

# Добавить поле к существующему (не перезаписывая другие)
vault-exec kv patch secret/platform/myapp \
  new_field="new_value"
```

### Обновление / ротация

```bash
# Обновить секрет (все поля нужно указать заново, иначе они будут удалены)
vault-exec kv put secret/platform/grafana \
  admin_user="admin" \
  admin_password="новый_пароль_2024"

# Форсировать ESO синхронизацию немедленно
kubectl annotate externalsecret grafana-admin -n monitoring \
  force-sync="$(date +%s)" --overwrite
```

### Откат к предыдущей версии

```bash
# Посмотреть доступные версии
vault-exec kv metadata get secret/platform/grafana

# Восстановить версию 2
vault-exec kv undelete -versions=2 secret/platform/grafana

# Теперь сделать её текущей через patch или put
vault-exec kv get -version=2 -field=admin_password secret/platform/grafana
# скопировать значение и записать как текущее
vault-exec kv put secret/platform/grafana \
  admin_user="admin" \
  admin_password="<значение из версии 2>"
```

### Удаление секрета

```bash
# Удалить последнюю версию (данные удалены, метаданные остались)
vault-exec kv delete secret/platform/old-app

# Удалить полностью (метаданные и все версии)
vault-exec kv metadata delete secret/platform/old-app
```

### Проверка состояния ESO синхронизации

```bash
# Статус всех ExternalSecrets в кластере
kubectl get externalsecret -A

# Детали конкретного (что пошло не так если READY: False)
kubectl describe externalsecret grafana-admin -n monitoring

# Проверить что Secret реально создан и содержит данные
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data}' | \
  python3 -c "import sys,json,base64; d=json.load(sys.stdin); \
  [print(k,'=',base64.b64decode(v).decode()) for k,v in d.items()]"
```

### Просмотр audit log

Vault логирует каждый запрос. Чтобы увидеть кто читал секреты:

```bash
# Включить audit log (если не включён)
vault-exec audit enable file file_path=/vault/audit/audit.log

# Посмотреть лог
kubectl exec -n vault vault-0 -- tail -f /vault/audit/audit.log | \
  python3 -m json.tool | grep -E '"path"|"operation"|"remote_address"'
```

---

## Раздел 6 — Шпаргалка по вашей установке

### Параметры подключения

| Параметр | Значение |
|---|---|
| UI URL | https://vault.k8s.va.atmodev.net |
| Internal address (внутри кластера) | `http://vault.vault.svc.cluster.local:8200` |
| Auth method | `kubernetes` |
| ESO Role | `eso-role` |
| ESO Policy | `eso-policy` (read `secret/platform/*`) |
| Root token | `VAULT_ROOT_TOKEN` из `credentials.env` |

### Быстрые команды

```bash
# Подготовка
export KUBECONFIG=~/.kube/config-k8s-va
source credentials.env

# Статус Vault
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault status

# Все секреты платформы
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv list secret/platform/

# Все ExternalSecrets и их статус
kubectl get externalsecret -A

# Состояние Vault pods
kubectl get pods -n vault
```

### Текущие секреты и соответствующие ExternalSecrets

| Vault path | ExternalSecret | Namespace | K8s Secret |
|---|---|---|---|
| `secret/platform/grafana` | `grafana-admin` | monitoring | `grafana-admin` |
| `secret/platform/minio` | `minio-credentials` | minio | `minio-credentials` |
| `secret/platform/velero` | `velero-credentials` | velero | `velero-credentials` |
| `secret/platform/registry` | `registry-pull-secret` | va-dev/stage/prod | `registry-pull-secret` |

### Действия при инциденте

**Vault sealed после рестарта:**
```bash
make vault-bootstrap
# автоматически распечатает все реплики
```

**ESO не синхронизирует (READY: False):**
```bash
# 1. Проверить что Vault доступен и не sealed
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status

# 2. Проверить что секрет существует в Vault
source credentials.env
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv get secret/platform/<name>

# 3. Если секрет не существует — засеять:
make vault-bootstrap
```

**Секрет не попадает в Pod:**
```bash
# Проверить цепочку: ExternalSecret → K8s Secret → Pod env
kubectl get externalsecret <name> -n <ns>            # должен быть READY: True
kubectl get secret <name> -n <ns>                    # должен существовать
kubectl exec <pod> -n <ns> -- env | grep <VAR_NAME>  # должна быть переменная
```

### Алгоритм добавления секрета для нового приложения

```
1. Добавить в credentials.env:
   MYAPP_SECRET="value"

2. Добавить строку в vault-bootstrap.sh (секция "seed secrets"):
   vr kv put secret/platform/myapp secret="${MYAPP_SECRET}"

3. Засеять в Vault (на текущем кластере):
   make vault-bootstrap   # пересеет всё из credentials.env

4. Создать platform/apps/myapp/externalsecret.yaml (скопировать пример из Раздела 3)

5. Добавить ExternalSecret как source в platform/argocd-apps/app-myapp.yaml

6. git commit + push → ArgoCD применит → ESO создаст K8s Secret

7. В Deployment использовать secretKeyRef на созданный Secret
```
