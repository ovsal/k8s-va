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
- Ansible: `brew install ansible` (system, for all steps except bootstrap)
- Kubespray venv: `cd cluster && python3 -m venv .venv && .venv/bin/pip install --quiet ansible==10.7.0 jmespath netaddr cryptography` — Kubespray v2.30 hard-blocks ansible-core 2.18+
- Kubespray submodule: `git submodule update --init --recursive`

## Quick start

1. Fill in real values in `cluster/inventory/prod/group_vars/all/vars.yml`
2. `make host-prep`        — prepare nodes
3. Bootstrap (venv required): `cd cluster && .venv/bin/ansible-playbook -b -i inventory/prod/hosts.yaml playbooks/10-kubespray.yaml`
4. `make post-bootstrap`   — fetch kubeconfig to `~/.kube/config-k8s-va`
5. `make bootstrap-platform` — install MetalLB, ingress, cert-manager, Argo CD

See `docs/deploy.md` for the full step-by-step guide.
See `docs/runbooks/` for operational procedures.
