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
- SSH-ключ с локальной машины → все ноды без пароля
- `sudo NOPASSWD` для пользователя `ubuntu` на всех нодах
- Локальная машина имеет выход в интернет (для скачивания образов и helm charts)

### Инструменты на локальной машине (macOS)
```bash
brew install ansible helm kubectl vault
pip3 install jinja2 netaddr
```

---

## Шаг 0. Настройка конфигурации

Перед запуском заменить все плейсхолдеры (`ЗАМЕНИТЬ`) в репозитории.

### 0.1 IP-адреса нод

Файл `ansible/inventory/prod/hosts.yaml`:
```yaml
cp-1:
  ansible_host: <CP1_IP>      # IP control-plane 1
cp-2:
  ansible_host: <CP2_IP>      # IP control-plane 2
cp-3:
  ansible_host: <CP3_IP>      # IP control-plane 3
worker-1:
  ansible_host: <WORKER1_IP>
# ... остальные воркеры
```

### 0.2 kube-vip и API VIP

Файл `ansible/inventory/prod/group_vars/all/vars.yml`:
```yaml
loadbalancer_apiserver_address: "<API_VIP>"   # свободный IP в подсети нод
kube_vip_interface: "eth0"                    # сетевой интерфейс нод (enp3s0 / ens3 / etc.)
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

Файл `ansible/inventory/prod/group_vars/all/containerd.yml`:
```yaml
containerd_registries_mirrors:
  "registry.company.com":
    - "https://registry.company.com"
```

---

## Шаг 1. Подготовка хостов

Playbook настраивает: kernel modules, sysctl, containerd, chrony (NTP).

```bash
cd /path/to/repo
make host-prep
```

**Или напрямую:**
```bash
cd ansible && ansible-playbook -i inventory/prod/hosts.yaml playbooks/00-host-prep.yaml
```

**Проверка:**
```bash
ansible all -i ansible/inventory/prod/hosts.yaml -m shell -a "systemctl is-active containerd"
# Ожидается: active на всех нодах

ansible all -i ansible/inventory/prod/hosts.yaml -m shell -a "chronyc tracking | grep 'Leap status'"
# Ожидается: Normal
```

---

## Шаг 2. Bootstrap кластера (Kubespray)

Kubespray запускает kubeadm на всех нодах, поднимает etcd (stacked), настраивает Calico CNI.

```bash
make bootstrap
```

**Или напрямую:**
```bash
cd ansible && ansible-playbook -i inventory/prod/hosts.yaml playbooks/10-kubespray.yaml
```

> Время выполнения: ~20–40 минут в зависимости от скорости сети (скачивание образов).

**Проверка по окончании:**
```bash
# На любом control-plane
ssh ubuntu@<CP1_IP>
sudo kubectl get nodes -o wide
# Ожидается: 3 control-plane + N workers в статусе Ready

sudo kubectl get pods -n kube-system
# Ожидается: все поды Running/Completed

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

Скачивает kubeconfig на локальную машину, проверяет доступность API через VIP.

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

**Или напрямую:**
```bash
bash platform/bootstrap/bootstrap.sh
```

> Скрипт идемпотентен — можно запускать повторно.

В конце скрипт выведет пароль admin для Argo CD UI.

**Проверки:**

```bash
# MetalLB: LoadBalancer получил IP
kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP должен быть из пула MetalLB

# ingress-nginx: отвечает
curl -s -o /dev/null -w "%{http_code}" http://<METALLB_IP>/
# Ожидается: 404 (nginx default backend)

# cert-manager: поды running
kubectl get pods -n cert-manager
kubectl get clusterissuers
# Ожидается: letsencrypt-staging и letsencrypt-prod в Ready=True

# Argo CD UI
kubectl get svc -n argocd argocd-server
# Открыть в браузере https://<ARGOCD_VIP>
# Логин: admin / <пароль из вывода скрипта>
```

---

## Шаг 5. Подключение git-репозитория к Argo CD

Если репозиторий приватный — добавить SSH-ключ или token.

**Через CLI:**
```bash
argocd login <ARGOCD_VIP> --username admin --password <PASSWORD> --insecure

# SSH-ключ
argocd repo add git@<GIT_HOST>:<ORG>/k8s-platform.git \
  --ssh-private-key-path ~/.ssh/id_rsa

# Или HTTPS token
argocd repo add https://<GIT_HOST>/<ORG>/k8s-platform.git \
  --username <USER> --password <TOKEN>
```

**Проверка:**
```bash
argocd repo list
# Ожидается: ConnectionStatus=Successful
```

---

## Шаг 6. Запуск App-of-Apps (GitOps-переход)

Root-application уже применена скриптом bootstrap. Argo CD начинает синхронизацию платформенных сервисов автоматически.

**Следить за прогрессом:**
```bash
watch kubectl get applications -n argocd
```

Argo CD задеплоит в следующем порядке (управляется `platform/apps/_root.yaml`):
1. `namespaces` — va-dev, va-stage, va-prod + RBAC + ResourceQuota
2. `policies` — NetworkPolicy defaults
3. `storage` — StorageClasses, nfs-csi
4. `secrets` — Vault + External Secrets Operator
5. `observability` — kube-prometheus-stack + Loki + promtail
6. `backup` — Velero

> Vault нужно вручную инициализировать и unseal — см. [vault-unseal runbook](runbooks/vault-unseal.md).

---

## Шаг 7. Инициализация Vault

```bash
# Инициализация (один раз)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 \
  -format=json > vault-init.json

# ВАЖНО: сохранить vault-init.json в защищённое место (не в git)

# Unseal на каждой из 3 реплик
for pod in vault-0 vault-1 vault-2; do
  for i in 1 2 3; do
    key=$(jq -r ".unseal_keys_b64[$i]" vault-init.json)
    kubectl exec -n vault $pod -- vault operator unseal $key
  done
done
```

Подробнее — [runbook vault-unseal](runbooks/vault-unseal.md).

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

# cert-manager: тестовый Certificate
kubectl get certificates -A

# Velero: backup работает
velero backup create smoke-test --wait
velero backup get smoke-test

# Observability: Grafana доступна
kubectl get ingress -n monitoring
```

---

## Быстрый старт (все шаги одной цепочкой)

```bash
export KUBECONFIG=~/.kube/config-k8s-va

# 1–3. Инфраструктура + кластер
make host-prep && make bootstrap && make post-bootstrap

# 4. Платформа до Argo CD
make bootstrap-platform

# Дальше следить через: watch kubectl get applications -n argocd
```

---

## Отмена / сброс кластера

```bash
make reset
# Запрашивает подтверждение (5 сек). Уничтожает кластер на всех нодах.
```
