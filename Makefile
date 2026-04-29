# INVENTORY is relative to CLUSTER_DIR — all targets cd into it before running ansible
INVENTORY       ?= inventory/prod/hosts.yaml
CLUSTER_DIR     := cluster
PLATFORM_DIR    := platform
KUBECONFIG_PATH := ~/.kube/config-k8s-va

.PHONY: help host-prep bootstrap post-bootstrap reset bootstrap-platform label-nodes vault-bootstrap apply-minio apply-secrets lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "%-25s %s\n",$$1,$$2}'

host-prep: ## Prepare hosts (apt, sysctl, containerd, chrony)
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/00-host-prep.yaml

bootstrap: ## Bootstrap k8s cluster via Kubespray (requires cluster/.venv with ansible-core 2.17.x)
	cd $(CLUSTER_DIR) && .venv/bin/ansible-playbook -b -i $(INVENTORY) playbooks/10-kubespray.yaml

post-bootstrap: ## Fetch kubeconfig, install CLI tools on bastion
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/20-post-bootstrap.yaml

prepare-storage: ## Format /dev/sdb, move containerd+longhorn onto it (frees root disk on workers)
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/40-prepare-storage-disk.yaml

label-nodes: ## Apply node labels and taints from host_vars (idempotent)
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/30-node-labels.yaml

reset: ## DESTRUCTIVE: reset the cluster
	@echo "WARNING: This will destroy the cluster. Press Ctrl+C to abort."
	@sleep 5
	cd $(CLUSTER_DIR) && ansible-playbook -i $(INVENTORY) playbooks/99-reset.yaml

bootstrap-platform: ## Install pre-ArgoCD components + Argo CD
	bash $(PLATFORM_DIR)/bootstrap/bootstrap.sh

vault-bootstrap: ## Init/unseal Vault + configure K8s auth + ESO role + seed all secrets from credentials.env
	@test -f credentials.env || { echo "ERROR: credentials.env not found"; exit 1; }
	bash $(PLATFORM_DIR)/bootstrap/vault/vault-bootstrap.sh

apply-minio: ## Deploy MinIO via helm template + create buckets (workaround: ArgoCD race condition)
	@export KUBECONFIG=$(KUBECONFIG_PATH); \
	helm template minio minio/minio --version 5.2.0 --namespace minio \
	  --values $(PLATFORM_DIR)/apps/storage/minio-values.yaml 2>/dev/null | \
	kubectl apply -n minio -f -; \
	echo "==> Applying MinIO bucket setup job..."; \
	kubectl apply -f $(PLATFORM_DIR)/apps/storage/minio-setup-job.yaml

apply-secrets: ## Apply all credentials from credentials.env to the cluster as K8s Secrets
	@test -f credentials.env || { echo "ERROR: credentials.env not found"; exit 1; }
	@set -a; . ./credentials.env; set +a; \
	export KUBECONFIG=$(KUBECONFIG_PATH); \
	kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl create secret generic minio-credentials -n minio \
	  --from-literal=rootUser="$$MINIO_ROOT_USER" \
	  --from-literal=rootPassword="$$MINIO_ROOT_PASSWORD" \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl create secret generic velero-credentials -n velero \
	  --from-literal=cloud="[default]\naws_access_key_id=$$VELERO_ACCESS_KEY\naws_secret_access_key=$$VELERO_SECRET_KEY" \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl create secret generic grafana-admin -n monitoring \
	  --from-literal=admin-user="admin" \
	  --from-literal=admin-password="$$GRAFANA_ADMIN_PASSWORD" \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	echo "Secrets applied."

lint: ## Lint Ansible playbooks and Helm charts
	@which ansible-lint >/dev/null 2>&1 || { echo "ansible-lint not installed, skipping"; exit 0; }
	cd $(CLUSTER_DIR) && ansible-lint playbooks/
	@which helm >/dev/null 2>&1 || { echo "helm not installed, skipping helm lint"; exit 0; }
	helm lint $(PLATFORM_DIR)/charts/microservice/ 2>/dev/null || true
