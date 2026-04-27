# k8s-platform

Kubernetes bootstrap automation for the video archive platform.

## Prerequisites

- SSH access from local machine to all nodes (key auth, sudo NOPASSWD)
- Python 3.10+, ansible, helm, kubectl installed locally
- Kubespray submodule initialized: `git submodule update --init --recursive`

## Quick start

1. Fill in real values in `ansible/inventory/prod/group_vars/all/vars.yml`
2. `make host-prep`    — prepare nodes
3. `make bootstrap`   — bootstrap k8s cluster
4. `make post-bootstrap` — fetch kubeconfig
5. `make bootstrap-platform` — install MetalLB, ingress, cert-manager, Argo CD

See `docs/runbooks/` for operational procedures.
