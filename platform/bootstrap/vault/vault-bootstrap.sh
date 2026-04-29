#!/usr/bin/env bash
# Initializes Vault (if fresh), unseals all replicas, configures KV + Kubernetes auth + ESO,
# and seeds all platform secrets from credentials.env.
#
# Idempotent: safe to re-run after cluster rebuild.
# On first run after fresh init: prints new keys and exits — update credentials.env, then re-run.
#
# Usage: make vault-bootstrap
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CREDENTIALS_FILE="${REPO_ROOT}/credentials.env"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config-k8s-va}"

[[ -f "${CREDENTIALS_FILE}" ]] || { echo "ERROR: ${CREDENTIALS_FILE} not found"; exit 1; }
# shellcheck disable=SC1090
set -a; source "${CREDENTIALS_FILE}"; set +a

# ── helpers ────────────────────────────────────────────────────────────────────

# vault CLI inside vault-0, no token
v0() {
  kubectl exec -n vault vault-0 -- \
    env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault "$@"
}

# vault CLI inside vault-0, with root token
vr() {
  kubectl exec -n vault vault-0 -- \
    env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
        VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault "$@"
}

unseal_pod() {
  local pod=$1
  kubectl get pod "${pod}" -n vault &>/dev/null || return 0
  local sealed
  sealed=$(kubectl exec -n vault "${pod}" -- \
    env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
    vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','true'))" \
    2>/dev/null || echo "true")
  if [[ "${sealed}" == "true" ]]; then
    echo "    Unsealing ${pod}..."
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault operator unseal "${VAULT_UNSEAL_KEY_1}" >/dev/null
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault operator unseal "${VAULT_UNSEAL_KEY_2}" >/dev/null
    kubectl exec -n vault "${pod}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault operator unseal "${VAULT_UNSEAL_KEY_3}" >/dev/null
  else
    echo "    ${pod} already unsealed"
  fi
}

# ── 1. wait ────────────────────────────────────────────────────────────────────
echo "==> [1/6] Waiting for Vault pods (timeout 5m)..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault \
  -n vault --timeout=300s

# ── 2. init or unseal ─────────────────────────────────────────────────────────
echo "==> [2/6] Checking initialization status..."
INITIALIZED=$(v0 status -format=json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized','false'))" \
  2>/dev/null || echo "false")

if [[ "${INITIALIZED}" == "false" ]]; then
  echo "    Vault is NOT initialized. Initializing (5 keys, threshold 3)..."
  TMP=$(mktemp)
  v0 operator init -key-shares=5 -key-threshold=3 -format=json > "${TMP}"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  VAULT INITIALIZED — save these lines into credentials.env  ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  python3 - "${TMP}" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
print(f'VAULT_ROOT_TOKEN="{d["root_token"]}"')
for i, k in enumerate(d["unseal_keys_b64"], 1):
    print(f'VAULT_UNSEAL_KEY_{i}="{k}"')
PYEOF
  rm -f "${TMP}"
  echo ""
  echo "Update credentials.env with the values above, then re-run: make vault-bootstrap"
  exit 0
fi

echo "    Vault is initialized. Unsealing all replicas..."
for pod in vault-0 vault-1 vault-2; do
  unseal_pod "${pod}"
done

# ── 3. KV v2 ──────────────────────────────────────────────────────────────────
echo "==> [3/6] Enabling KV v2 secrets engine at path 'secret/'..."
vr secrets enable -path=secret kv-v2 2>/dev/null \
  && echo "    enabled" || echo "    already enabled (ok)"

# ── 4. Kubernetes auth + ESO role ─────────────────────────────────────────────
echo "==> [4/6] Configuring Kubernetes auth..."
vr auth enable kubernetes 2>/dev/null \
  && echo "    enabled" || echo "    already enabled (ok)"

# Read CA cert and SA token from inside the pod — these files exist on every K8s pod
K8S_CA=$(kubectl exec -n vault vault-0 -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)
K8S_SA_TOKEN=$(kubectl exec -n vault vault-0 -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)

vr write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert="${K8S_CA}" \
  token_reviewer_jwt="${K8S_SA_TOKEN}"

vr policy write eso-policy - <<'EOF'
path "secret/data/platform/*" {
  capabilities = ["read"]
}
path "secret/metadata/platform/*" {
  capabilities = ["read", "list"]
}
EOF

vr write auth/kubernetes/role/eso-role \
  bound_service_account_names="external-secrets" \
  bound_service_account_namespaces="external-secrets" \
  policies="eso-policy" \
  ttl=1h

echo "    Kubernetes auth + ESO role configured"

# ── 5. seed secrets ───────────────────────────────────────────────────────────
echo "==> [5/6] Seeding platform secrets from credentials.env..."

vr kv put secret/platform/grafana \
  admin_user="admin" \
  admin_password="${GRAFANA_ADMIN_PASSWORD}"

vr kv put secret/platform/minio \
  root_user="${MINIO_ROOT_USER}" \
  root_password="${MINIO_ROOT_PASSWORD}"

vr kv put secret/platform/velero \
  access_key="${VELERO_ACCESS_KEY}" \
  secret_key="${VELERO_SECRET_KEY}"

vr kv put secret/platform/argocd \
  admin_password="${ARGOCD_ADMIN_PASSWORD}"

echo "    All secrets written to Vault"

# ── 6. force ESO sync ─────────────────────────────────────────────────────────
echo "==> [6/6] Triggering immediate ESO sync..."
for pair in "monitoring/grafana-admin" "minio/minio-credentials" "velero/velero-credentials"; do
  ns="${pair%%/*}"; es="${pair##*/}"
  kubectl annotate externalsecret "${es}" -n "${ns}" \
    force-sync="$(date +%s)" --overwrite 2>/dev/null \
    && echo "    annotated ${ns}/${es}" || echo "    ${ns}/${es} not found yet (will sync on next ESO cycle)"
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Vault bootstrap complete!                                   ║"
echo "║  ESO will pull all secrets from Vault within ~1 minute.     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
