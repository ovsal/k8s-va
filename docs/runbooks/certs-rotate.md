# Runbook: Ротация сертификатов кластера

## Контекст
kubeadm-сертификаты истекают через 1 год. cert-manager управляет сертификатами
приложений автоматически. Этот runbook — для сертификатов control-plane.

## Проверить срок действия сертификатов
```bash
# На каждой control-plane ноде:
ssh ubuntu@<CP_NODE> sudo kubeadm certs check-expiration
```

## Ротация (выполнить на КАЖДОЙ control-plane ноде по очереди)
```bash
ssh ubuntu@<CP_NODE>
sudo kubeadm certs renew all
sudo systemctl restart kubelet
```

## Обновить kubeconfig на локальной машине
```bash
cd ansible && ansible-playbook playbooks/20-post-bootstrap.yaml \
  --tags kubeconfig
# Или вручную:
ssh ubuntu@<CP1_NODE> sudo cat /etc/kubernetes/admin.conf > ~/.kube/config-k8s-va
```

## Проверить
```bash
kubectl get nodes  # должно работать без ошибок TLS
kubeadm certs check-expiration  # все сертификаты обновлены
```
