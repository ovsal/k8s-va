# K8s Cluster Bootstrap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Автоматизированный bootstrap production-ready HA Kubernetes-кластера (3 control-plane + N workers) с полным платформенным стеком для видеоархива.

**Architecture:** Ansible + Kubespray создают vanilla k8s кластер на Ubuntu 24.04; MetalLB/ingress-nginx/cert-manager ставятся через Helm до Argo CD; дальше всё управляется GitOps через Argo CD App-of-Apps. Платформенные сервисы (Vault, Prometheus/Loki, Velero) — отдельные Argo CD Applications.

**Tech Stack:** Kubespray v2.26, Kubernetes v1.31, Calico, kube-vip, MetalLB v0.14, ingress-nginx v1.11, cert-manager v1.15, Argo CD v2.11, kube-prometheus-stack, Loki v6, Vault v1.17 (chart 0.28), External Secrets Operator v0.9, Velero v7, nfs-subdir-external-provisioner v4.

---

## Переменные среды (заполнить перед стартом)

Создать файл `ansible/inventory/prod/group_vars/all/vars.yml` с реальными значениями:

```
API_VIP          — виртуальный IP kube-apiserver (kube-vip), напр. 192.168.1.100
METALLB_POOL     — диапазон IP для LoadBalancer, напр. 192.168.1.200-192.168.1.220
NFS_SERVER       — IP NFS-сервера
NFS_PATH         — экспорт, напр. /exports/k8s
S3_ENDPOINT      — endpoint для Velero S3
S3_BUCKET        — бакет Velero
S3_ACCESS_KEY / S3_SECRET_KEY
REGISTRY_URL     — внешний Harbor/Nexus, напр. registry.company.com
EXTERNAL_DOMAIN  — домен ingress, напр. k8s.company.com
NODE_IFACE       — имя сетевого интерфейса нод (eth0 / ens3 / enp3s0)
INTERNAL_CA_CERT — PEM сертификат корпоративного CA
INTERNAL_CA_KEY  — приватный ключ корпоративного CA
```

---

## Файловая структура

```
k8s-platform/
├── ansible/
│   ├── ansible.cfg
│   ├── kubespray/                               # git submodule
│   ├── inventory/prod/
│   │   ├── hosts.yaml
│   │   └── group_vars/
│   │       ├── all/
│   │       │   ├── vars.yml
│   │       │   └── containerd.yml
│   │       └── k8s_cluster/
│   │           ├── k8s-cluster.yml
│   │           ├── k8s-net-calico.yml
│   │           └── addons.yml
│   ├── playbooks/
│   │   ├── 00-host-prep.yaml
│   │   ├── 10-kubespray.yaml
│   │   ├── 20-post-bootstrap.yaml
│   │   └── 99-reset.yaml
│   └── roles/
│       └── host-prep/
│           ├── defaults/main.yml
│           ├── tasks/
│           │   ├── main.yml
│           │   ├── system.yml
│           │   ├── containerd.yml
│           │   └── ca-trust.yml
│           └── templates/
│               └── chrony.conf.j2
├── platform/
│   ├── bootstrap/
│   │   ├── bootstrap.sh                         # единый скрипт pre-ArgoCD install
│   │   ├── metallb/
│   │   │   ├── values.yaml
│   │   │   └── resources.yaml                   # IPAddressPool + L2Advertisement
│   │   ├── ingress-nginx/
│   │   │   └── values.yaml
│   │   ├── cert-manager/
│   │   │   ├── values.yaml
│   │   │   └── cluster-issuers.yaml
│   │   └── argocd/
│   │       ├── values.yaml
│   │       └── root-app.yaml
│   └── apps/
│       ├── _root.yaml                           # App-of-Apps
│       ├── storage/
│       │   ├── application.yaml
│       │   └── values.yaml
│       ├── observability/
│       │   ├── application-prometheus.yaml
│       │   ├── prometheus-values.yaml
│       │   ├── application-loki.yaml
│       │   ├── loki-values.yaml
│       │   ├── application-promtail.yaml
│       │   └── promtail-values.yaml
│       ├── secrets/
│       │   ├── application-vault.yaml
│       │   ├── vault-values.yaml
│       │   ├── application-eso.yaml
│       │   ├── eso-values.yaml
│       │   └── cluster-secret-store.yaml
│       ├── backup/
│       │   ├── application.yaml
│       │   ├── values.yaml
│       │   └── schedule.yaml
│       ├── policies/
│       │   ├── application.yaml
│       │   └── manifests/
│       │       ├── namespace-labels.yaml
│       │       └── default-netpol.yaml
│       └── namespaces/
│           ├── application.yaml
│           └── manifests/
│               ├── namespaces.yaml
│               ├── resource-quotas.yaml
│               ├── limit-ranges.yaml
│               ├── rbac.yaml
│               └── registry-external-secret.yaml
├── platform/charts/microservice/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       └── serviceaccount.yaml
├── platform/apps/services/
│   └── applicationset.yaml
├── docs/runbooks/
│   ├── add-node.md
│   ├── drain-node.md
│   ├── certs-rotate.md
│   ├── vault-unseal.md
│   └── restore-from-velero.md
└── Makefile
```

---

## Task 1: Repository skeleton + Kubespray submodule

**Files:**
- Create: `Makefile`
- Create: `.gitignore`
- Create: `ansible/ansible.cfg`
- Create: `README.md` (минимальный)
- Init: `ansible/kubespray/` (git submodule)

- [ ] **Step 1: Инициализировать репозиторий**

```bash
cd /path/to/k8s-platform   # заменить на реальный путь
git init
git checkout -b main
```

- [ ] **Step 2: Создать .gitignore**

```
# ansible/kubespray/ управляется submodule — не игнорировать
*.retry
.vault_pass
*.pem
*.key
kubeconfig
.env
__pycache__/
*.pyc
.DS_Store
```

- [ ] **Step 3: Добавить Kubespray как submodule**

```bash
git submodule add https://github.com/kubernetes-sigs/kubespray.git ansible/kubespray
cd ansible/kubespray
git checkout v2.26.0    # зафиксировать тег
cd ../..
```

Ожидаемый результат: `cat .gitmodules` показывает `url = .../kubespray.git`.

- [ ] **Step 4: Создать ansible.cfg**

```ini
# ansible/ansible.cfg
[defaults]
inventory          = inventory/prod/hosts.yaml
roles_path         = roles:kubespray/roles
collections_paths  = kubespray/collections
host_key_checking  = False
stdout_callback    = yaml
callbacks_enabled  = timer, profile_tasks
forks              = 20
gathering          = smart
fact_caching       = jsonfile
fact_caching_connection = /tmp/ansible_facts_cache
fact_caching_timeout = 3600

[ssh_connection]
pipelining         = True
ssh_args           = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
```

- [ ] **Step 5: Создать Makefile skeleton**

```makefile
# Makefile
INVENTORY       ?= ansible/inventory/prod/hosts.yaml
ANSIBLE_DIR     := ansible
PLATFORM_DIR    := platform
KUBECONFIG_PATH := ~/.kube/config-k8s-va

.PHONY: help host-prep bootstrap post-bootstrap reset bootstrap-platform

help:
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "%-20s %s\n",$$1,$$2}'

host-prep: ## Подготовка хостов (apt, sysctl, containerd, chrony)
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/00-host-prep.yaml

bootstrap: ## Поднять кластер через Kubespray
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/10-kubespray.yaml

post-bootstrap: ## Получить kubeconfig, установить CLI утилиты
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/20-post-bootstrap.yaml

reset: ## DESTRUCTIVE: сбросить кластер
	@echo "WARNING: This will destroy the cluster. Press Ctrl+C to abort."
	@sleep 5
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/99-reset.yaml

bootstrap-platform: ## Установить pre-ArgoCD компоненты + Argo CD
	bash $(PLATFORM_DIR)/bootstrap/bootstrap.sh
```

- [ ] **Step 6: Установить зависимости Python для Ansible**

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r ansible/kubespray/requirements.txt
ansible --version   # ожидаем ansible [core 2.16+]
```

- [ ] **Step 7: Первый коммит**

```bash
git add .gitignore .gitmodules ansible/ansible.cfg ansible/kubespray Makefile
git commit -m "chore: init repo, add Kubespray submodule v2.26.0"
```

---

## Task 2: Ansible — роль host-prep

**Files:**
- Create: `ansible/roles/host-prep/defaults/main.yml`
- Create: `ansible/roles/host-prep/tasks/main.yml`
- Create: `ansible/roles/host-prep/tasks/system.yml`
- Create: `ansible/roles/host-prep/tasks/containerd.yml`
- Create: `ansible/roles/host-prep/tasks/ca-trust.yml`
- Create: `ansible/roles/host-prep/templates/chrony.conf.j2`

- [ ] **Step 1: Написать smoke-test (проверим что роль отработала)**

Создать `ansible/roles/host-prep/tests/test_host_prep.yaml` — запустим ПОСЛЕ применения роли:

```yaml
# ansible/roles/host-prep/tests/test_host_prep.yaml
---
- name: Verify host-prep role
  hosts: all
  gather_facts: true
  tasks:
    - name: swap is off
      command: swapon --show
      register: swap_out
      changed_when: false
      failed_when: swap_out.stdout != ""

    - name: ip_forward is enabled
      command: sysctl -n net.ipv4.ip_forward
      register: ipfwd
      changed_when: false
      failed_when: ipfwd.stdout | trim != "1"

    - name: containerd is running
      systemd:
        name: containerd
      register: containerd_svc
      failed_when: containerd_svc.status.ActiveState != "active"

    - name: chrony is running
      systemd:
        name: chronyd
      register: chrony_svc
      failed_when: chrony_svc.status.ActiveState != "active"
