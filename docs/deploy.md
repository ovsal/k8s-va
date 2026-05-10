# Деплой кластера (актуально)

Эта инструкция описывает **текущий минимальный сценарий**: поднять Kubernetes (Kubespray) и поставить базовые компоненты платформы:
**MetalLB → ingress-nginx → cert-manager → Argo CD**.

В репозитории **больше нет** шагов/целей для Vault/MinIO/Velero/«сеединга» секретов и прочих компонентов — старые разделы удалены из документа.

---

## Что есть в репозитории

- `cluster/`: inventory и Ansible playbooks для подготовки хостов и Kubespray
- `platform/bootstrap/`: bootstrap-скрипт и значения Helm для MetalLB/ingress-nginx/cert-manager/Argo CD
- `Makefile`: команды-обёртки (см. `make help`)

---

## Предварительные требования

### Инфраструктура (пример)

| Роль | Кол-во | CPU | RAM | Диск | ОС |
|---|---:|---:|---:|---:|---|
| control-plane | 3 | 4 vCPU | 8 GB | 80 GB SSD | Ubuntu 24.04 LTS |
| worker | N | 8 vCPU | 16 GB | 100 GB | Ubuntu 24.04 LTS |

### Сеть
- **L2-сеть** между всеми нодами (MetalLB в L2 режиме)
- **Пул свободных IP** для MetalLB (не пересекается с DHCP)
- **API VIP (kube-vip)**: отдельный свободный IP из той же подсети

### Доступ
- SSH-ключ с локальной машины → все ноды без пароля (пользователь `ansible`)
- `sudo NOPASSWD` для пользователя `ansible` на всех нодах
- Локальная машина имеет выход в интернет (скачивание образов/чартов)

### Инструменты на локальной машине (macOS)

```bash
brew install helm kubectl ansible
```

### Kubespray: submodule и venv

Kubespray (submodule) требует `ansible-core 2.17.x` (и падает на 2.18+). Подготовьте окружение один раз:

```bash
git submodule update --init --recursive

cd cluster
python3 -m venv .venv
.venv/bin/pip install --quiet ansible==10.7.0 jmespath netaddr cryptography
.venv/bin/ansible-playbook --version | head -1
# ansible-playbook [core 2.17.x]
```

---

## Шаг 0. Настройка конфигурации

Перед запуском замените плейсхолдеры `ЗАМЕНИТЬ` в репозитории.

### 0.1 Инвентори: IP и доступ к нодам

Файл `cluster/inventory/prod/hosts.yaml` — укажите IP и пользователя `ansible`.

### 0.2 kube-vip: API VIP

Файл `cluster/inventory/prod/group_vars/all/vars.yml`:
- `loadbalancer_apiserver.address`
- `kube_vip_address`
- `kube_vip_interface` (например, `eth0`/`ens3` — по факту на ваших VM)

### 0.3 MetalLB: пул IP

Файл `platform/bootstrap/metallb/resources.yaml`:
- в `spec.addresses` замените диапазон (комментарий `# ЗАМЕНИТЬ на METALLB_POOL`)

### 0.4 cert-manager (опционально): Let's Encrypt email

Файл `platform/bootstrap/cert-manager/cluster-issuers.yaml`:
- замените `email: ... # ЗАМЕНИТЬ`

Примечание: issuers создаются всегда, но **сертификаты начнут выпускаться только когда** вы создадите Ingress/Certificate и обеспечите доступность HTTP-01 (порт 80 через ingress-nginx).

---

## Шаг 1. Подготовка хостов

```bash
make host-prep
```

Что делает: отключает swap, настраивает sysctl/kernel modules, ставит/запускает containerd и т.п. (см. `cluster/playbooks/00-host-prep.yaml`).

---

## Шаг 2. Bootstrap кластера (Kubespray)

```bash
make bootstrap
```

---

## Шаг 3. Post-bootstrap (kubeconfig на локальную машину)

```bash
make post-bootstrap
```

Результат:
- kubeconfig сохраняется в `~/.kube/config-k8s-va`
- в kubeconfig **подменяется адрес API** на VIP из `loadbalancer_apiserver.address`
- в `~/.zshrc` добавляется `export KUBECONFIG=...`

Проверка:

```bash
kubectl get nodes -o wide
```

---

## Шаг 4. Bootstrap базовых компонентов платформы

Скрипт `platform/bootstrap/bootstrap.sh` устанавливает в правильном порядке:
**MetalLB → ingress-nginx → cert-manager → Argo CD** и печатает пароль admin.

```bash
make bootstrap-platform
```

Проверки:

```bash
# ingress-nginx должен получить EXTERNAL-IP из пула MetalLB
kubectl -n ingress-nginx get svc ingress-nginx-controller

# cert-manager должен быть Running
kubectl -n cert-manager get pods
kubectl get clusterissuers

# Argo CD должен быть Running
kubectl -n argocd get pods
```

---

## (Опционально) GitOps через Argo CD

Скрипт bootstrap применяет `platform/bootstrap/argocd/root-app.yaml`.
Сейчас он указывает `spec.source.path: platform/argocd-apps`.

Если вы хотите включить GitOps:
- создайте каталог `platform/argocd-apps` с `Application` манифестами (App-of-Apps) **или**
- измените `root-app.yaml` на актуальный `repoURL/path/targetRevision`.

В текущем состоянии репозитория уже добавлены GitOps приложения для storage:
- `platform/argocd-apps/storage/longhorn/application.yaml`
- `platform/argocd-apps/storage/local-path/application.yaml`
- `platform/argocd-apps/storage/smoke/storage-smoke.yaml` (smoke-тест PVC/POD)

---

## Быстрый старт

```bash
make host-prep
make bootstrap
make post-bootstrap
make bootstrap-platform
```

---

## Сброс кластера (DESTRUCTIVE)

```bash
make reset
```
