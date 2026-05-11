## Argo CD Apps (GitOps)

Этот каталог используется `platform/bootstrap/argocd/root-app.yaml` как **App-of-Apps**.

Здесь лежат манифесты `Application` Argo CD для компонентов, которые **после bootstrap** живут в GitOps (например **local-path**, **External Secrets Operator**, **ClusterSecretStore**).

**Longhorn и Vault** в этот каталог **не входят** — они ставятся скриптом `platform/bootstrap/bootstrap.sh` (см. `docs/deploy.md`, `docs/longhorn.md`, `docs/vault.md`).
