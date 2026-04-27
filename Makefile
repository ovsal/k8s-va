INVENTORY       ?= ansible/inventory/prod/hosts.yaml
ANSIBLE_DIR     := ansible
PLATFORM_DIR    := platform
KUBECONFIG_PATH := ~/.kube/config-k8s-va

.PHONY: help host-prep bootstrap post-bootstrap reset bootstrap-platform lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "%-25s %s\n",$$1,$$2}'

host-prep: ## Prepare hosts (apt, sysctl, containerd, chrony)
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) playbooks/00-host-prep.yaml

bootstrap: ## Bootstrap k8s cluster via Kubespray
	cd $(ANSIBLE_DIR) && ansible-playbook -b -i $(INVENTORY) playbooks/10-kubespray.yaml

post-bootstrap: ## Fetch kubeconfig, install CLI tools on bastion
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) playbooks/20-post-bootstrap.yaml

reset: ## DESTRUCTIVE: reset the cluster
	@echo "WARNING: This will destroy the cluster. Press Ctrl+C to abort."
	@sleep 5
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) playbooks/99-reset.yaml

bootstrap-platform: ## Install pre-ArgoCD components + Argo CD
	bash $(PLATFORM_DIR)/bootstrap/bootstrap.sh

lint: ## Lint Ansible playbooks and Helm charts
	@which ansible-lint >/dev/null 2>&1 || { echo "ansible-lint not installed, skipping"; exit 0; }
	cd $(ANSIBLE_DIR) && ansible-lint playbooks/
	@which helm >/dev/null 2>&1 || { echo "helm not installed, skipping helm lint"; exit 0; }
	helm lint $(PLATFORM_DIR)/charts/microservice/ 2>/dev/null || true
