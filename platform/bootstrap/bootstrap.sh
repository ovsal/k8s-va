#!/usr/bin/env bash
# Устанавливает MetalLB, ingress-nginx, cert-manager, Longhorn, Vault (Helm),
# RBAC/Ingress для Vault/Longhorn, затем Argo CD и root App-of-Apps.
# Идемпотентен (helm upgrade --install).
#
# После первого запуска на пустом Vault: выполните make vault-bootstrap
# (скрипт выведет ключи; сохраните credentials.env и повторите).
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-k8s-va}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

METALLB_VERSION="0.14.5"
INGRESS_NGINX_VERSION="4.10.1"
CERT_MANAGER_VERSION="1.15.1"
LONGHORN_VERSION="1.11.2"
VAULT_CHART_VERSION="0.32.0"
ARGOCD_VERSION="7.3.4"

echo "==> Adding Helm repositories"
helm repo add metallb https://metallb.github.io/metallb
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add longhorn https://charts.longhorn.io
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

echo "==> [1/8] Installing MetalLB ${METALLB_VERSION}"
if helm status metallb -n metallb-system &>/dev/null; then
  echo "    MetalLB already installed, skipping upgrade"
else
  helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system --create-namespace \
    --version "${METALLB_VERSION}" \
    --values "${SCRIPT_DIR}/metallb/values.yaml" \
    --wait --timeout 5m
fi

echo "==> Applying MetalLB IP pools"
kubectl apply -f "${SCRIPT_DIR}/metallb/resources.yaml"
kubectl wait --for=condition=Ready ipaddresspool/main-pool \
  -n metallb-system --timeout=60s 2>/dev/null || true

echo "==> [2/8] Installing ingress-nginx ${INGRESS_NGINX_VERSION}"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version "${INGRESS_NGINX_VERSION}" \
  --values "${SCRIPT_DIR}/ingress-nginx/values.yaml" \
  --wait --timeout 5m

INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "    ingress-nginx LoadBalancer IP: ${INGRESS_IP}"

echo "==> [3/8] Installing cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --values "${SCRIPT_DIR}/cert-manager/values.yaml" \
  --wait --timeout 5m

echo "==> Applying ClusterIssuers"
kubectl apply -f "${SCRIPT_DIR}/cert-manager/cluster-issuers.yaml"

echo "==> [4/8] Installing Longhorn ${LONGHORN_VERSION} (не через Argo CD)"
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --version "${LONGHORN_VERSION}" \
  --values "${SCRIPT_DIR}/longhorn/values.yaml" \
  --wait --timeout 15m

echo "==> Applying StorageClass longhorn-ha + Ingress Longhorn UI"
kubectl apply -f "${SCRIPT_DIR}/longhorn/storageclass-longhorn-ha.yaml"
kubectl apply -f "${SCRIPT_DIR}/longhorn/ingress-ui.yaml"

echo "==> [5/8] Installing Vault (Helm release secrets-vault, chart ${VAULT_CHART_VERSION})"
helm upgrade --install secrets-vault hashicorp/vault \
  --namespace vault --create-namespace \
  --version "${VAULT_CHART_VERSION}" \
  --values "${SCRIPT_DIR}/vault/values.yaml" \
  --wait --timeout 15m

echo "==> RBAC для Kubernetes auth (TokenReview) + Ingress Vault UI"
kubectl apply -f "${SCRIPT_DIR}/vault/kubernetes-auth-delegator.yaml"
kubectl apply -f "${SCRIPT_DIR}/vault/ingress-ui.yaml"

echo "==> [6/8] Installing Argo CD ${ARGOCD_VERSION}"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "${ARGOCD_VERSION}" \
  --values "${SCRIPT_DIR}/argocd/values.yaml" \
  --wait --timeout 10m

echo "==> [7/8] Applying Argo CD root App-of-Apps"
kubectl apply -f "${SCRIPT_DIR}/argocd/root-app.yaml"
echo "    Argo CD синхронизирует приложения из Git (ESO, local-path, манифесты секретов и т.д.)."

echo "==> [8/8] Vault: init / unseal / Kubernetes auth / роль ESO"
set +e
bash "${SCRIPT_DIR}/vault/vault-bootstrap.sh"
VB_RC=$?
set -e
if [[ "${VB_RC}" -eq 11 ]]; then
  echo ""
  echo ">>> Vault только что инициализирован. Сохраните ключи в credentials.env"
  echo ">>> (шаблон: platform/bootstrap/vault/credentials.env.example), затем:"
  echo ">>>   make vault-bootstrap"
  echo ""
elif [[ "${VB_RC}" -ne 0 ]]; then
  echo "ERROR: vault-bootstrap.sh завершился с кодом ${VB_RC}"
  exit "${VB_RC}"
fi

echo ""
echo "==> Bootstrap завершён."
echo "    Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