```

Запустить до применения роли — ожидаем FAIL:

```bash
cd ansible && ansible-playbook roles/host-prep/tests/test_host_prep.yaml
# Ожидаем: FAILED on "swap is off" или других checks
```

- [ ] **Step 2: Создать defaults**

```yaml
# ansible/roles/host-prep/defaults/main.yml
---
kernel_modules:
  - overlay
  - br_netfilter

sysctl_params:
  net.ipv4.ip_forward: 1
  net.bridge.bridge-nf-call-iptables: 1
  net.bridge.bridge-nf-call-ip6tables: 1
  fs.inotify.max_user_watches: 524288
  fs.inotify.max_user_instances: 512
  vm.overcommit_memory: 1
  kernel.panic: 10
  kernel.panic_on_oops: 1

containerd_version: "1.7.*"
containerd_config_dir: /etc/containerd

ntp_servers:
  - 0.ubuntu.pool.ntp.org
  - 1.ubuntu.pool.ntp.org

corporate_ca_cert: ""   # заполнить PEM строкой или передать как extra-var
```

- [ ] **Step 3: Создать tasks/system.yml**

```yaml
# ansible/roles/host-prep/tasks/system.yml
---
- name: Disable swap immediately
  command: swapoff -a
  when: ansible_swaptotal_mb > 0

- name: Remove swap from fstab
  replace:
    path: /etc/fstab
    regexp: '^([^#].*\s+swap\s+.*)$'
    replace: '# \1'

- name: Load kernel modules now
  modprobe:
    name: "{{ item }}"
    state: present
  loop: "{{ kernel_modules }}"

- name: Persist kernel modules
  copy:
    dest: /etc/modules-load.d/k8s.conf
    content: "{{ kernel_modules | join('\n') }}\n"
    mode: '0644'

- name: Set sysctl params
  sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-kubernetes.conf
    reload: true
  loop: "{{ sysctl_params | dict2items }}"

- name: Install base packages
  apt:
    name:
      - apt-transport-https
      - ca-certificates
      - curl
      - gnupg
      - lsb-release
      - python3-pip
      - rsync
      - nfs-common        # нужен для nfs-csi на воркерах
      - open-iscsi        # нужен некоторым CSI-провайдерам
    state: present
    update_cache: true

- name: Install chrony
  apt:
    name: chrony
    state: present

- name: Configure chrony
  template:
    src: chrony.conf.j2
    dest: /etc/chrony/chrony.conf
    mode: '0644'
  notify: restart chrony

- name: Enable and start chrony
  systemd:
    name: chronyd
    enabled: true
    state: started
```

- [ ] **Step 4: Создать tasks/containerd.yml**

```yaml
# ansible/roles/host-prep/tasks/containerd.yml
---
- name: Add Docker/containerd GPG key
  apt_key:
    url: https://download.docker.com/linux/ubuntu/gpg
    state: present

- name: Add containerd repo
  apt_repository:
    repo: "deb [arch=amd64] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
    state: present
    filename: docker

- name: Install containerd
  apt:
    name: "containerd.io={{ containerd_version }}"
    state: present
    update_cache: true

- name: Ensure containerd config dir exists
  file:
    path: "{{ containerd_config_dir }}"
    state: directory
    mode: '0755'

- name: Generate default containerd config
  shell: containerd config default > {{ containerd_config_dir }}/config.toml
  args:
    creates: "{{ containerd_config_dir }}/config.toml"

- name: Enable SystemdCgroup in containerd
  replace:
    path: "{{ containerd_config_dir }}/config.toml"
    regexp: 'SystemdCgroup = false'
    replace: 'SystemdCgroup = true'

- name: Set sandbox image to registry.k8s.io
  replace:
    path: "{{ containerd_config_dir }}/config.toml"
    regexp: 'sandbox_image = "registry.k8s.io/pause:.*"'
    replace: 'sandbox_image = "registry.k8s.io/pause:3.9"'

- name: Enable and restart containerd
  systemd:
    name: containerd
    enabled: true
    state: restarted
    daemon_reload: true
```

- [ ] **Step 5: Создать tasks/ca-trust.yml**

```yaml
# ansible/roles/host-prep/tasks/ca-trust.yml
---
- name: Add corporate CA to trusted store
  copy:
    content: "{{ corporate_ca_cert }}"
    dest: /usr/local/share/ca-certificates/corporate-ca.crt
    mode: '0644'
  when: corporate_ca_cert != ""
  notify: update ca-certificates

- name: Ensure CA store is up to date
  command: update-ca-certificates
  changed_when: false
```

- [ ] **Step 6: Создать tasks/main.yml**

```yaml
# ansible/roles/host-prep/tasks/main.yml
---
- import_tasks: system.yml
- import_tasks: containerd.yml
- import_tasks: ca-trust.yml
```

Добавить handlers в `ansible/roles/host-prep/handlers/main.yml`:

```yaml
---
- name: restart chrony
  systemd:
    name: chronyd
    state: restarted

- name: update ca-certificates
  command: update-ca-certificates
