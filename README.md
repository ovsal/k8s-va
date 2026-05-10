# k8s-platform

Kubernetes bootstrap automation for the video archive platform.

## Structure

```
cluster/    — cluster provisioning (Ansible + Kubespray)
platform/   — platform apps managed by Argo CD (GitOps)
apps/       — break-glass/local-only manifests, not part of normal GitOps
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
3. `make bootstrap`        — bootstrap k8s cluster (~20–40 min, uses `cluster/.venv`)
4. `make post-bootstrap`   — fetch kubeconfig to `~/.kube/config-k8s-va`
5. `make prepare-storage` — mount worker storage disk for containerd/Longhorn
6. `make label-nodes` — apply node pool labels/taints
7. `make bootstrap-platform` — install MetalLB, ingress, cert-manager, Argo CD
8. `make vault-bootstrap` — initialize/unseal Vault and seed ESO-backed secrets
9. `make apply-minio` — first-install workaround for the MinIO chart; buckets are created by ArgoCD PostSync hook

Rollback marker before the current Codex improvement pass:

```bash
git checkout safety/pre-improvements-20260510
git stash show --stat stash@{0}
```

See `docs/deploy.md` for the full step-by-step guide.
See `docs/runbooks/` for operational procedures.
