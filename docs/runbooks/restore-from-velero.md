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
