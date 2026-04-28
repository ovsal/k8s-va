# Деплой кластера: пошаговый алгоритм

Инструкция охватывает полный цикл от пустых VM до production-ready кластера с GitOps.

---

## Предварительные требования

### Инфраструктура

| Роль | Кол-во | CPU | RAM | Диск | ОС |
|---|---|---|---|---|---|
| control-plane | 3 | 4 vCPU | 8 GB | 80 GB SSD | Ubuntu 24.04 LTS |
| worker | N | 8 vCPU | 16 GB | 100 GB | Ubuntu 24.04 LTS |

### Сеть
- L2-сеть между всеми нодами
- Пул свободных IP ≥ 10 адресов под MetalLB (не пересекается с DHCP)
- DNS: `*.k8s.va.atmodev.net` → VIP MetalLB (или временно в `/etc/hosts`)
- API VIP (kube-vip): отдельный свободный IP из той же подсети

### Доступ
- SSH-ключ с локальной машины → все ноды без пароля (пользователь `ansible`)
- `sudo NOPASSWD` для пользователя `ansible` на всех нодах
- Локальная машина имеет выход в интернет (для скачивания образов и helm charts)

### Инструменты на локальной машине (macOS)
```bash
brew install helm kubectl vault ansible
```

Kubespray v2.30 жёстко проверяет версию ansible-core (`2.17.3 ≤ x < 2.18.0`) и отказывает при 2.18+.
Создать отдельный venv один раз:
```bash
cd cluster
python3 -m venv .venv
.venv/bin/pip install --quiet ansible==10.7.0 jmespath netaddr cryptography
# Проверка:
.venv/bin/ansible-playbook --version | head -1
# ansible-playbook [core 2.17.x]
```

---

## Шаг 0. Настройка конфигурации

Перед запуском заменить все плейсхолдеры (`ЗАМЕНИТЬ`) в репозитории.

### 0.1 IP-адреса нод

Файл `cluster/inventory/prod/hosts.yaml`:
```yaml
cp-1:
  ansible_host: <CP1_IP>      # IP control-plane 1
  ansible_user: ansible
cp-2:
  ansible_host: <CP2_IP>
  ansible_user: ansible
cp-3:
  ansible_host: <CP3_IP>
  ansible_user: ansible
worker-1:
  ansible_host: <WORKER1_IP>
  ansible_user: ansible
# ... остальные воркеры
```

### 0.2 kube-vip и API VIP

Файл `cluster/inventory/prod/group_vars/all/vars.yml`:
```yaml
loadbalancer_apiserver:
  address: "<API_VIP>"   # свободный IP в подсети нод
  port: 6443
kube_vip_address: "<API_VIP>"
kube_vip_interface: "eth0"   # сетевой интерфейс нод (уточнить: eth0, ens3, enp3s0)
```

### 0.3 Пул IP для MetalLB

Файл `platform/bootstrap/metallb/resources.yaml`:
```yaml
addresses:
  - <METALLB_START>-<METALLB_END>   # напр. 192.168.1.200-192.168.1.220
```

### 0.4 cert-manager: Let's Encrypt

Файл `platform/bootstrap/cert-manager/cluster-issuers.yaml`:
- Заменить `ops@company.com` на реальный email (уведомления об истечении сертификатов)

