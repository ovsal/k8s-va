#!/usr/bin/env bash
# Создаёт Kubernetes Secret с логином/паролем администратора Grafana (без Vault и ESO).
# Вызовите до или сразу после первого синка observability, пока под Grafana не стартовал без секрета.
#
# Переменные:
#   GRAFANA_ADMIN_USER     — логин (по умолчанию admin)
#   GRAFANA_ADMIN_PASSWORD — пароль; если не задан — генерируется и печатается один раз
#
# Использование: make grafana-admin-secret  (или bash этот файл)
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config-k8s-va}"

NS="observability"
NAME="grafana-admin-credentials"
USER="${GRAFANA_ADMIN_USER:-admin}"

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: нет доступа к кластеру (KUBECONFIG=${KUBECONFIG})"
  exit 1
fi

kubectl get ns "${NS}" &>/dev/null || kubectl create ns "${NS}"

if kubectl -n "${NS}" get secret "${NAME}" &>/dev/null; then
  echo "Secret ${NS}/${NAME} уже есть — пропуск (удалите secret вручную, чтобы создать заново)."
  exit 0
fi

if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  PASS="${GRAFANA_ADMIN_PASSWORD}"
else
  PASS="$(openssl rand -base64 24)"
fi

kubectl -n "${NS}" create secret generic "${NAME}" \
  --from-literal=admin-user="${USER}" \
  --from-literal=admin-password="${PASS}"

echo "Создан Secret ${NS}/${NAME} (user=${USER})."
if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  echo "Сгенерированный пароль (сохраните вне Git): ${PASS}"
fi
