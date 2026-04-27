#!/usr/bin/env bash
# Устанавливает MetalLB, ingress-nginx, cert-manager, Argo CD
# в правильном порядке. Идемпотентен.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-k8s-va}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

METALLB_VERSION="0.14.5"
INGRESS_NGINX_VERSION="4.10.1"
CERT_MANAGER_VERSION="1.15.1"
ARGOCD_VERSION="7.3.4"    # Helm chart version для Argo CD v2.11

echo "==> Adding Helm repositories"
helm repo add metallb https://metallb.github.io/metallb
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> [1/4] Installing MetalLB ${METALLB_VERSION}"
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

echo "==> [2/4] Installing ingress-nginx ${INGRESS_NGINX_VERSION}"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version "${INGRESS_NGINX_VERSION}" \
  --values "${SCRIPT_DIR}/ingress-nginx/values.yaml" \
  --wait --timeout 5m

INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "    ingress-nginx LoadBalancer IP: ${INGRESS_IP}"

echo "==> [3/4] Installing cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --values "${SCRIPT_DIR}/cert-manager/values.yaml" \
  --wait --timeout 5m

echo "==> Applying ClusterIssuers"
kubectl apply -f "${SCRIPT_DIR}/cert-manager/cluster-issuers.yaml"

echo "==> [4/4] Installing Argo CD ${ARGOCD_VERSION}"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "${ARGOCD_VERSION}" \
  --values "${SCRIPT_DIR}/argocd/values.yaml" \
  --wait --timeout 10m

echo "==> Applying Argo CD root App-of-Apps"
kubectl apply -f "${SCRIPT_DIR}/argocd/root-app.yaml"
echo "==> Root app applied. Argo CD will now manage the platform from git."

echo "==> Bootstrap complete!"
echo "    Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
