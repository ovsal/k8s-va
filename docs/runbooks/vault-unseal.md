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
