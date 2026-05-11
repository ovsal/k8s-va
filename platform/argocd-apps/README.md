## Argo CD Apps (GitOps)

Этот каталог используется `platform/bootstrap/argocd/root-app.yaml` как **App-of-Apps**.

Здесь лежат манифесты `Application` Argo CD для компонентов, которые **после bootstrap** живут в GitOps (например **local-path**, **External Secrets Operator**, **ClusterSecretStore**).

**Longhorn и Vault** в этот каталог **не входят** — они ставятся скриптом `platform/bootstrap/bootstrap.sh` (см. `docs/deploy.md`, `docs/longhorn.md`, `docs/vault.md`).

Порядок для ESO: `external-secrets-namespace.yaml` (sync-wave **-2**) создаёт namespace до Job/SA CRD (wave **-1**); иначе `CreateNamespace` у root-app не помогает — он относится только к `spec.destination` приложения (`argocd`).