```

- [ ] **Step 7: Создать шаблон chrony**

```jinja2
{# ansible/roles/host-prep/templates/chrony.conf.j2 #}
{% for server in ntp_servers %}
pool {{ server }} iburst
{% endfor %}
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
```

- [ ] **Step 8: Применить роль и запустить тест**

```bash
cd ansible && ansible-playbook playbooks/00-host-prep.yaml
ansible-playbook roles/host-prep/tests/test_host_prep.yaml
# Ожидаем: все tasks OK / passed
```

- [ ] **Step 9: Commit**

```bash
git add ansible/roles/host-prep/
git commit -m "feat: ansible host-prep role (swap, sysctl, containerd, chrony, CA)"
```

---

## Task 3: Ansible — Kubespray inventory и group_vars

**Files:**
- Create: `ansible/inventory/prod/hosts.yaml`
- Create: `ansible/inventory/prod/group_vars/all/vars.yml`
- Create: `ansible/inventory/prod/group_vars/all/containerd.yml`
- Create: `ansible/inventory/prod/group_vars/k8s_cluster/k8s-cluster.yml`
- Create: `ansible/inventory/prod/group_vars/k8s_cluster/k8s-net-calico.yml`
- Create: `ansible/inventory/prod/group_vars/k8s_cluster/addons.yml`

- [ ] **Step 1: Проверить что Kubespray sample inventory доступен**

```bash
ls ansible/kubespray/inventory/sample/
# Ожидаем: group_vars/ hosts.ini
```

- [ ] **Step 2: Создать hosts.yaml**

Заменить `cp-1..3` и `worker-1..N` реальными IP из инфраструктуры:

```yaml
# ansible/inventory/prod/hosts.yaml
all:
  hosts:
    cp-1:
      ansible_host: 192.168.1.10      # ЗАМЕНИТЬ
      ansible_user: ubuntu
    cp-2:
      ansible_host: 192.168.1.11      # ЗАМЕНИТЬ
      ansible_user: ubuntu
    cp-3:
      ansible_host: 192.168.1.12      # ЗАМЕНИТЬ
      ansible_user: ubuntu
    worker-1:
      ansible_host: 192.168.1.20      # ЗАМЕНИТЬ
      ansible_user: ubuntu
    worker-2:
      ansible_host: 192.168.1.21      # ЗАМЕНИТЬ
      ansible_user: ubuntu
    worker-3:
      ansible_host: 192.168.1.22      # ЗАМЕНИТЬ
      ansible_user: ubuntu
  children:
    kube_control_plane:
      hosts:
        cp-1:
        cp-2:
        cp-3:
    kube_node:
      hosts:
        worker-1:
        worker-2:
        worker-3:
    etcd:
      hosts:
        cp-1:
        cp-2:
        cp-3:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
```

- [ ] **Step 3: Создать group_vars/all/vars.yml**

```yaml
# ansible/inventory/prod/group_vars/all/vars.yml
---
# kube-vip: VIP для kube-apiserver (внешний адрес для kubectl)
kube_vip_enabled: true
kube_vip_arp_enabled: true
kube_vip_interface: "{{ node_iface }}"   # enp3s0 / eth0 / ens3
loadbalancer_apiserver_address: "192.168.1.100"   # ЗАМЕНИТЬ на API_VIP

# Используемый runtime
container_manager: containerd

# NTP — уже настроен host-prep ролью
```

- [ ] **Step 4: Создать group_vars/all/containerd.yml**

```yaml
# ansible/inventory/prod/group_vars/all/containerd.yml
---
containerd_registries_mirrors:
  "registry.company.com":    # ЗАМЕНИТЬ на REGISTRY_URL
    - "https://registry.company.com"
# Если registry с self-signed cert:
containerd_insecure_registries: []
```

- [ ] **Step 5: Создать k8s-cluster.yml**

```yaml
# ansible/inventory/prod/group_vars/k8s_cluster/k8s-cluster.yml
---
kube_version: v1.31.4          # зафиксировать актуальную версию
kube_network_plugin: calico
kube_pods_subnet: 10.233.64.0/18
kube_service_addresses: 10.233.0.0/18
kube_proxy_mode: ipvs
dns_domain: cluster.local

# HA control-plane: kube-vip
kube_apiserver_ip: "{{ loadbalancer_apiserver_address }}"
supplementary_addresses_in_ssl_keys:
  - "{{ loadbalancer_apiserver_address }}"

# Container runtime
container_manager: containerd

# RBAC / audit
kubernetes_audit: true

# Включить encryption at rest для secrets
kube_encrypt_secret_data: true

# Отключить feature gates для стабильности
kube_feature_gates: []

# Версия pause образа (должна совпадать с containerd config)
pod_infra_container: registry.k8s.io/pause:3.9

# kubeadm — время ожидания
kubeadm_init_timeout: 300
```

- [ ] **Step 6: Создать k8s-net-calico.yml**

```yaml
# ansible/inventory/prod/group_vars/k8s_cluster/k8s-net-calico.yml
---
calico_version: "v3.28.0"
calico_cni_name: k8s-pod-network
calico_datastore: kdd       # kubernetes datastore (без etcd)
calico_network_backend: bird
calico_ip_auto_method: "interface={{ node_iface }}"
calico_ipv4pool_ipip: "Off"
calico_ipv4pool_vxlan: "Always"   # vxlan лучше работает без BGP
nat_outgoing: true
# NetworkPolicy включен по умолчанию при network_plugin: calico
```

- [ ] **Step 7: Создать addons.yml (оставить kubespray-addons выключенными — управляем через Argo CD)**

```yaml
# ansible/inventory/prod/group_vars/k8s_cluster/addons.yml
---
# Все аддоны ставим через Argo CD, не через Kubespray
helm_enabled: false
metrics_server_enabled: false   # поставим через kube-prometheus-stack
dashboard_enabled: false
ingress_nginx_enabled: false
cert_manager_enabled: false
metallb_enabled: false

# Kubespray всё равно нужен helm для некоторых внутренних операций
# поэтому helm binary установим в post-bootstrap playbook
```

- [ ] **Step 8: Проверить inventory**

```bash
cd ansible && ansible-inventory --list --yaml | head -50
# Ожидаем: вывод групп kube_control_plane, kube_node, etcd
ansible all -m ping
# Ожидаем: все ноды pong
```

- [ ] **Step 9: Commit**

```bash
git add ansible/inventory/
git commit -m "feat: Kubespray inventory, group_vars (HA 3CP, Calico, kube-vip)"
```

---

## Task 4: Ansible — Playbooks

**Files:**
- Create: `ansible/playbooks/00-host-prep.yaml`
- Create: `ansible/playbooks/10-kubespray.yaml`
- Create: `ansible/playbooks/20-post-bootstrap.yaml`
- Create: `ansible/playbooks/99-reset.yaml`

- [ ] **Step 1: Создать 00-host-prep.yaml**

```yaml
# ansible/playbooks/00-host-prep.yaml
---
- name: Prepare all hosts for Kubernetes
  hosts: all
  become: true
  gather_facts: true
  roles:
    - role: host-prep
      vars:
        node_iface: "{{ ansible_default_ipv4.interface }}"
  post_tasks:
    - name: Verify swap is off
      command: swapon --show
      register: swap_check
      changed_when: false
      failed_when: swap_check.stdout != ""

    - name: Verify ip_forward
      command: sysctl -n net.ipv4.ip_forward
      register: ipfwd
      changed_when: false
      failed_when: ipfwd.stdout | trim != "1"

    - name: Verify containerd running
      systemd:
        name: containerd
      register: ctr
      failed_when: ctr.status.ActiveState != "active"
```

- [ ] **Step 2: Запустить host-prep**

```bash
cd ansible && ansible-playbook playbooks/00-host-prep.yaml
# Ожидаем: PLAY RECAP — failed=0 unreachable=0
```

- [ ] **Step 3: Создать 10-kubespray.yaml**

```yaml
# ansible/playbooks/10-kubespray.yaml
---
# Запускает Kubespray cluster.yml с нашим inventory
# Kubespray предоставляет всё необходимое для bootstrap HA кластера.
- name: Bootstrap Kubernetes cluster via Kubespray
  ansible.builtin.import_playbook: ../kubespray/cluster.yml
```

- [ ] **Step 4: Запустить Kubespray (только после host-prep)**

```bash
cd ansible && ansible-playbook playbooks/10-kubespray.yaml
# Длительность: 20-40 минут в зависимости от скорости сети
# Ожидаем финальный RECAP: failed=0 unreachable=0
```

- [ ] **Step 5: Создать 20-post-bootstrap.yaml**

```yaml
# ansible/playbooks/20-post-bootstrap.yaml
---
- name: Post-bootstrap setup on bastion
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    kubeconfig_dest: "{{ lookup('env','HOME') }}/.kube/config-k8s-va"
    cp1_host: "{{ groups['kube_control_plane'][0] }}"
  tasks:
    - name: Ensure .kube dir exists
      file:
        path: "{{ lookup('env','HOME') }}/.kube"
        state: directory
        mode: '0700'

    - name: Fetch kubeconfig from first control-plane
      fetch:
        src: /etc/kubernetes/admin.conf
        dest: "{{ kubeconfig_dest }}"
        flat: true
      delegate_to: "{{ cp1_host }}"
      become: true

    - name: Replace internal API server address with VIP in kubeconfig
      replace:
        path: "{{ kubeconfig_dest }}"
        regexp: 'server: https://.*:6443'
        replace: "server: https://{{ loadbalancer_apiserver_address }}:6443"

    - name: Set KUBECONFIG in shell profile
      lineinfile:
        path: "{{ lookup('env','HOME') }}/.bashrc"
        line: "export KUBECONFIG={{ kubeconfig_dest }}"
        state: present

- name: Install CLI tools on bastion
  hosts: localhost
  connection: local
  gather_facts: true
  tasks:
    - name: Install kubectl via snap
      snap:
        name: kubectl
        classic: true
        state: present
      become: true

    - name: Install helm
      shell: |
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      args:
        creates: /usr/local/bin/helm

    - name: Install vault CLI
      shell: |
        curl -fsSL https://releases.hashicorp.com/vault/1.17.0/vault_1.17.0_linux_amd64.zip -o /tmp/vault.zip
        unzip -o /tmp/vault.zip -d /usr/local/bin/
        chmod +x /usr/local/bin/vault
      args:
        creates: /usr/local/bin/vault
      become: true

- name: Smoke test cluster
  hosts: localhost
  connection: local
  environment:
    KUBECONFIG: "{{ lookup('env','HOME') }}/.kube/config-k8s-va"
  tasks:
    - name: Get nodes
      command: kubectl get nodes -o wide
      register: nodes_out
      changed_when: false

    - name: Print nodes
      debug:
        var: nodes_out.stdout_lines

    - name: Verify all nodes Ready
      command: >
        kubectl get nodes -o jsonpath='{.items[*].status.conditions[-1].type}'
      register: node_status
      changed_when: false
      failed_when: "'NotReady' in node_status.stdout"

    - name: Check etcd cluster health
      command: >
        kubectl -n kube-system exec -it etcd-cp-1 -- etcdctl
        --endpoints=https://127.0.0.1:2379
        --cacert=/etc/kubernetes/pki/etcd/ca.crt
        --cert=/etc/kubernetes/pki/etcd/peer.crt
        --key=/etc/kubernetes/pki/etcd/peer.key
        endpoint health --cluster
      changed_when: false
      ignore_errors: true   # допускаем разные имена pod
```

- [ ] **Step 6: Создать 99-reset.yaml**

```yaml
# ansible/playbooks/99-reset.yaml
---
- name: DESTRUCTIVE — Reset Kubernetes cluster
  ansible.builtin.import_playbook: ../kubespray/reset.yml
  vars:
    reset_confirmation: "yes"
```

- [ ] **Step 7: Запустить post-bootstrap**

```bash
cd ansible && ansible-playbook playbooks/20-post-bootstrap.yaml
export KUBECONFIG=~/.kube/config-k8s-va
kubectl get nodes -o wide
# Ожидаем: 3 cp + 3 worker, STATUS=Ready
kubectl get pods -n kube-system | grep -v Running
# Ожидаем: только Running pods (coredns, calico, kube-proxy, etcd, apiserver…)
```

- [ ] **Step 8: Commit**

```bash
git add ansible/playbooks/
git commit -m "feat: ansible playbooks (host-prep, kubespray, post-bootstrap, reset)"
```

---

## Task 5: Pre-Argo CD bootstrap — MetalLB + ingress-nginx + cert-manager

**Files:**
- Create: `platform/bootstrap/bootstrap.sh`
- Create: `platform/bootstrap/metallb/values.yaml`
- Create: `platform/bootstrap/metallb/resources.yaml`
- Create: `platform/bootstrap/ingress-nginx/values.yaml`
- Create: `platform/bootstrap/cert-manager/values.yaml`
- Create: `platform/bootstrap/cert-manager/cluster-issuers.yaml`

- [ ] **Step 1: Написать smoke-test ДО bootstrap (ожидаем отсутствие компонентов)**

```bash
export KUBECONFIG=~/.kube/config-k8s-va
kubectl get ns metallb-system 2>&1 | grep -c "not found"
# Ожидаем: 1 (namespace не существует — failing state)
kubectl get ns ingress-nginx 2>&1 | grep -c "not found"
# Ожидаем: 1
kubectl get ns cert-manager 2>&1 | grep -c "not found"
# Ожидаем: 1
```

- [ ] **Step 2: Создать MetalLB values**

```yaml
# platform/bootstrap/metallb/values.yaml
controller:
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule
  nodeSelector:
    kubernetes.io/os: linux
speaker:
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule
  nodeSelector:
    kubernetes.io/os: linux
```

- [ ] **Step 3: Создать MetalLB IPAddressPool и L2Advertisement**

```yaml
# platform/bootstrap/metallb/resources.yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: main-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.200-192.168.1.220   # ЗАМЕНИТЬ на METALLB_POOL
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: main-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - main-pool
```

- [ ] **Step 4: Создать ingress-nginx values**

```yaml
# platform/bootstrap/ingress-nginx/values.yaml
controller:
  kind: DaemonSet
  service:
    type: LoadBalancer
    annotations:
      metallb.universe.tf/address-pool: main-pool
  ingressClassResource:
    name: nginx
    default: true
  config:
    use-real-ip: "true"
    compute-full-forwarded-for: "true"
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  podAnnotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "10254"
```

- [ ] **Step 5: Создать cert-manager values**

```yaml
# platform/bootstrap/cert-manager/values.yaml
installCRDs: true
global:
  leaderElection:
    namespace: cert-manager
prometheus:
  enabled: true
  servicemonitor:
    enabled: true
```

- [ ] **Step 6: Создать ClusterIssuers**

```yaml
# platform/bootstrap/cert-manager/cluster-issuers.yaml
---
# Internal CA issuer (корпоративный CA)
apiVersion: v1
kind: Secret
metadata:
  name: internal-ca-secret
  namespace: cert-manager
type: kubernetes.io/tls
stringData:
  tls.crt: |
    # ЗАМЕНИТЬ: вставить содержимое INTERNAL_CA_CERT
  tls.key: |
    # ЗАМЕНИТЬ: вставить содержимое INTERNAL_CA_KEY
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca
spec:
  ca:
    secretName: internal-ca-secret
---
# Let's Encrypt production issuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@company.com   # ЗАМЕНИТЬ
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
```

- [ ] **Step 7: Создать bootstrap.sh**

```bash
#!/usr/bin/env bash
# platform/bootstrap/bootstrap.sh
# Устанавливает MetalLB, ingress-nginx, cert-manager, Argo CD
# в правильном порядке. Идемпотентен.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-k8s-va}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

METALLB_VERSION="0.14.5"
INGRESS_NGINX_VERSION="4.10.1"
CERT_MANAGER_VERSION="1.15.1"
ARGOCD_VERSION="7.3.4"    # Helm chart version для Argo CD v2.11

echo "==> Adding Helm repositories"
helm repo add metallb https://metallb.github.io/metallb
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> [1/4] Installing MetalLB ${METALLB_VERSION}"
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system --create-namespace \
  --version "${METALLB_VERSION}" \
  --values "${SCRIPT_DIR}/metallb/values.yaml" \
  --wait --timeout 5m

echo "==> Applying MetalLB IP pools"
kubectl apply -f "${SCRIPT_DIR}/metallb/resources.yaml"
kubectl wait --for=condition=Ready ipaddresspool/main-pool \
  -n metallb-system --timeout=60s 2>/dev/null || true

echo "==> [2/4] Installing ingress-nginx ${INGRESS_NGINX_VERSION}"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version "${INGRESS_NGINX_VERSION}" \
  --values "${SCRIPT_DIR}/ingress-nginx/values.yaml" \
  --wait --timeout 5m

INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "    ingress-nginx LoadBalancer IP: ${INGRESS_IP}"

echo "==> [3/4] Installing cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --values "${SCRIPT_DIR}/cert-manager/values.yaml" \
  --wait --timeout 5m

echo "==> Applying ClusterIssuers"
kubectl apply -f "${SCRIPT_DIR}/cert-manager/cluster-issuers.yaml"

echo "==> [4/4] Installing Argo CD ${ARGOCD_VERSION}"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "${ARGOCD_VERSION}" \
  --values "${SCRIPT_DIR}/argocd/values.yaml" \
  --wait --timeout 10m

echo "==> Bootstrap complete!"
echo "    Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
```

```bash
chmod +x platform/bootstrap/bootstrap.sh
```

- [ ] **Step 8: Запустить bootstrap и проверить**

```bash
bash platform/bootstrap/bootstrap.sh

# Проверить MetalLB
kubectl -n metallb-system get pods
# Ожидаем: controller и speaker pods в Running

# Проверить ingress-nginx получил IP от MetalLB
kubectl -n ingress-nginx get svc ingress-nginx-controller
# Ожидаем: EXTERNAL-IP = IP из пула MetalLB (не <pending>)

# Проверить cert-manager
kubectl -n cert-manager get pods
kubectl get clusterissuer
# Ожидаем: internal-ca и letsencrypt-prod в READY=True

# Тест TLS: деплоим тестовый pod + ingress
kubectl create ns smoke-test
kubectl -n smoke-test run nginx --image=nginx --port=80
kubectl -n smoke-test expose pod nginx --port=80
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-test
  namespace: smoke-test
  annotations:
    cert-manager.io/cluster-issuer: internal-ca
spec:
  ingressClassName: nginx
  tls:
    - hosts: [test.k8s.company.com]   # ЗАМЕНИТЬ на реальный DNS
      secretName: nginx-test-tls
  rules:
    - host: test.k8s.company.com      # ЗАМЕНИТЬ
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx
                port:
                  number: 80
EOF

kubectl -n smoke-test wait --for=condition=Ready certificate/nginx-test-tls --timeout=120s
# Ожидаем: certificate.cert-manager.io/nginx-test-tls condition met

# Удалить тест
kubectl delete ns smoke-test
```

- [ ] **Step 9: Commit**

```bash
git add platform/bootstrap/
git commit -m "feat: pre-ArgoCD bootstrap (MetalLB, ingress-nginx, cert-manager, bootstrap.sh)"
```

---

## Task 6: Argo CD bootstrap + App-of-Apps

**Files:**
- Create: `platform/bootstrap/argocd/values.yaml`
- Create: `platform/bootstrap/argocd/root-app.yaml`
- Create: `platform/apps/_root.yaml`

- [ ] **Step 1: Создать Argo CD values**

```yaml
# platform/bootstrap/argocd/values.yaml
global:
  domain: argocd.k8s.company.com   # ЗАМЕНИТЬ

server:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: internal-ca
      nginx.ingress.kubernetes.io/ssl-passthrough: "false"
      nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    tls: true
  config:
    # URL репозитория платформы (публичный или с deploy key)
    repositories: |
      - url: https://github.com/company/k8s-platform.git
  rbacConfig:
    policy.default: role:readonly
    policy.csv: |
      p, role:sre, applications, *, */*, allow
      p, role:sre, clusters, get, *, allow
      p, role:sre, repositories, *, *, allow
      g, sre-team, role:sre

configs:
  params:
    server.insecure: false

repoServer:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi

applicationSet:
  enabled: true

notifications:
  enabled: true

dex:
  enabled: false   # включить позже для OIDC
```

- [ ] **Step 2: Применить root-app вручную (единственный раз)**

bootstrap.sh уже поставил Argo CD. Теперь применяем root-app:

```yaml
# platform/bootstrap/argocd/root-app.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/company/k8s-platform.git   # ЗАМЕНИТЬ
    targetRevision: main
    path: platform/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Добавить в конец `bootstrap.sh`:

```bash
echo "==> Applying Argo CD root App-of-Apps"
kubectl apply -f "${SCRIPT_DIR}/argocd/root-app.yaml"
echo "==> Root app applied. Argo CD will now manage the platform from git."
```

- [ ] **Step 3: Создать App-of-Apps _root.yaml**

```yaml
# platform/apps/_root.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform infrastructure applications
  sourceRepos:
    - https://github.com/company/k8s-platform.git   # ЗАМЕНИТЬ
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
---
# Далее: каждое дочернее Application будет в своей директории.
# Argo CD подхватит их через path: platform/apps
# и будет рекурсивно синкать.
```

- [ ] **Step 4: Проверить что Argo CD доступен и root-app создан**

```bash
# Открыть браузер: https://argocd.k8s.company.com
# Логин: admin / пароль из bootstrap.sh вывода

# Через CLI:
argocd login argocd.k8s.company.com --username admin --insecure
argocd app list
# Ожидаем: root-app в состоянии Synced или OutOfSync (пока нет дочерних apps)
```

- [ ] **Step 5: Commit**

```bash
git add platform/bootstrap/argocd/ platform/apps/_root.yaml
git commit -m "feat: Argo CD bootstrap + App-of-Apps root"
git push origin main
# После push — Argo CD подхватит изменения
```

---

## Task 7: Storage app — nfs-csi-driver

**Files:**
- Create: `platform/apps/storage/application.yaml`
- Create: `platform/apps/storage/values.yaml`
- Create: `platform/apps/storage/storage-classes.yaml`

- [ ] **Step 1: Проверить что StorageClass не существует**

```bash
kubectl get storageclass 2>&1
# Ожидаем: No resources found — failing state
```

- [ ] **Step 2: Создать Argo CD Application**

```yaml
# platform/apps/storage/application.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nfs-csi
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
    chart: csi-driver-nfs
    targetRevision: v4.7.0
    helm:
      valueFiles:
        - $values/platform/apps/storage/values.yaml
  sources:
    - repoURL: https://github.com/company/k8s-platform.git   # ЗАМЕНИТЬ
      targetRevision: main
      ref: values
    - repoURL: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
      chart: csi-driver-nfs
      targetRevision: v4.7.0
      helm:
        valueFiles:
          - $values/platform/apps/storage/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 3: Создать values для nfs-csi**

```yaml
# platform/apps/storage/values.yaml
controller:
  replicas: 2
  resources:
    limits:
      cpu: 100m
      memory: 300Mi

node:
  resources:
    limits:
      cpu: 100m
      memory: 300Mi
```

- [ ] **Step 4: Создать StorageClasses**

```yaml
# platform/apps/storage/storage-classes.yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-shared
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.0.0.50        # ЗАМЕНИТЬ на NFS_SERVER
  share: /exports/k8s      # ЗАМЕНИТЬ на NFS_PATH
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - hard
  - nfsvers=4.1
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-fast
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.0.0.50        # ЗАМЕНИТЬ на NFS_SERVER (быстрый шаринг)
  share: /exports/k8s-fast # ЗАМЕНИТЬ
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - hard
  - nfsvers=4.1
```

Добавить в `application.yaml` секцию для применения storage-classes:

Используем multi-source Application — добавить второй source для raw manifests:

```yaml
# Дополнить sources в application.yaml:
    - repoURL: https://github.com/company/k8s-platform.git
      targetRevision: main
      path: platform/apps/storage
      directory:
        include: 'storage-classes.yaml'
```

- [ ] **Step 5: Push и проверить через Argo CD**

```bash
git add platform/apps/storage/
git commit -m "feat: nfs-csi-driver + StorageClasses"
git push origin main

# Argo CD синкнет автоматически (через 3 мин) или вручную:
argocd app sync nfs-csi
argocd app wait nfs-csi --health

kubectl get storageclass
# Ожидаем: nfs-shared (default), nfs-fast

# Тест PVC:
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-shared
  resources:
    requests:
      storage: 1Gi
EOF
kubectl wait --for=condition=Bound pvc/test-pvc --timeout=60s
kubectl delete pvc test-pvc
# Ожидаем: Bound → успешно
```

- [ ] **Step 6: Commit**

```bash
# Уже сделан в Step 5
```

---

## Task 8: Observability — kube-prometheus-stack + Loki + promtail

**Files:**
- Create: `platform/apps/observability/application-prometheus.yaml`
- Create: `platform/apps/observability/prometheus-values.yaml`
- Create: `platform/apps/observability/application-loki.yaml`
- Create: `platform/apps/observability/loki-values.yaml`
- Create: `platform/apps/observability/application-promtail.yaml`
- Create: `platform/apps/observability/promtail-values.yaml`

- [ ] **Step 1: Создать Application для kube-prometheus-stack**

```yaml
# platform/apps/observability/application-prometheus.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  project: platform
  sources:
    - repoURL: https://github.com/company/k8s-platform.git
      targetRevision: main
      ref: values
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 61.7.1
      helm:
        valueFiles:
          - $values/platform/apps/observability/prometheus-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true   # требуется для больших CRD
```

- [ ] **Step 2: Создать prometheus-values.yaml**

```yaml
# platform/apps/observability/prometheus-values.yaml
grafana:
  enabled: true
  adminPassword: "changeme123!"   # ЗАМЕНИТЬ — вынести в Vault после Task 9
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: internal-ca
    hosts:
      - grafana.k8s.company.com   # ЗАМЕНИТЬ
    tls:
      - secretName: grafana-tls
        hosts: [grafana.k8s.company.com]
  persistence:
    enabled: true
    storageClassName: nfs-shared
    size: 10Gi
  defaultDashboardsEnabled: true
  sidecar:
    dashboards:
      enabled: true

prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: "50GB"
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: nfs-shared
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 50Gi
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: nfs-shared
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 5Gi

kubeEtcd:
  enabled: true
  endpoints:
    - 192.168.1.10    # ЗАМЕНИТЬ — IP control-plane нод
    - 192.168.1.11
    - 192.168.1.12

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
```

- [ ] **Step 3: Создать Loki application**

```yaml
# platform/apps/observability/application-loki.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
spec:
  project: platform
  sources:
    - repoURL: https://github.com/company/k8s-platform.git
      targetRevision: main
      ref: values
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 6.7.3
      helm:
        valueFiles:
          - $values/platform/apps/observability/loki-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Создать loki-values.yaml**

```yaml
# platform/apps/observability/loki-values.yaml
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem   # заменить на s3 если есть S3 объектное хранилище
  schemaConfig:
    configs:
      - from: 2024-01-01
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

deploymentMode: SingleBinary

singleBinary:
  replicas: 1
  persistence:
    storageClass: nfs-shared
    size: 50Gi

# Grafana datasource будет добавлен через sidecar в kube-prometheus-stack
gateway:
  enabled: false
```

- [ ] **Step 5: Создать promtail application + values**

```yaml
# platform/apps/observability/application-promtail.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: promtail
  namespace: argocd
spec:
  project: platform
  sources:
    - repoURL: https://github.com/company/k8s-platform.git
      targetRevision: main
      ref: values
    - repoURL: https://grafana.github.io/helm-charts
      chart: promtail
      targetRevision: 6.16.4
      helm:
        valueFiles:
          - $values/platform/apps/observability/promtail-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```yaml
# platform/apps/observability/promtail-values.yaml
config:
  clients:
    - url: http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push
      # Если gateway отключён:
      # url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push

tolerations:
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule

serviceMonitor:
  enabled: true
  namespaceSelector:
    matchNames:
      - monitoring
```

- [ ] **Step 6: Push и проверить**

```bash
git add platform/apps/observability/
git commit -m "feat: observability stack (prometheus, loki, promtail)"
git push origin main

argocd app sync kube-prometheus-stack loki promtail
argocd app wait kube-prometheus-stack --health --timeout 300
argocd app wait loki --health --timeout 120
argocd app wait promtail --health --timeout 60

kubectl -n monitoring get pods
# Ожидаем: все Running

# Smoke-test: убить тестовый pod, проверить алерт и лог
kubectl -n monitoring run alert-test --image=alpine --restart=Never \
  -- sh -c "echo 'test log from alert-test'; sleep 5"
# Подождать 5-10 минут
# Открыть Grafana → Explore → Loki: {namespace="monitoring"} | = "test log"
# Ожидаем: видим лог от alert-test pod
```

- [ ] **Step 7: Commit** *(уже сделан в Step 6)*

---

## Task 9: Secrets — Vault HA + ESO

**Files:**
- Create: `platform/apps/secrets/application-vault.yaml`
- Create: `platform/apps/secrets/vault-values.yaml`
- Create: `platform/apps/secrets/application-eso.yaml`
- Create: `platform/apps/secrets/eso-values.yaml`
- Create: `platform/apps/secrets/cluster-secret-store.yaml`

- [ ] **Step 1: Создать Vault Application**

```yaml
# platform/apps/secrets/application-vault.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd
spec:
  project: platform
  sources:
    - repoURL: https://github.com/company/k8s-platform.git
      targetRevision: main
      ref: values
    - repoURL: https://helm.releases.hashicorp.com
      chart: vault
      targetRevision: 0.28.0
      helm:
        valueFiles:
          - $values/platform/apps/secrets/vault-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: vault
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Создать vault-values.yaml (HA + raft)**

```yaml
# platform/apps/secrets/vault-values.yaml
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true
        listener "tcp" {
          tls_disable = 1
          address = "[::]:8200"
          cluster_address = "[::]:8201"
        }
        storage "raft" {
          path = "/vault/data"
          retry_join {
            leader_api_addr = "http://vault-0.vault-internal:8200"
          }
          retry_join {
            leader_api_addr = "http://vault-1.vault-internal:8200"
          }
          retry_join {
            leader_api_addr = "http://vault-2.vault-internal:8200"
          }
        }
        service_registration "kubernetes" {}

  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: vault
              component: server
          topologyKey: kubernetes.io/hostname

  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: nfs-fast

  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: internal-ca
    hosts:
      - host: vault.k8s.company.com   # ЗАМЕНИТЬ
        paths: [/]
    tls:
      - secretName: vault-tls
        hosts: [vault.k8s.company.com]

  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

ui:
  enabled: true

injector:
  enabled: false   # используем ESO, не sidecar-инжектор
```

- [ ] **Step 3: Инициализировать Vault после деплоя**

После первого деплоя Vault нужно инициализировать (один раз):

```bash
# Подождать пока все 3 ноды vault будут Running
kubectl -n vault get pods -w
# Ожидаем: vault-0, vault-1, vault-2 — Running но sealed

# Инициализация (только на vault-0)
kubectl -n vault exec vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > vault-init-keys.json

# ВАЖНО: vault-init-keys.json содержит unseal keys и root token.
# Сохранить в БЕЗОПАСНОМ месте (offline, password manager, HSM).
# НИКОГДА не коммитить в git!

# Unseal все 3 ноды (нужны 3 из 5 ключей)
UNSEAL_KEY_1=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[0]')
UNSEAL_KEY_2=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[1]')
UNSEAL_KEY_3=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[2]')
ROOT_TOKEN=$(cat vault-init-keys.json | jq -r '.root_token')

for pod in vault-0 vault-1 vault-2; do
  kubectl -n vault exec $pod -- vault operator unseal $UNSEAL_KEY_1
  kubectl -n vault exec $pod -- vault operator unseal $UNSEAL_KEY_2
  kubectl -n vault exec $pod -- vault operator unseal $UNSEAL_KEY_3
done

# Настроить Kubernetes auth (нужен для ESO)
export VAULT_ADDR=https://vault.k8s.company.com
export VAULT_TOKEN=$ROOT_TOKEN

vault auth enable kubernetes

vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@<(kubectl get cm kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}')

# Создать политику и роль для ESO
vault policy write external-secrets - <<EOF
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["list","read"] }
EOF

vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=24h

# Создать тестовый секрет
vault kv put secret/platform/test value="bootstrap-ok"

# Удалить init-keys файл с диска (уже сохранён в безопасном месте)
shred -u vault-init-keys.json
```

- [ ] **Step 4: Создать ESO Application**

```yaml
# platform/apps/secrets/application-eso.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets
  namespace: argocd
spec:
  project: platform
  sources:
    - repoURL: https://github.com/company/k8s-platform.git
      targetRevision: main
      ref: values
    - repoURL: https://charts.external-secrets.io
      chart: external-secrets
      targetRevision: 0.10.0
      helm:
        valueFiles:
          - $values/platform/apps/secrets/eso-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```yaml
# platform/apps/secrets/eso-values.yaml
installCRDs: true
resources:
  requests:
    cpu: 100m
    memory: 128Mi
serviceMonitor:
  enabled: true
```

- [ ] **Step 5: Создать ClusterSecretStore**

```yaml
# platform/apps/secrets/cluster-secret-store.yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

Добавить в `application-eso.yaml` под resources также:

```yaml
# Добавить в sources application-eso.yaml:
    - repoURL: https://github.com/company/k8s-platform.git
      targetRevision: main
      path: platform/apps/secrets
      directory:
        include: 'cluster-secret-store.yaml'
```

- [ ] **Step 6: Push и проверить**

```bash
git add platform/apps/secrets/
git commit -m "feat: Vault HA + ESO + ClusterSecretStore"
git push origin main

argocd app sync vault external-secrets
argocd app wait vault --health --timeout 300
argocd app wait external-secrets --health --timeout 120

# Тест ESO → Vault
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: test-secret
  namespace: default
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: test-k8s-secret
    creationPolicy: Owner
  data:
    - secretKey: value
      remoteRef:
        key: platform/test
        property: value
EOF

kubectl wait --for=condition=Ready externalsecret/test-secret --timeout=60s
kubectl get secret test-k8s-secret -o jsonpath='{.data.value}' | base64 -d
# Ожидаем: bootstrap-ok

kubectl delete externalsecret test-secret
kubectl delete secret test-k8s-secret
```

---

## Task 10: Backup — Velero

**Files:**
- Create: `platform/apps/backup/application.yaml`
- Create: `platform/apps/backup/values.yaml`
- Create: `platform/apps/backup/schedule.yaml`

- [ ] **Step 1: Создать S3-секрет для Velero в Vault**

```bash
vault kv put secret/platform/velero \
  access_key_id="ЗАМЕНИТЬ_S3_ACCESS_KEY" \
  secret_access_key="ЗАМЕНИТЬ_S3_SECRET_KEY"
```

- [ ] **Step 2: Создать Velero Application**

```yaml
# platform/apps/backup/application.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
spec:
  project: platform
  sources:
    - repoURL: https://github.com/company/k8s-platform.git
      targetRevision: main
      ref: values
    - repoURL: https://vmware-tanzu.github.io/helm-charts
      chart: velero
      targetRevision: 7.1.4
      helm:
        valueFiles:
          - $values/platform/apps/backup/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Создать Velero values**

```yaml
# platform/apps/backup/values.yaml
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: k8s-velero-backup   # ЗАМЕНИТЬ на S3_BUCKET
      config:
        region: us-east-1          # ЗАМЕНИТЬ или оставить для minio
        s3Url: https://s3.company.com   # ЗАМЕНИТЬ на S3_ENDPOINT
        s3ForcePathStyle: "true"

  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: us-east-1

credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=PLACEHOLDER     # ЗАМЕНИТЬ через ESO ниже
      aws_secret_access_key=PLACEHOLDER

initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.10.0
    volumeMounts:
      - mountPath: /target
        name: plugins

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

**Примечание:** S3-учётные данные передать через ExternalSecret вместо plaintext в values. Создать ESO-ресурс который создаёт Secret `velero-credentials` в namespace `velero` из Vault.

- [ ] **Step 4: Создать BackupSchedule**

```yaml
# platform/apps/backup/schedule.yaml
---
# Ежедневный backup всего кластера (все namespaces)
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-full
  namespace: velero
spec:
  schedule: "0 2 * * *"    # 02:00 каждый день
  template:
    storageLocation: default
    ttl: 720h               # хранить 30 дней
    includedNamespaces:
      - '*'
    excludedNamespaces:
      - kube-system
      - kube-public
    includeClusterResources: true
    snapshotVolumes: false   # для NFS/S3 snapshotting не нужен
---
# Еженедельный backup с PVC
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: weekly-with-volumes
  namespace: velero
spec:
  schedule: "0 3 * * 0"    # 03:00 каждое воскресенье
  template:
    storageLocation: default
    ttl: 2160h              # 90 дней
    includedNamespaces:
      - '*'
    excludedNamespaces:
      - kube-system
    includeClusterResources: true
    snapshotVolumes: false
```

- [ ] **Step 5: Push и проверить**

```bash
git add platform/apps/backup/
git commit -m "feat: Velero backup (S3, daily+weekly schedules)"
git push origin main

argocd app sync velero
argocd app wait velero --health --timeout 180

kubectl -n velero get backupstoragelocation
# Ожидаем: STATUS=Available

# Тест backup/restore
velero backup create smoke-test --include-namespaces=default --wait
velero backup describe smoke-test
# Ожидаем: STATUS: Completed

velero restore create --from-backup smoke-test \
  --namespace-mappings default:restore-test --wait
kubectl get ns restore-test
kubectl delete ns restore-test
velero backup delete smoke-test --confirm
```

---

## Task 11: Policies — PodSecurity + NetworkPolicy

**Files:**
- Create: `platform/apps/policies/application.yaml`
- Create: `platform/apps/policies/manifests/namespace-labels.yaml`
- Create: `platform/apps/policies/manifests/default-netpol.yaml`

- [ ] **Step 1: Создать Application**

```yaml
# platform/apps/policies/application.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: policies
  namespace: argocd
spec:
  project: platform
  source:
    repoURL: https://github.com/company/k8s-platform.git
    targetRevision: main
    path: platform/apps/policies/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Создать namespace-labels.yaml (PodSecurity)**

```yaml
# platform/apps/policies/manifests/namespace-labels.yaml
# Применяет PodSecurity admission labels к namespaces сервисов.
# "restricted" = запрет privileged pods, hostNetwork, hostPath и т.д.
---
apiVersion: v1
kind: Namespace
metadata:
  name: va-prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.31
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: va-stage
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: va-dev
  labels:
    pod-security.kubernetes.io/enforce: baseline
```

- [ ] **Step 3: Создать default-netpol.yaml**

```yaml
# platform/apps/policies/manifests/default-netpol.yaml
# Default-deny + allow для необходимых системных namespace
---
# va-prod: только явно разрешённый трафик
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: va-prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: va-prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-nginx
  namespace: va-prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
---
# То же для va-stage
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: va-stage
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: va-stage
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-nginx
  namespace: va-stage
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
```

- [ ] **Step 4: Push и проверить**

```bash
git add platform/apps/policies/
git commit -m "feat: PodSecurity + default-deny NetworkPolicies"
git push origin main

argocd app sync policies
argocd app wait policies --health

kubectl get ns va-prod -o jsonpath='{.metadata.labels}' | jq
# Ожидаем: pod-security labels присутствуют

kubectl -n va-prod get networkpolicy
# Ожидаем: default-deny-all, allow-dns, allow-ingress-from-nginx
```

---

## Task 12: Namespaces, RBAC, ResourceQuota + ImagePullSecrets

**Files:**
- Create: `platform/apps/namespaces/application.yaml`
- Create: `platform/apps/namespaces/manifests/namespaces.yaml`
- Create: `platform/apps/namespaces/manifests/resource-quotas.yaml`
- Create: `platform/apps/namespaces/manifests/limit-ranges.yaml`
- Create: `platform/apps/namespaces/manifests/rbac.yaml`
- Create: `platform/apps/namespaces/manifests/registry-external-secret.yaml`

- [ ] **Step 1: Создать Vault KV для registry credentials**

```bash
vault kv put secret/platform/registry \
  url="registry.company.com" \
  username="k8s-pull" \
  password="ЗАМЕНИТЬ"
```

- [ ] **Step 2: Создать namespaces.yaml**

```yaml
# platform/apps/namespaces/manifests/namespaces.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: va-dev
---
apiVersion: v1
kind: Namespace
metadata:
  name: va-stage
---
apiVersion: v1
kind: Namespace
metadata:
  name: va-prod
```

- [ ] **Step 3: Создать resource-quotas.yaml**

```yaml
# platform/apps/namespaces/manifests/resource-quotas.yaml
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: va-dev
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    persistentvolumeclaims: "20"
    services.loadbalancers: "0"   # dev не должен создавать LB
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: va-stage
spec:
  hard:
    requests.cpu: "16"
    requests.memory: 32Gi
    limits.cpu: "32"
    limits.memory: 64Gi
    persistentvolumeclaims: "20"
    services.loadbalancers: "0"
```

- [ ] **Step 4: Создать limit-ranges.yaml**

```yaml
# platform/apps/namespaces/manifests/limit-ranges.yaml
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: va-dev
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 256Mi
      defaultRequest:
        cpu: 50m
        memory: 64Mi
      max:
        cpu: "2"
        memory: 2Gi
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: va-stage
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "4"
        memory: 4Gi
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: va-prod
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "8"
        memory: 8Gi
```

- [ ] **Step 5: Создать rbac.yaml**

```yaml
# platform/apps/namespaces/manifests/rbac.yaml
---
# ClusterRole: developer (ro prod, rw dev/stage)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: developer
rules:
  - apiGroups: ["", "apps", "batch", "extensions"]
    resources: ["pods", "pods/log", "deployments", "services", "ingresses",
                "configmaps", "events", "replicasets", "jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-rw
  namespace: va-dev
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-rw
  namespace: va-stage
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["*"]
    verbs: ["*"]
---
# ClusterRole: SRE (full access)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sre
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
---
# ClusterRole: CI (deploy to specific namespace via Argo CD)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ci-deploy
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "update", "patch"]
```

- [ ] **Step 6: Создать registry-external-secret.yaml (ImagePullSecrets через ESO)**

```yaml
# platform/apps/namespaces/manifests/registry-external-secret.yaml
# Создаёт docker-registry secret в каждом namespace сервисов
# с учётными данными из Vault.
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: registry-pull-secret
  namespace: va-dev
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: registry-pull-secret
    type: kubernetes.io/dockerconfigjson
    creationPolicy: Owner
    template:
      data:
        .dockerconfigjson: |
          {
            "auths": {
              "{{ .url }}": {
                "username": "{{ .username }}",
                "password": "{{ .password }}",
                "auth": "{{ printf "%s:%s" .username .password | b64enc }}"
              }
            }
          }
  data:
    - secretKey: url
      remoteRef:
        key: platform/registry
        property: url
    - secretKey: username
      remoteRef:
        key: platform/registry
        property: username
    - secretKey: password
      remoteRef:
        key: platform/registry
        property: password
---
# То же для va-stage
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: registry-pull-secret
  namespace: va-stage
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: registry-pull-secret
    type: kubernetes.io/dockerconfigjson
    creationPolicy: Owner
    template:
      data:
        .dockerconfigjson: |
          {
            "auths": {
              "{{ .url }}": {
                "username": "{{ .username }}",
                "password": "{{ .password }}",
                "auth": "{{ printf "%s:%s" .username .password | b64enc }}"
              }
            }
          }
  data:
    - secretKey: url
      remoteRef:
        key: platform/registry
        property: url
    - secretKey: username
      remoteRef:
        key: platform/registry
        property: username
    - secretKey: password
      remoteRef:
        key: platform/registry
        property: password
---
# То же для va-prod (идентичная структура)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: registry-pull-secret
  namespace: va-prod
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: registry-pull-secret
    type: kubernetes.io/dockerconfigjson
    creationPolicy: Owner
    template:
      data:
        .dockerconfigjson: |
          {
            "auths": {
              "{{ .url }}": {
                "username": "{{ .username }}",
                "password": "{{ .password }}",
                "auth": "{{ printf "%s:%s" .username .password | b64enc }}"
              }
            }
          }
  data:
    - secretKey: url
      remoteRef:
        key: platform/registry
        property: url
    - secretKey: username
      remoteRef:
        key: platform/registry
        property: username
    - secretKey: password
      remoteRef:
        key: platform/registry
        property: password
```

- [ ] **Step 7: Создать Application**

```yaml
# platform/apps/namespaces/application.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: namespaces
  namespace: argocd
spec:
  project: platform
  source:
    repoURL: https://github.com/company/k8s-platform.git
    targetRevision: main
    path: platform/apps/namespaces/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: false   # не удалять namespaces автоматически
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 8: Push и проверить**

```bash
git add platform/apps/namespaces/
git commit -m "feat: namespaces, RBAC, quotas, ImagePullSecrets via ESO"
git push origin main

argocd app sync namespaces
argocd app wait namespaces --health

kubectl get ns va-dev va-stage va-prod
kubectl -n va-dev get externalsecret
# Ожидаем: STATUS=SecretSynced

kubectl -n va-dev get secret registry-pull-secret \
  -o jsonpath='{.type}'
# Ожидаем: kubernetes.io/dockerconfigjson
```

---

## Task 13: Helm chart skeleton + ApplicationSet

**Files:**
- Create: `platform/charts/microservice/Chart.yaml`
- Create: `platform/charts/microservice/values.yaml`
- Create: `platform/charts/microservice/templates/_helpers.tpl`
- Create: `platform/charts/microservice/templates/deployment.yaml`
- Create: `platform/charts/microservice/templates/service.yaml`
- Create: `platform/charts/microservice/templates/ingress.yaml`
- Create: `platform/charts/microservice/templates/serviceaccount.yaml`
- Create: `platform/apps/services/applicationset.yaml`

- [ ] **Step 1: Создать Chart.yaml**

```yaml
# platform/charts/microservice/Chart.yaml
apiVersion: v2
name: microservice
description: Generic Helm chart for video archive microservices
type: application
version: 1.0.0
appVersion: "1.0.0"
```

- [ ] **Step 2: Создать values.yaml**

```yaml
# platform/charts/microservice/values.yaml
# Эти значения — defaults. Каждый сервис переопределяет нужные.

replicaCount: 2

image:
  repository: registry.company.com/va/service-name   # ЗАМЕНИТЬ
  tag: latest
  pullPolicy: IfNotPresent
  pullSecrets:
    - name: registry-pull-secret

service:
  type: ClusterIP
  port: 8080

ingress:
  enabled: false
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: internal-ca
  host: ""
  tlsSecret: ""

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

env: {}
  # KEY: value

envFromSecret: []
  # - secretName: my-secret
  #   key: MY_KEY

livenessProbe:
  httpGet:
    path: /healthz
    port: http
  initialDelaySeconds: 10
  periodSeconds: 30

readinessProbe:
  httpGet:
    path: /readyz
    port: http
  initialDelaySeconds: 5
  periodSeconds: 10

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"

serviceAccount:
  create: true
  name: ""
```

- [ ] **Step 3: Создать _helpers.tpl**

```
{{/* platform/charts/microservice/templates/_helpers.tpl */}}
{{- define "microservice.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "microservice.labels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "microservice.serviceAccountName" -}}
{{- if .Values.serviceAccount.name }}
{{- .Values.serviceAccount.name }}
{{- else }}
{{- include "microservice.name" . }}
{{- end }}
{{- end }}
```

- [ ] **Step 4: Создать deployment.yaml**

```yaml
{{/* platform/charts/microservice/templates/deployment.yaml */}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "microservice.name" . }}
  labels:
    {{- include "microservice.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "microservice.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "microservice.selectorLabels" . | nindent 8 }}
      annotations:
        {{- toYaml .Values.podAnnotations | nindent 8 }}
    spec:
      serviceAccountName: {{ include "microservice.serviceAccountName" . }}
      imagePullSecrets:
        {{- toYaml .Values.image.pullSecrets | nindent 8 }}
      containers:
        - name: {{ include "microservice.name" . }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.port }}
              protocol: TCP
          env:
            {{- range $key, $val := .Values.env }}
            - name: {{ $key }}
              value: {{ $val | quote }}
            {{- end }}
            {{- range .Values.envFromSecret }}
            - name: {{ .key }}
              valueFrom:
                secretKeyRef:
                  name: {{ .secretName }}
                  key: {{ .key }}
            {{- end }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

- [ ] **Step 5: Создать service.yaml и ingress.yaml**

```yaml
{{/* platform/charts/microservice/templates/service.yaml */}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "microservice.name" . }}
  labels:
    {{- include "microservice.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "microservice.selectorLabels" . | nindent 4 }}
```

```yaml
{{/* platform/charts/microservice/templates/ingress.yaml */}}
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "microservice.name" . }}
  labels:
    {{- include "microservice.labels" . | nindent 4 }}
  annotations:
    {{- toYaml .Values.ingress.annotations | nindent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  {{- if .Values.ingress.tlsSecret }}
  tls:
    - hosts: [{{ .Values.ingress.host }}]
      secretName: {{ .Values.ingress.tlsSecret }}
  {{- end }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "microservice.name" . }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

```yaml
{{/* platform/charts/microservice/templates/serviceaccount.yaml */}}
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "microservice.serviceAccountName" . }}
  labels:
    {{- include "microservice.labels" . | nindent 4 }}
{{- end }}
```

- [ ] **Step 6: Создать ApplicationSet для сервисов**

```yaml
# platform/apps/services/applicationset.yaml
# Автоматически создаёт Argo CD Application для каждого сервиса
# который есть в репозитории сервисов.
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: va-services
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/company/va-services.git   # репо с сервисами
        revision: main
        directories:
          - path: "services/*"
  template:
    metadata:
      name: '{{`{{path.basename}}`}}-prod'
      namespace: argocd
    spec:
      project: platform
      source:
        repoURL: https://github.com/company/va-services.git
        targetRevision: main
        path: '{{`{{path}}`}}'
        helm:
          valueFiles:
            - values.yaml
            - values-prod.yaml
      destination:
        server: https://kubernetes.default.svc
        namespace: va-prod
      syncPolicy:
        automated:
          prune: false          # prod: ручное удаление
          selfHeal: true
        syncOptions:
          - CreateNamespace=false
