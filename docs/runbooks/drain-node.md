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
