## External Secrets Operator (ESO)

### Зачем нужен

ESO синхронизирует секреты из внешнего хранилища (в нашем случае **Vault**) в обычные Kubernetes `Secret`.

Это позволяет:
- хранить секреты централизованно в Vault
- выдавать в namespace’ы только нужные значения через GitOps
- не использовать root token в приложениях

### Как деплоится

ESO разворачивается **строго через Argo CD**:
- Argo CD Application: `platform/argocd-apps/secrets/external-secrets/application.yaml`
- Namespace: `external-secrets`
- Helm chart: `external-secrets/external-secrets` версии `2.4.1`

### Как настроена интеграция с Vault

Используем:
- Vault KV v2 на mount `secret/`
- Vault Kubernetes auth method на mount `auth/kubernetes`

ClusterSecretStore:
- `platform/argocd-apps/secrets/secret-stores/vault-clustersecretstore.yaml`
- обращается к Vault по адресу `http://secrets-vault-active.vault.svc:8200`
- аутентифицируется в Vault через Kubernetes auth (ServiceAccount `external-secrets`)
- использует роль Vault `eso-role`

### Как сервису получить секрет

Сервис описывает `ExternalSecret`, который создаёт/обновляет Kubernetes `Secret`.

Пример:
- `platform/argocd-apps/secrets/external-secrets-samples/argocd-example.yaml`

Паттерн путей в Vault:
- `secret/platform/<service>` — инфраструктурные секреты

### Troubleshooting

- Проверить ESO:
  - `kubectl -n external-secrets get pods`
  - `kubectl -n external-secrets logs deploy/external-secrets --tail=200`
- Проверить готовность store:
  - `kubectl get clustersecretstore vault -o yaml`
- Проверить ExternalSecret:
  - `kubectl -n <ns> describe externalsecret <name>`