```

- [ ] **Step 7: Helm lint чарт**

```bash
helm lint platform/charts/microservice/
# Ожидаем: 1 chart(s) linted, 0 chart(s) failed

helm template test-svc platform/charts/microservice/ \
  --set image.repository=registry.company.com/va/hello \
  --set image.tag=latest \
  --set ingress.enabled=true \
  --set ingress.host=hello.k8s.company.com | kubectl apply --dry-run=client -f -
# Ожидаем: все ресурсы "configured (dry run)"
```

- [ ] **Step 8: Commit**

```bash
git add platform/charts/ platform/apps/services/
git commit -m "feat: microservice Helm chart skeleton + ApplicationSet"
git push origin main
```

---

## Task 14: Runbooks

**Files:**
- Create: `docs/runbooks/add-node.md`
- Create: `docs/runbooks/drain-node.md`
- Create: `docs/runbooks/certs-rotate.md`
- Create: `docs/runbooks/vault-unseal.md`
- Create: `docs/runbooks/restore-from-velero.md`

- [ ] **Step 1: Создать add-node.md**

```markdown
# Runbook: Добавление worker-ноды

## Когда использовать
Необходимо увеличить вычислительные мощности кластера.

## Шаги

### 1. Подготовить новую VM
VM должна соответствовать требованиям: Ubuntu 24.04, 8 vCPU, 16 GB RAM.
Убедиться что SSH ключ bastion работает:
```
ssh ubuntu@<NEW_NODE_IP>
```

