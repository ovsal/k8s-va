# k8s-platform

Kubernetes bootstrap automation for the video archive platform.

## Structure

```
cluster/    — cluster provisioning (Ansible + Kubespray)
platform/   — platform apps managed by Argo CD (GitOps)
docs/       — runbooks and architecture docs
```

## Prerequisites

- SSH access from local machine to all nodes (key auth, `ansible` user, sudo NOPASSWD)
- Python 3.10+, helm, kubectl installed locally
- Ansible: `brew install ansible` for most steps; `make bootstrap` requires a venv with ansible-core 2.17.x (Kubespray v2.30 hard-blocks 2.18+): `cd cluster && python3 -m venv .venv && .venv/bin/pip install ansible==10.7.0 jmespath netaddr cryptography`
- Kubespray submodule: `git submodule update --init --recursive`

## Quick start

1. Fill in real values in `cluster/inventory/prod/group_vars/all/vars.yml`
2. `make host-prep`        — prepare nodes
3. `make bootstrap`        — bootstrap k8s cluster (~20–40 min)
4. `make post-bootstrap`   — fetch kubeconfig to `~/.kube/config-k8s-va`
5. `make bootstrap-platform` — install MetalLB, ingress, cert-manager, Argo CD

See `docs/deploy.md` for the full step-by-step guide.
See `docs/runbooks/` for operational procedures.