Требования к домену:
- DNS `*.k8s.va.atmodev.net` должен резолвиться в публичный IP ingress-nginx до запуска bootstrap
- Порт 80 на этом IP должен быть доступен из интернета (Let's Encrypt HTTP-01 challenge)

### 0.5 Argo CD: git-репозиторий

Файл `platform/bootstrap/argocd/root-app.yaml`:
```yaml
repoURL: https://<GIT_HOST>/<ORG>/k8s-platform.git
```

### 0.6 Container registry (опционально)

Файл `cluster/inventory/prod/group_vars/all/containerd.yml`:
```yaml
containerd_registries_mirrors:
  "registry.company.com":
    - "https://registry.company.com"
```

### 0.7 Инициализация git submodule (Kubespray)

```bash
git submodule update --init --recursive
```

---

## Шаг 1. Подготовка хостов

Playbook настраивает: kernel modules, sysctl, containerd, chrony (NTP).

```bash
make host-prep
```

**Или напрямую:**
```bash
cd cluster && ansible-playbook -i inventory/prod/hosts.yaml playbooks/00-host-prep.yaml
```

**Проверка:**
```bash
cd cluster
ansible all -i inventory/prod/hosts.yaml -m shell -a "systemctl is-active containerd"
# Ожидается: active на всех нодах

ansible all -i inventory/prod/hosts.yaml -m shell -a "chronyc tracking | grep 'Leap status'"
# Ожидается: Normal
```

---

## Шаг 2. Bootstrap кластера (Kubespray)

Kubespray запускает kubeadm на всех нодах, поднимает etcd (stacked), настраивает Calico CNI.

> **Требование к версии ansible**: Kubespray v2.30 проверяет `2.17.3 ≤ ansible-core < 2.18.0` и завершается с ошибкой при других версиях. Необходимо использовать venv.

> **Ubuntu 24.04**: `unattended-upgrades` стартует сразу после загрузки VM и может заблокировать apt во время bootstrap. Kubespray отключит его автоматически — `ubuntu_stop_unattended_upgrades: true` уже задан в inventory.

Запускать **из директории `cluster/`** (чтобы подхватился `ansible.cfg`):

```bash
cd cluster
.venv/bin/ansible-playbook -b -i inventory/prod/hosts.yaml playbooks/10-kubespray.yaml
```

> Время выполнения: ~20–40 минут в зависимости от скорости сети (скачивание образов).

**Проверка по окончании:**
```bash
# На любом control-plane
ssh ansible@<CP1_IP>
sudo kubectl get nodes -o wide
# Ожидается: 3 control-plane + N workers в статусе Ready

sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/node-cp-1.pem \
  --key=/etc/ssl/etcd/ssl/node-cp-1-key.pem \
  endpoint health --cluster
# Ожидается: 3/3 healthy
```

---

## Шаг 3. Post-bootstrap

Скачивает kubeconfig на локальную машину, заменяет адрес cp-1 на kube-vip VIP.

```bash
make post-bootstrap
```

После выполнения:
```bash
export KUBECONFIG=~/.kube/config-k8s-va
kubectl get nodes
```

---

## Шаг 4. Bootstrap платформенных компонентов (pre-Argo CD)

Устанавливает в правильном порядке: MetalLB → ingress-nginx → cert-manager → Argo CD.

```bash
export KUBECONFIG=~/.kube/config-k8s-va
make bootstrap-platform
```

Скрипт идемпотентен — можно запускать повторно.
В конце выводит пароль admin для Argo CD UI.

**Проверки:**
```bash
# MetalLB: LoadBalancer получил IP
kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP должен быть из пула MetalLB

# cert-manager: поды running
kubectl get pods -n cert-manager
kubectl get clusterissuers
# Ожидается: letsencrypt-staging и letsencrypt-prod в Ready=True
```

---

## Шаг 5. Подключение git-репозитория к Argo CD

Если репозиторий приватный — добавить SSH-ключ или token.

```bash
argocd login <ARGOCD_VIP> --username admin --password <PASSWORD> --insecure

# HTTPS token
argocd repo add https://<GIT_HOST>/<ORG>/k8s-platform.git \
  --username <USER> --password <TOKEN>
```

---

## Шаг 6. Запуск App-of-Apps (GitOps-переход)

Root-application уже применена скриптом bootstrap. Argo CD начинает синхронизацию платформенных сервисов автоматически.

```bash
watch kubectl get applications -n argocd
```

Argo CD задеплоит в следующем порядке:
1. `namespaces` — va-dev, va-stage, va-prod + RBAC + ResourceQuota
2. `policies` — NetworkPolicy defaults
3. `storage` — StorageClasses, nfs-csi (или local-path-provisioner временно)
4. `secrets` — Vault + External Secrets Operator
5. `observability` — kube-prometheus-stack + Loki + promtail
6. `backup` — Velero

> Vault нужно вручную инициализировать и unseal — см. [vault-unseal runbook](runbooks/vault-unseal.md).

---

## Шаг 7. Инициализация Vault

```bash
# Инициализация (один раз, выполнить сразу после того как все vault pods Running)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 \
  -format=json > vault-init.json

# ВАЖНО: сохранить vault-init.json в защищённое место (не в git!)

# Unseal на каждой из 3 реплик (нужны любые 3 из 5 ключей)
for pod in vault-0 vault-1 vault-2; do
  for i in 0 1 2; do
    key=$(jq -r ".unseal_keys_b64[$i]" vault-init.json)
    kubectl exec -n vault $pod -- vault operator unseal $key
  done
done
```

После unseal настроить Vault для ESO:
```bash
ROOT_TOKEN=$(jq -r '.root_token' vault-init.json)

# KV v2 secret engine
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$ROOT_TOKEN \
  vault secrets enable -path=secret kv-v2

# Kubernetes auth
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$ROOT_TOKEN \
  vault auth enable kubernetes

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$ROOT_TOKEN \
  vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"

# Policy и role для ESO
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$ROOT_TOKEN vault policy write eso-policy - <<'EOF'
path "secret/data/*" { capabilities = ["read","list"] }
path "secret/metadata/*" { capabilities = ["read","list"] }
EOF

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$ROOT_TOKEN \
  vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="eso-policy" \
    ttl="1h"
```

---

## Итоговая проверка

```bash
# Все ноды Ready
kubectl get nodes -o wide

# Нет проблемных подов
kubectl get pods -A | grep -v Running | grep -v Completed

# Все Argo CD Applications Synced/Healthy
kubectl get applications -n argocd

# MetalLB: LoadBalancer IP выдаётся
kubectl get svc -A | grep LoadBalancer

# Vault unsealed
kubectl -n vault exec vault-0 -- vault status | grep Sealed
# Sealed: false
```

---

## Быстрый старт (все шаги одной цепочкой)

```bash
export KUBECONFIG=~/.kube/config-k8s-va

# 1. Подготовка нод
make host-prep

# 2. Bootstrap кластера (venv обязателен — Kubespray требует ansible-core 2.17.x)
cd cluster && .venv/bin/ansible-playbook -b -i inventory/prod/hosts.yaml playbooks/10-kubespray.yaml
cd ..

# 3. Получить kubeconfig
make post-bootstrap

# 4. Платформа до Argo CD
make bootstrap-platform

# Дальше следить через:
watch kubectl get applications -n argocd
```

---

## Отмена / сброс кластера

```bash
make reset
# Запрашивает подтверждение (5 сек). Уничтожает кластер на всех нодах.
```
