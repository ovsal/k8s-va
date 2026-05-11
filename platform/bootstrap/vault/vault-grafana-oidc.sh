#!/usr/bin/env bash
# Настройка Vault как OIDC-провайдера для Grafana (Generic OAuth).
# Идемпотентно: если identity/oidc/provider/grafana уже есть — выход без изменений.
#
# Вызывается из vault-bootstrap.sh при наличии VAULT_ROOT_TOKEN и распечатанного Vault.
set -euo pipefail

: "${VAULT_ROOT_TOKEN:?нет VAULT_ROOT_TOKEN}"
VAULT_POD="${VAULT_POD:-secrets-vault-0}"
# Публичный URL Vault (Ingress), без завершающего слэша — для issuer и .well-known.
VAULT_PUBLIC_ISSUER="${VAULT_PUBLIC_ISSUER:-https://vault.k8s.va.atmodev.net}"
# Публичный URL Grafana (Ingress) — redirect_uri OAuth.
GRAFANA_PUBLIC_URL="${GRAFANA_PUBLIC_URL:-https://grafana.k8s.va.atmodev.net}"

vr() {
  # -i: иначе stdin (heredoc, policy write -) не доходит до vault в контейнере.
  kubectl exec -i -n vault "${VAULT_POD}" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault "$@"
}

# Кодирует шаблон JSON для identity/oidc/scope (Vault ожидает base64).
b64_scope_template() {
  python3 -c "import base64,sys; print(base64.b64encode(sys.argv[1].encode()).decode())" "$1"
}

# Политика userpass-пользователя Grafana: authorize + token + userinfo + .well-known (раньше только authorize → permission denied).
write_grafana_oidc_policy() {
  vr policy write grafana-oidc-auth - <<'POL'
path "identity/oidc/provider/grafana/authorize" {
  capabilities = ["read", "update"]
}
path "identity/oidc/provider/grafana/token" {
  capabilities = ["create", "read", "update"]
}
path "identity/oidc/provider/grafana/userinfo" {
  capabilities = ["read"]
}
path "identity/oidc/provider/grafana/.well-known/openid-configuration" {
  capabilities = ["read"]
}
path "identity/oidc/provider/grafana/.well-known/keys" {
  capabilities = ["read"]
}
POL
}

write_grafana_oidc_policy

if vr read identity/oidc/provider/grafana >/dev/null 2>&1; then
  echo "    OIDC-провайдер grafana уже есть (политика grafana-oidc-auth обновлена)."
  exit 0
fi

echo "    Создаю OIDC-провайдер Vault для Grafana (userpass → OIDC → Grafana)..."

vr auth enable userpass 2>/dev/null || true

GPASS="${GRAFANA_VAULT_USERPASS_PASSWORD:-}"
if [[ -z "${GPASS}" ]]; then
  GPASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | cut -c1-24)
  echo ""
  echo "    ВНИМАНИЕ: задайте GRAFANA_VAULT_USERPASS_PASSWORD в credentials.env для постоянного пароля."
  echo "    Одноразовый пароль userpass пользователя grafana-oidc-user: ${GPASS}"
  echo ""
fi

if vr read identity/entity/name/grafana-oidc-user >/dev/null 2>&1; then
  echo "    Сущность grafana-oidc-user уже есть"
else
  vr write identity/entity name=grafana-oidc-user \
    metadata=email='grafana-oidc-user@k8s.va.local' \
    disabled=false
fi

EID=$(vr read -format=json identity/entity/name/grafana-oidc-user | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")

vr write auth/userpass/users/grafana-oidc-user \
  password="${GPASS}" \
  token_policies=grafana-oidc-auth \
  token_ttl=24h

UP_ACC=$(vr auth list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('userpass/') or {}).get('accessor',''))")
[[ -n "${UP_ACC}" ]] || { echo "ERROR: не найден accessor для userpass"; exit 1; }

vr write identity/entity-alias name=grafana-oidc-user \
  canonical_id="${EID}" \
  mount_accessor="${UP_ACC}" 2>/dev/null || true

vr write identity/group name=grafana-admins member_entity_ids="${EID}"

GID=$(vr read -format=json identity/group/name/grafana-admins | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")

vr write identity/oidc/assignment/grafana-login group_ids="${GID}"

vr write identity/oidc/key/grafana-signing \
  allowed_client_ids="*" \
  algorithm=RS256 \
  rotation_period="24h" \
  verification_ttl="24h"

CALLBACK="${GRAFANA_PUBLIC_URL}/login/generic_oauth"
vr write identity/oidc/client/grafana \
  redirect_uris="${CALLBACK}" \
  assignments=grafana-login \
  key=grafana-signing \
  id_token_ttl="30m" \
  access_token_ttl="1h"

CID=$(vr read -field=client_id identity/oidc/client/grafana)
SECRET=$(vr read -field=client_secret identity/oidc/client/grafana)

# Имя scope «openid» в Vault зарезервировано — не создаём кастомный scope; в scopes_supported провайдера указываем только user и groups.
T_USER='{"email":{{identity.entity.metadata.email}},"email_verified":true,"name":{{identity.entity.name}},"preferred_username":{{identity.entity.name}}}'
T_GROUPS='{"groups":{{identity.entity.groups.names}}}'

vr write identity/oidc/scope/user description="Профиль для Grafana" template="$(b64_scope_template "${T_USER}")"
vr write identity/oidc/scope/groups description="Группы grafana-admins" template="$(b64_scope_template "${T_GROUPS}")"

vr write identity/oidc/provider/grafana \
  issuer="${VAULT_PUBLIC_ISSUER}" \
  allowed_client_ids="${CID}" \
  scopes_supported=user,groups

vr kv put secret/platform/grafana-oidc client_id="${CID}" client_secret="${SECRET}"

echo "    OIDC-провайдер grafana создан; KV secret/platform/grafana-oidc обновлён для ESO."
echo "    Логин в Vault UI (для редиректа Grafana): userpass / grafana-oidc-user"