### 2. Добавить ноду в inventory
В `ansible/inventory/prod/hosts.yaml`:
```yaml
worker-N:
  ansible_host: <NEW_NODE_IP>
  ansible_user: ubuntu
```
Добавить `worker-N` в группу `kube_node`.

### 3. Применить host-prep роль
```bash
cd ansible && ansible-playbook playbooks/00-host-prep.yaml \
  --limit worker-N
```

### 4. Добавить ноду через Kubespray scale
```bash
cd ansible && ansible-playbook kubespray/scale.yml \
  --limit worker-N
```

### 5. Проверить
```bash
kubectl get node worker-N
# Ожидаем: Ready
kubectl describe node worker-N | grep -E "Taints|Conditions"
```
```

- [ ] **Step 2: Создать drain-node.md**

```markdown
# Runbook: Вывод ноды из обслуживания (drain)

## Когда использовать
Плановое обслуживание ноды: обновление ОС, замена железа.

## Шаги

### 1. Cordon — запрет новых pod
```bash
kubectl cordon <NODE_NAME>
kubectl get node <NODE_NAME>  # SchedulingDisabled
```

### 2. Drain — безопасное выселение pod
```bash
kubectl drain <NODE_NAME> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60 \
  --timeout=300s
```
Если есть PodDisruptionBudget нарушения — решить вручную или увеличить timeout.

