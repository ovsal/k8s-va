## Metrics Server

### Зачем нужен

[Metrics Server](https://github.com/kubernetes-sigs/metrics-server) агрегирует использование CPU и памяти с kubelet и регистрирует API **`metrics.k8s.io`**. Без него не работают:

- **`kubectl top nodes` / `kubectl top pods`**
- **HorizontalPodAutoscaler** по ресурсным метрикам (`cpu`, `memory`)

### Как деплоится

- **GitOps:** Argo CD, приложение **`system-metrics-server`** (манифест `platform/argocd-apps/system/metrics-server/application.yaml`).
- **Helm-чарт:** официальный репозиторий `https://kubernetes-sigs.github.io/metrics-server/`, chart **`metrics-server`**, версия чарта зафиксирована в `application.yaml` (поле `targetRevision`).
- **Namespace:** **`kube-system`** (релиз Helm `metrics-server`).
- **Values (как код):** `platform/argocd-apps/system/metrics-server/values.yaml`

В values включён аргумент **`--kubelet-insecure-tls`**, что соответствует типичной установке Kubespray с самоподписанными сертификатами kubelet. Если в будущем перейдёте на строгую проверку TLS у kubelet, этот флаг нужно убрать и настроить доверенные CA.

### Как проверить

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl -n kube-system get deploy,po -l app.kubernetes.io/name=metrics-server
kubectl top nodes
```

### Обновление версии чарта

1. Проверить [CHANGELOG чарта](https://github.com/kubernetes-sigs/metrics-server/blob/master/charts/metrics-server/CHANGELOG.md) и совместимость с версией Kubernetes кластера.
2. Обновить `targetRevision` в `platform/argocd-apps/system/metrics-server/application.yaml`, при необходимости — `values.yaml`.
3. Дождаться синка Argo CD или выполнить синхронизацию вручную.

### Связь с Kubespray

В `cluster/inventory/prod/group_vars/k8s_cluster/addons.yml` для кластера отключён встроенный metrics-server Kubespray (`metrics_server_enabled: false`), чтобы единственным источником установки был **этот** Argo CD Application.
