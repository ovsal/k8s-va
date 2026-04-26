# k8s-platform

Kubernetes bootstrap automation for the video archive platform.

## Prerequisites

- Bastion host with SSH access to all nodes
- Python 3.10+ on bastion
- Kubespray submodule initialized: `git submodule update --init --recursive`

## Quick start

1. Fill in real values in `ansible/inventory/prod/group_vars/all/vars.yml`
2. `make host-prep`    — prepare nodes
3. `make bootstrap`   — bootstrap k8s cluster
4. `make post-bootstrap` — fetch kubeconfig
5. `make bootstrap-platform` — install MetalLB, ingress, cert-manager, Argo CD

See `docs/runbooks/` for operational procedures.