### 3. Выполнить обслуживание на ноде
SSH на ноду, провести работы.

### 4. Вернуть ноду в ротацию
```bash
kubectl uncordon <NODE_NAME>
kubectl get node <NODE_NAME>  # Ready
```

### 5. Проверить что workload вернулся
```bash
kubectl get pods -A -o wide | grep <NODE_NAME>
```
```

- [ ] **Step 3: Создать certs-rotate.md**

```markdown
# Runbook: Ротация сертификатов кластера

## Контекст
kubeadm-сертификаты истекают через 1 год. cert-manager управляет сертификатами
приложений автоматически. Этот runbook — для сертификатов control-plane.

## Проверить срок действия сертификатов
```bash
# На каждой control-plane ноде:
ssh ubuntu@<CP_NODE> sudo kubeadm certs check-expiration
```

## Ротация (выполнить на КАЖДОЙ control-plane ноде по очереди)
```bash
ssh ubuntu@<CP_NODE>
sudo kubeadm certs renew all
sudo systemctl restart kubelet
```

## Обновить kubeconfig на bastion
```bash
cd ansible && ansible-playbook playbooks/20-post-bootstrap.yaml \
  --tags kubeconfig
# Или вручную:
ssh ubuntu@<CP1_NODE> sudo cat /etc/kubernetes/admin.conf > ~/.kube/config-k8s-va
```

