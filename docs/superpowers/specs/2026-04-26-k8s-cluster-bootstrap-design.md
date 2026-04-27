# Design: Kubernetes Cluster Bootstrap для видеоархива

**Дата:** 2026-04-26
**Статус:** Approved
**Автор:** SRE/DevOps (brainstorm session)

---

## Контекст и цель

Платформа видеоархива для realtime-вещательных студий сейчас работает на Docker.
Цель — перевести её на Kubernetes для:
- управляемого деплоя и rolling-update'ов микросервисов;
- унифицированного observability и SLA на инцидентах;
- готовности к горизонтальному масштабированию по студиям.

**Скоуп:** только bootstrap кластера и его платформенные компоненты.
Развёртывание сервисов видеоархива — следующая итерация.

---

## Архитектурные решения

| Решение                | Выбор                                                                    |
|------------------------|--------------------------------------------------------------------------|
| Окружения              | **Один кластер**, dev/stage/prod через namespaces + RBAC + ResourceQuota |
| Топология control-plane| **HA: 3 control-plane** + N worker (stacked etcd)                        |
| Дистрибутив            | **Kubespray** (Ansible + kubeadm), vanilla k8s                           |
| ОС нод                 | **Ubuntu 24.04 LTS**                                                     |
| CNI                    | **Calico** (с NetworkPolicy)                                             |
| LoadBalancer           | **MetalLB** L2-режим                                                     |
| Ingress                | **ingress-nginx**                                                         |
| TLS                    | **cert-manager** (внутренний CA + Let's Encrypt)                         |
| Storage                | **Внешний** (S3/NFS/SAN), CSI-драйверы в кластере (nfs-csi)             |
| Container registry     | **Внешний** (Harbor/Nexus/GitLab)                                        |
| Observability          | **kube-prometheus-stack** + **Loki** + **promtail**                      |
| GitOps                 | **Argo CD** (App-of-Apps, ApplicationSet)                                |
| Secrets                | **HashiCorp Vault** + **External Secrets Operator**                      |
| Backup                 | **Velero** (S3 backend)                                                  |

---

## Структура репозитория

```
k8s-platform/
├── ansible/
│   ├── inventory/prod/{hosts.yaml, group_vars/}
│   ├── playbooks/
│   │   ├── 00-host-prep.yaml
│   │   ├── 10-kubespray.yaml
│   │   ├── 20-post-bootstrap.yaml
│   │   └── 99-reset.yaml
│   ├── roles/host-prep/
│   └── kubespray/                 # git submodule
├── platform/
│   ├── bootstrap/{metallb,ingress-nginx,cert-manager,argocd}/
│   └── apps/
│       ├── _root.yaml             # App-of-Apps
│       ├── observability/
│       ├── secrets/
│       ├── backup/
│       ├── storage/
│       └── policies/
├── docs/runbooks/
└── Makefile
```

**Принцип:** Ansible только для host-level и kubeadm. Всё остальное — через Argo CD + git.

---

## Фазы реализации

### Фаза 0. Требования к инфраструктуре (до старта)

- 3× control-plane VM: 4 vCPU / 8 GB / 80 GB SSD
- N× worker VM: 8 vCPU / 16 GB / 100 GB (N уточним после profiling сервисов)
- L2-сеть, пул IP ≥10 под MetalLB, DNS `*.k8s.va.atmodev.net` → VIP
- SSH-ключ с локальной машины оператора → все ноды (sudo NOPASSWD)
- NTP/chrony на всех нодах (критично для etcd)

### Фаза 1. Bootstrap кластера (Kubespray)

Ansible playbooks: host-prep → Kubespray cluster.yml → post-bootstrap.
Критерий: `kubectl get nodes` 3 master + N worker в Ready, etcd 3/3.

### Фаза 2. Базовые сетевые компоненты (pre-Argo CD)

MetalLB + ingress-nginx + cert-manager через Helm (до Argo CD).
Критерий: тестовый Ingress с TLS отвечает 200 OK через MetalLB VIP.

### Фаза 3. Argo CD и GitOps

Helm-установка Argo CD, настройка App-of-Apps root-application.
С этой точки — все изменения платформы только через PR в git.

### Фаза 4. Платформенные сервисы (через Argo CD)

Параллельный деплой через Argo CD Applications:
- nfs-csi-driver
- kube-prometheus-stack + Loki + promtail
- Vault (HA, 3 реплики, raft) + External Secrets Operator
- Velero (S3 backend, ежедневные backups)
- PodSecurity + NetworkPolicy defaults

Критерий: все Applications Healthy/Synced, Velero backup/restore работает.

### Фаза 5. Подготовка к сервисам (last bootstrap step)

- Namespaces: va-dev, va-stage, va-prod
- RBAC: роли developer / sre / ci
- ResourceQuota + LimitRange на dev/stage
- ImagePullSecrets через ESO из Vault
- Helm-чарт-скелет для микросервиса + ApplicationSet
- Runbooks: add-node, drain-node, certs-rotate, vault-unseal, restore-from-velero

Критерий готовности всего bootstrap'а: hello-world сервис деплоится через Argo CD,
доступен по HTTPS, метрики в Grafana, секреты из Vault.

---

## Verification checklist

- [ ] `kubectl get nodes -o wide` — все Ready, версия одинаковая
- [ ] `kubectl get pods -A` — нет CrashLoopBackOff/Pending
- [ ] `kubectl get applications -n argocd` — все Synced/Healthy
- [ ] MetalLB: LoadBalancer сервис получает IP из пула
- [ ] cert-manager: тестовый Certificate в Ready=True
- [ ] Vault+ESO: ExternalSecret синкает в k8s Secret
- [ ] Velero: backup create + restore работает
- [ ] Observability: kill pod → алерт в Alertmanager, лог в Loki
- [ ] DR-репетиция: потеря 1 master → кластер работает, recovery по runbook

---

## Что вне скоупа этой итерации

- Деплой микросервисов видеоархива (следующая итерация)
- HPA/VPA/PodDisruptionBudget для media-нагрузки
- CI: build + push + автообновление тегов
- SLO/SLA для сервисов
- (Возможно позже) выделение prod в отдельный кластер
