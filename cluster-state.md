# Актуальное состояние кластера

> Обновлено: 2026-05-10. Kubernetes 1.34.3 · Calico VXLAN · IPVS kube-proxy · Longhorn block storage.

## Архитектура

```mermaid
graph TB
    DNS["*.k8s.va.atmodev.net -> 176.113.118.185"]
    KVIP["kube-vip API VIP\n176.113.118.190:6443"]

    subgraph CP["Control plane x3"]
        CP1["cp-1 .177\netcd + apiserver"]
        CP2["cp-2 .178\netcd + apiserver"]
        CP3["cp-3 .179\netcd + apiserver"]
    end

    subgraph WORKERS["Workers x2"]
        W1["worker-1 .180\nnode-pool=storage"]
        W2["worker-2 .181\nnode-pool=storage"]
    end

    CP1 & CP2 & CP3 --> KVIP
    DNS --> NGINX

    subgraph BOOTSTRAP["Bootstrap components"]
        METALLB["MetalLB L2 pool\n176.113.118.185-189"]
        NGINX["ingress-nginx LoadBalancer\n176.113.118.185"]
        CERT["cert-manager\nletsencrypt-prod/staging"]
        ARGO["ArgoCD root app\nplatform/argocd-apps"]
    end

    subgraph STORAGE["Storage"]
        LH["Longhorn\nSC: longhorn, longhorn-retain"]
        MINIO["MinIO\nlonghorn-retain 500Gi"]
    end

    subgraph SECRETS["Secrets"]
        VAULT["Vault Raft x3\nplain HTTP inside cluster"]
        ESO["External Secrets Operator\nVault role: eso-role"]
    end

    subgraph OBS["Observability"]
        PROM["kube-prometheus-stack"]
        LOKI["Loki SingleBinary"]
        PROMTAIL["Promtail DaemonSet"]
    end

    subgraph BACKUP["Backups"]
        VELERO["Velero\nMinIO S3 backend\nnode-agent filesystem backup"]
    end

    LH --> VAULT
    LH --> LOKI
    LH --> PROM
    LH --> MINIO
    VAULT --> ESO
    ESO --> MINIO
    ESO --> VELERO
    ESO --> PROM
    MINIO --> VELERO
```

## GitOps ordering

Root app watches `platform/argocd-apps/` as a flat directory. Child Applications use sync-wave annotations:

| Wave | App |
|---:|---|
| -20 | `platform` AppProject |
| -15 | namespaces |
| -14 | NetworkPolicies |
| -12 | Longhorn |
| -10 | Vault |
| -9 | External Secrets Operator |
| -8 | MinIO |
| -6 | Registry pull secrets |
| 0 | kube-prometheus-stack |
| 5 | Loki |
| 6 | Promtail |
| 10 | Velero |
| 20 | Longhorn monitoring |

## Security posture

- Kubernetes Dashboard is not exposed through Ingress and does not create a long-lived cluster-admin token.
- Longhorn UI Ingress is disabled; use port-forward or add protected OIDC/VPN ingress.
- App namespaces `va-dev`, `va-stage`, `va-prod` have Pod Security labels, ResourceQuota, LimitRange, and default-deny NetworkPolicies.
- Secrets flow: `credentials.env` -> `make vault-bootstrap` -> Vault KV -> ESO -> Kubernetes Secrets.

## Known operational risks

- MinIO is currently inside the same cluster as Velero. For full cluster disaster recovery, replicate MinIO data off-cluster or move Velero to external S3.
- `make apply-minio` remains as a first-install workaround for the MinIO chart hook behavior; bucket creation itself is managed by the ArgoCD PostSync hook.
- Worker root disks are small. Keep `/var/lib/containerd` and `/var/lib/longhorn` on the secondary disk and watch root filesystem pressure.
