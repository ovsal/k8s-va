## Longhorn

### Зачем нужен

Longhorn — распределённое блочное хранилище (CSI) для Kubernetes. В этом кластере Longhorn используется как **HA StorageClass** для stateful-нагрузок:
- PVC с репликацией между воркерами (переживает потерю одной worker-ноды)
- расширение томов (`allowVolumeExpansion: true`)
- диагностика и операции обслуживания через UI

Ключевая идея: приложения **явно выбирают** StorageClass под требуемый уровень надёжности/стоимости.

### Как деплоится

Longhorn ставится **скриптом** `platform/bootstrap/bootstrap.sh` (Helm) **до** Argo CD — так у Vault и других stateful-сервисов есть StorageClass и CSI до GitOps.

- **Values (как код)**: `platform/bootstrap/longhorn/values.yaml`
- **StorageClass `longhorn-ha`**: `platform/bootstrap/longhorn/storageclass-longhorn-ha.yaml`
- **Ingress UI**: `platform/bootstrap/longhorn/ingress-ui.yaml`
- Namespace: **`longhorn-system`**
- Helm chart: **`longhorn/longhorn`** версии **`1.11.2`**

Важные настройки:
- **dataPath**: на воркерах **`/storage/longhorn`**
- **репликация**: `defaultClassReplicaCount: 2`, **default StorageClass выключен** (`persistence.defaultClass: false`)
- **`preUpgradeChecker.jobEnabled: false`** — чтобы не блокировать установку hook-job (актуально и для Helm из bootstrap)

Подготовка директорий на нодах: `cluster/roles/host-prep/tasks/system.yml` — `/storage/longhorn` при наличии `/storage`.

Подготовка директорий на нодах выполняется `host-prep`:
- `cluster/roles/host-prep/tasks/system.yml` создаёт `/storage/longhorn` (если существует `/storage`)

### Как использовать (для других систем)

#### StorageClass’ы

В кластере есть несколько StorageClass от Longhorn, но для приложений мы используем **явно заданный**:
- **`longhorn-ha`** — основной класс для HA томов (2 реплики)
  - манифест: `platform/bootstrap/longhorn/storageclass-longhorn-ha.yaml`

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

#### Зачем нужен

Longhorn предоставляет UI для управления хранилищем:
- просмотр нод/дисков и их ёмкости
- просмотр/диагностика томов и реплик
- операции обслуживания (snapshots, backup target, восстановление, troubleshooting)

#### Как деплоится

UI ставится **вместе с Longhorn** из bootstrap (тот же Helm-релиз).

Для доступа снаружи:
- манифест: `platform/bootstrap/longhorn/ingress-ui.yaml`
- ingress class: `nginx` (ingress-nginx)
- TLS: cert-manager, `ClusterIssuer` = `letsencrypt-prod`
- hostname: `longhorn.k8s.va.atmodev.net`

Требования:
- DNS `longhorn.k8s.va.atmodev.net` должен указывать на внешний IP ingress-nginx
- Порт 80/443 на этом IP должен быть доступен (для HTTP-01 challenge Let's Encrypt)

#### Как использовать (для других систем)

Longhorn UI — это административный интерфейс и обычно не используется приложениями напрямую.

#### Ограничение доступа (сеть и авторизация)

На Ingress `longhorn-ui` включено:

- **Фильтр по IP** (`nginx.ingress.kubernetes.io/whitelist-source-range`): по умолчанию **`176.113.118.0/24`**. Запросы с других адресов получают **403** (ответ от nginx, до UI Longhorn).
- **Basic Auth** (логин/пароль на уровне nginx): секрет **`longhorn-ui-basic-auth`** в `longhorn-system`. Создание: **`make longhorn-ui-basic-auth`** или `bash platform/bootstrap/longhorn/longhorn-ui-basic-auth-secret.sh` (переменные `LONGHORN_UI_USER`, `LONGHORN_UI_PASSWORD` — см. комментарии в скрипте).

Порядок при первом включении: сначала создать секрет Basic Auth, затем **`kubectl apply -f platform/bootstrap/longhorn/ingress-ui.yaml`**. Если применить Ingress без секрета, nginx может отдавать **503** до появления секрета.

**Про TLS (Let's Encrypt):** HTTP-01 challenge идёт через **отдельные** Ingress, которые создаёт cert-manager; на них нет вашего whitelist — продление сертификата не блокируется whitelist’ом на `longhorn-ui`.

**Если клиенты за NAT/прокси:** nginx видит IP TCP-сессии до балансировщика. За корпоративным HTTP-прокси без проброса реального клиента whitelist может «не совпасть» с ожиданиями — тогда либо вход с адресов из `/24`, либо настройка `X-Forwarded-For` и политики доверия на ingress-nginx (отдельная тема).

##### Другие варианты авторизации (на выбор)

| Вариант | Плюсы | Минусы |
|--------|--------|--------|
| **Basic Auth на Ingress** (текущая схема в репозитории) | Просто, без новых подов, секрет не в Git | Один общий пароль; пароль уходит при каждом запросе (HTTPS обязателен — у вас есть TLS) |
| **oauth2-proxy** (или аналог) перед UI | SSO, MFA, отзыв сессий | Дополнительный Deployment/SVC, интеграция с IdP |
| **Forward-auth** (`auth-url` / `auth-signin` nginx) к **Authelia**, **oauth2-proxy**, своему сервису | Гибкая политика, единый вход с другими приложениями | Сложнее в эксплуатации |
| **Только сеть** (VPN / bastion + whitelist на firewall) | Минимум движущихся частей в кластере | Нет второго фактора на уровне HTTP; доступ «все из VPN» |
| **Доступ только через `kubectl port-forward`**, без публичного Ingress | Максимально узкая поверхность | Нет веб-UI из браузера без туннеля |

Longhorn по умолчанию не заменяет полноценный IdP на границе; для админ-UI обычно комбинируют **ограничение по сети** + **Basic Auth или SSO**.

