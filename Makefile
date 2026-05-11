# INVENTORY is relative to CLUSTER_DIR — all targets cd into it before running ansible
INVENTORY       ?= inventory/prod/hosts.yaml
CLUSTER_DIR     := cluster
PLATFORM_DIR    := platform
KUBECONFIG_PATH := ~/.kube/config-k8s-va

.PHONY: help host-prep bootstrap post-bootstrap reset bootstrap-platform vault-bootstrap grafana-admin-secret longhorn-ui-basic-auth

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "%-25s %s\n",$$1,$$2}'

host-prep: ## Prepare hosts (apt, sysctl, containerd, chrony)
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/00-host-prep.yaml

bootstrap: ## Bootstrap k8s cluster via Kubespray (requires cluster/.venv with ansible-core 2.17.x)
	cd $(CLUSTER_DIR) && .venv/bin/ansible-playbook -b -i $(INVENTORY) playbooks/10-kubespray.yaml

post-bootstrap: ## Fetch kubeconfig, install CLI tools on bastion
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/20-post-bootstrap.yaml


reset: ## DESTRUCTIVE: reset the cluster
	@echo "WARNING: This will destroy the cluster. Press Ctrl+C to abort."
	@sleep 5
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/99-reset.yaml

bootstrap-platform: ## Install pre-ArgoCD components + Longhorn + Vault + Argo CD
	bash $(PLATFORM_DIR)/bootstrap/bootstrap.sh

vault-bootstrap: ## Init/unseal Vault + Kubernetes auth + роль ESO (после bootstrap-platform)
	bash $(PLATFORM_DIR)/bootstrap/vault/vault-bootstrap.sh

grafana-admin-secret: ## Secret админа Grafana в observability (без Vault; см. docs/observability.md)
	bash $(PLATFORM_DIR)/bootstrap/observability/grafana-admin-secret.sh

longhorn-ui-basic-auth: ## Secret Basic Auth для Ingress Longhorn UI (см. docs/longhorn.md)
	bash $(PLATFORM_DIR)/bootstrap/longhorn/longhorn-ui-basic-auth-secret.sh