## Проверить
```bash
kubectl get nodes  # должно работать без ошибок TLS
kubeadm certs check-expiration  # все сертификаты обновлены
```
```

- [ ] **Step 4: Создать vault-unseal.md**

```markdown
# Runbook: Vault Unseal после рестарта

## Контекст
HashiCorp Vault запечатывается (sealed) при каждом рестарте pod/ноды.
Для unsealing нужны 3 из 5 ключей, созданных при инициализации.
Ключи хранятся OFFLINE в безопасном месте (password manager команды SRE).

## Проверить статус
```bash
kubectl -n vault get pods
# vault-X pods с READY=0/1 означает что они sealed

kubectl -n vault exec vault-0 -- vault status
# Sealed: true → нужен unseal
```

## Unseal каждый pod
```bash
# Получить unseal ключи из безопасного хранилища
UNSEAL_KEY_1=<ключ_1>
UNSEAL_KEY_2=<ключ_2>
UNSEAL_KEY_3=<ключ_3>

for pod in vault-0 vault-1 vault-2; do
  echo "Unsealing $pod..."
  kubectl -n vault exec $pod -- vault operator unseal $UNSEAL_KEY_1
  kubectl -n vault exec $pod -- vault operator unseal $UNSEAL_KEY_2
  kubectl -n vault exec $pod -- vault operator unseal $UNSEAL_KEY_3
done
```

