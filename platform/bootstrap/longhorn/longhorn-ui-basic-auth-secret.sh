#!/usr/bin/env bash
# Создаёт Secret для Basic Auth на Ingress Longhorn UI (nginx ingress).
# Пароль не хранится в Git — только в Kubernetes.
#
# Переменные:
#   LONGHORN_UI_USER     — логин (по умолчанию admin)
#   LONGHORN_UI_PASSWORD — пароль; если не задан — генерируется и печатается один раз
#
# Использование: make longhorn-ui-basic-auth  (или bash этот файл)
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config-k8s-va}"

NS="longhorn-system"
NAME="longhorn-ui-basic-auth"
USER="${LONGHORN_UI_USER:-admin}"

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: нет доступа к кластеру (KUBECONFIG=${KUBECONFIG})"
  exit 1
fi

kubectl get ns "${NS}" &>/dev/null || {
  echo "ERROR: namespace ${NS} не найден (Longhorn ещё не установлен?)"
  exit 1
}

if kubectl -n "${NS}" get secret "${NAME}" &>/dev/null; then
  echo "Secret ${NS}/${NAME} уже есть — пропуск (удалите secret вручную, чтобы создать заново)."
  exit 0
fi

if [[ -n "${LONGHORN_UI_PASSWORD:-}" ]]; then
  PASS="${LONGHORN_UI_PASSWORD}"
else
  PASS="$(openssl rand -base64 24)"
fi

# Формат nginx basic-auth: строка user:hash (apr1). Через stdin — безопаснее для спецсимволов в пароле.
HASH="$(printf '%s\n' "${PASS}" | openssl passwd -apr1 -stdin)"
AUTH_LINE="${USER}:${HASH}"

kubectl -n "${NS}" create secret generic "${NAME}" \
  --from-literal=auth="${AUTH_LINE}"

echo "Создан Secret ${NS}/${NAME} (user=${USER})."
if [[ -z "${LONGHORN_UI_PASSWORD:-}" ]]; then
  echo "Сгенерированный пароль (сохраните вне Git): ${PASS}"
fi
echo "Примените Ingress: kubectl apply -f platform/bootstrap/longhorn/ingress-ui.yaml"
