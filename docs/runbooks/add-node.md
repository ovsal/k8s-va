# Runbook: Добавление worker-ноды

## Когда использовать
Необходимо увеличить вычислительные мощности кластера.

## Шаги

### 1. Подготовить новую VM
VM должна соответствовать требованиям: Ubuntu 24.04, 8 vCPU, 16 GB RAM.
Убедиться что SSH ключ с локальной машины работает:
```bash
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
