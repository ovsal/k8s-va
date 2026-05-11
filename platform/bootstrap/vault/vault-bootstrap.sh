#!/usr/bin/env bash
# Инициализация и операционная настройка Vault после Helm (bootstrap, не Argo CD).
# Идемпотентно: повторный запуск безопасен при уже настроенном Vault.
#
# Первый запуск на пустом storage: operator init → печать ключей → exit 11
# (сохраните credentials.env по шаблону platform/bootstrap/vault/credentials.env.example и выполните снова).
#
# Второй и далее: unseal всех реплик, KV v2, Kubernetes auth, политика и роль для ESO.
#
# Использование: make vault-bootstrap  (или bash platform/bootstrap/vault/vault-bootstrap.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CREDENTIALS_FILE="${REPO_ROOT}/credentials.env"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config-k8s-va}"

VAULT_POD="secrets-vault-0"

# vault CLI в поде без токена (status / init)
v0() {
  kubectl exec -n vault "${VAULT_POD}" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 vault "$@"
}

# vault CLI с root token
vr() {
  kubectl exec -n vault "${VAULT_POD}" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault "$@"
}

unseal_pod() {
  local pod=$1
  kubectl get pod "${pod}" -n vault &>/dev/null || return 0
  local sealed
  sealed=$(kubectl exec -n vault "${pod}" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 \
    vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))" \
    2>/dev/null || echo "True")
  if [[ "${sealed}" == "True" ]]; then
    echo "    Unsealing ${pod}..."
    for k in "${VAULT_UNSEAL_KEY_1}" "${VAULT_UNSEAL_KEY_2}" "${VAULT_UNSEAL_KEY_3}"; do
      kubectl exec -n vault "${pod}" -- \
        env VAULT_ADDR=http://127.0.0.1:8200 \
        vault operator unseal "${k}" >/dev/null
    done
  else
    echo "    ${pod} уже распечатан"
  fi
}

echo "==> [1/5] Ожидание подов Vault (до 5 мин)..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault,component=server \
  -n vault --timeout=300s

echo "==> [2/5] Проверка инициализации..."
INITIALIZED=$(v0 status -format=json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized', False))" \
  2>/dev/null || echo "False")

if [[ "${INITIALIZED}" != "True" ]]; then
  echo "    Vault не инициализирован. Выполняю operator init (5 ключей, порог 3)..."
  TMP=$(mktemp)
  v0 operator init -key-shares=5 -key-threshold=3 -format=json > "${TMP}"

  echo ""
  echo "╔════════════════════════════════════════════════════════════════════╗"
  echo "║  VAULT ИНИЦИАЛИЗИРОВАН — сохраните значения вне кластера            ║"
  echo "║  Скопируйте в credentials.env (см. credentials.env.example)       ║"
  echo "║  Затем снова: make vault-bootstrap                                  ║"
  echo "╚════════════════════════════════════════════════════════════════════╝"
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
  exit 11
fi

if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
  echo "ERROR: Нет файла ${CREDENTIALS_FILE}"
  echo "После первого init создайте его по образцу platform/bootstrap/vault/credentials.env.example"
  exit 1
fi
# shellcheck disable=SC1090
set -a
# shellcheck disable=SC1091
source "${CREDENTIALS_FILE}"
set +a

[[ -n "${VAULT_ROOT_TOKEN:-}" ]] || { echo "ERROR: в credentials.env нужен VAULT_ROOT_TOKEN"; exit 1; }
[[ -n "${VAULT_UNSEAL_KEY_1:-}" && -n "${VAULT_UNSEAL_KEY_2:-}" && -n "${VAULT_UNSEAL_KEY_3:-}" ]] || {
  echo "ERROR: в credentials.env нужны VAULT_UNSEAL_KEY_1..3 (порог 3 из 5)"
  exit 1
}

echo "==> [3/5] Unseal всех реплик server..."
while read -r pod; do
  [[ -n "${pod}" ]] || continue
  unseal_pod "${pod}"
done < <(kubectl get pods -n vault -l 'app.kubernetes.io/name=vault,component=server' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

echo "==> [4/5] KV v2 на secret/ и Kubernetes auth + роль ESO..."
vr secrets enable -path=secret kv-v2 2>/dev/null && echo "    KV включён" || echo "    KV уже есть (ok)"

vr auth enable kubernetes 2>/dev/null && echo "    auth/kubernetes включён" || echo "    auth/kubernetes уже есть (ok)"

kubectl exec -n vault "${VAULT_POD}" -- sh -lc \
  "export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='${VAULT_ROOT_TOKEN}'; \
   vault write auth/kubernetes/config \
     kubernetes_host='https://kubernetes.default.svc:443' \
     kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token"

kubectl exec -n vault -i "${VAULT_POD}" -- sh -lc \
  "export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='${VAULT_ROOT_TOKEN}'; vault policy write eso-policy -" <<'POL'
path "secret/data/platform/*" {
  capabilities = ["read"]
}
path "secret/metadata/platform/*" {
  capabilities = ["read", "list"]
}
POL

vr write auth/kubernetes/role/eso-role \
  bound_service_account_names="secrets-external-secrets" \
  bound_service_account_namespaces="external-secrets" \
  policies="eso-policy" \
  ttl=1h

echo "    Kubernetes auth и роль eso-role настроены (SA secrets-external-secrets)"

echo "==> [5/5] Готово."
echo "    Дальше: дождитесь синка Argo CD (ESO, ClusterSecretStore) или выполните make vault-bootstrap после установки ESO."