## Проверить
```bash
kubectl -n vault get pods
# Все vault-X должны быть READY=1/1

kubectl -n vault exec vault-0 -- vault status
# Sealed: false

# ESO должен автоматически подключиться снова
kubectl -n external-secrets get pods
```

## Автоматизация (рекомендуется для prod)
Настроить Vault auto-unseal через AWS KMS / Azure Key Vault / GCP KMS.
Подробнее: https://developer.hashicorp.com/vault/docs/configuration/seal/awskms
```

- [ ] **Step 5: Создать restore-from-velero.md**

```markdown
# Runbook: Восстановление из Velero backup

## Контекст
Velero хранит backups в S3. Восстановление возможно как в тот же кластер,
так и в новый кластер (disaster recovery).

## Проверить доступные backup'ы
```bash
velero backup get
# Список backup'ов с датой и статусом
```

## Восстановление конкретного namespace
```bash
# Найти нужный backup:
velero backup describe <BACKUP_NAME>

# Восстановить namespace (если объекты уже существуют — будут пропущены):
velero restore create \
  --from-backup <BACKUP_NAME> \
  --include-namespaces va-prod \
  --wait

velero restore describe <RESTORE_NAME>
# STATUS: Completed
```

## Восстановление всего кластера (Disaster Recovery)
```bash
# 1. Поднять новый кластер через ansible:
make bootstrap

# 2. Установить Velero на новый кластер:
make bootstrap-platform

# 3. Восстановить все namespace'ы:
velero restore create dr-restore \
  --from-backup <LAST_GOOD_BACKUP> \
  --include-cluster-resources=true \
  --wait

# 4. Проверить что все ресурсы восстановлены:
kubectl get pods -A | grep -v Running
```

## Восстановление отдельного PVC
```bash
velero restore create \
  --from-backup <BACKUP_NAME> \
  --include-namespaces va-prod \
  --selector app=my-service \
  --wait
```
```

- [ ] **Step 6: Commit**

```bash
git add docs/runbooks/
git commit -m "docs: operational runbooks (add-node, drain, certs, vault-unseal, velero-restore)"
git push origin main
```

---

## Task 15: End-to-end smoke test (Hello World через Argo CD)

Финальная проверка всего bootstrap'а — деплоим hello-world сервис через Argo CD в va-prod.

- [ ] **Step 1: Создать hello-world сервис в репозитории сервисов**

```bash
mkdir -p /tmp/va-services/services/hello-world
cat > /tmp/va-services/services/hello-world/values.yaml <<EOF
image:
  repository: registry.company.com/va/hello-world   # или nginx для теста
  tag: latest

ingress:
  enabled: true
  host: hello.k8s.company.com
  tlsSecret: hello-tls
  annotations:
    cert-manager.io/cluster-issuer: internal-ca
EOF

cat > /tmp/va-services/services/hello-world/values-prod.yaml <<EOF
replicaCount: 2
EOF
```

- [ ] **Step 2: Применить ApplicationSet (если не применён)**

```bash
argocd app sync root-app
# ApplicationSet va-services должен создать Application hello-world-prod
argocd app list | grep hello-world
```

- [ ] **Step 3: Запустить полный verification checklist**

```bash
export KUBECONFIG=~/.kube/config-k8s-va

echo "=== 1. Nodes ==="
kubectl get nodes -o wide
# Ожидаем: все Ready

echo "=== 2. No bad pods ==="
kubectl get pods -A | grep -v -E "Running|Completed|Terminating" | grep -v NAME
# Ожидаем: пустой вывод

echo "=== 3. Argo CD apps ==="
argocd app list
# Ожидаем: все Synced/Healthy

echo "=== 4. MetalLB: ingress IP ==="
kubectl -n ingress-nginx get svc ingress-nginx-controller
# Ожидаем: EXTERNAL-IP = IP из MetalLB пула

echo "=== 5. cert-manager: ClusterIssuers ready ==="
kubectl get clusterissuer
# Ожидаем: internal-ca READY=True, letsencrypt-prod READY=True

echo "=== 6. Hello-world доступен по HTTPS ==="
curl -sk https://hello.k8s.company.com/ | head -5
# Ожидаем: nginx welcome page или ответ приложения

echo "=== 7. Vault: unsealed ==="
kubectl -n vault exec vault-0 -- vault status | grep Sealed
# Ожидаем: Sealed  false

echo "=== 8. ESO: ExternalSecrets synced ==="
kubectl get externalsecret -A | grep -v SecretSynced
# Ожидаем: пустой вывод (все Synced)

echo "=== 9. Velero: BSL available ==="
kubectl -n velero get backupstoragelocation
# Ожидаем: STATUS=Available

echo "=== 10. Grafana доступна ==="
curl -sk https://grafana.k8s.company.com/api/health | jq .database
# Ожидаем: "ok"

echo "=== 11. Loki получает логи ==="
# В Grafana → Explore → Loki: {namespace="va-prod"} — видим логи hello-world

echo "=== 12. Prometheus scraping ==="
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result | length'
# Ожидаем: >10 targets
kill %1
```

- [ ] **Step 4: DR-репетиция (один раз)**

```bash
# Вывести один master из строя
MASTER_NODE="cp-3"   # выбрать не первый (не тот с которого брали kubeconfig)
kubectl cordon $MASTER_NODE
kubectl drain $MASTER_NODE --ignore-daemonsets --delete-emptydir-data --force

# Убедиться что кластер продолжает работать
kubectl get nodes     # cp-3 SchedulingDisabled, остальные Ready
kubectl get pods -n va-prod  # hello-world продолжает работать
curl -sk https://hello.k8s.company.com/ | head -3   # отвечает

# Вернуть ноду
kubectl uncordon $MASTER_NODE

# Проверить что etcd вернулся в кворум 3/3
kubectl -n kube-system exec -it etcd-cp-1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  endpoint health --cluster
# Ожидаем: все 3 ноды healthy
```

- [ ] **Step 5: Финальный commit**

```bash
git add .
git status   # убедиться нет секретов
git commit -m "chore: final verification, bootstrap complete"
git push origin main
```

---

## Spec Coverage Check

| Требование из spec                                   | Task |
|------------------------------------------------------|------|
| HA 3 control-plane + stacked etcd                    | T3, T4 |
| Ubuntu 24.04                                         | T2, T3 |
| Kubespray                                            | T1, T4 |
| Calico CNI + NetworkPolicy                           | T3, T11 |
| MetalLB L2                                           | T5 |
| ingress-nginx                                        | T5 |
| cert-manager (internal CA + LE)                      | T5 |
| External storage (NFS CSI drivers)                   | T7 |
| kube-prometheus-stack + Loki + promtail              | T8 |
| Argo CD App-of-Apps                                  | T6 |
| Vault HA + ESO + ClusterSecretStore                  | T9 |
| Velero + S3 + schedules                              | T10 |
| PodSecurity + NetworkPolicy defaults                 | T11 |
| Namespaces va-dev/stage/prod                         | T12 |
| RBAC: developer/sre/ci                               | T12 |
| ResourceQuota + LimitRange                           | T12 |
| ImagePullSecrets через ESO                           | T12 |
| Helm chart skeleton + ApplicationSet                 | T13 |
| Runbooks (5 шт.)                                     | T14 |
| Hello-world E2E test через Argo CD                   | T15 |
| DR-репетиция (1 master down)                         | T15 |
