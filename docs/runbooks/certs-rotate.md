# Runbook: Ротация сертификатов кластера

## Контекст
kubeadm-сертификаты истекают через 1 год. cert-manager управляет сертификатами
приложений автоматически. Этот runbook — для сертификатов control-plane.

## Проверить срок действия сертификатов
```bash
# На каждой control-plane ноде:
ssh ansible@<CP_NODE> sudo kubeadm certs check-expiration
```

## Ротация (выполнить на КАЖДОЙ control-plane ноде по очереди)
```bash
ssh ansible@<CP_NODE>
sudo kubeadm certs renew all
sudo systemctl restart kubelet
```

## Обновить kubeconfig на локальной машине
```bash
# Перезапустить post-bootstrap плейбук — он заново скачает admin.conf и заменит адрес на VIP
cd cluster && ansible-playbook playbooks/20-post-bootstrap.yaml

# Или вручную (если плейбук недоступен):
ssh ansible@<CP1_NODE> sudo cat /etc/kubernetes/admin.conf > ~/.kube/config-k8s-va
# Не забыть заменить адрес на kube-vip VIP:
sed -i '' 's|server: https://.*:6443|server: https://<API_VIP>:6443|' ~/.kube/config-k8s-va
```

## Проверить
```bash
kubectl get nodes  # должно работать без ошибок TLS
ssh ansible@<CP_NODE> sudo kubeadm certs check-expiration
# Все сертификаты должны иметь новый срок действия
```
