# Generating Kubernetes Configuration Files (Modernized 2025)

## Why Update?
- Use variable-driven scripting to reduce duplication
- Embed certs to make distribution simpler
- Clarify separation: kubeconfigs generated once then copied
- Update cluster name to remain backward compatible (kubernetes-the-hard-way)

Assume you are in `~/pki` where cert directories exist (see previous step). Run on `master-1`.

Set common variables:
```bash
CLUSTER_NAME=kubernetes-the-hard-way
CONTROL_PLANE_LB=192.168.5.30
KUBECONFIG_DST=~/kubeconfigs
mkdir -p $KUBECONFIG_DST
CA_CRT=~/pki/ca/ca.crt
``` 

## 1. kube-proxy kubeconfig
```bash
kubectl config set-cluster ${CLUSTER_NAME} \
  --certificate-authority=${CA_CRT} \
  --embed-certs=true \
  --server=https://${CONTROL_PLANE_LB}:6443 \
  --kubeconfig=$KUBECONFIG_DST/kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
  --client-certificate=~/pki/proxy/kube-proxy.crt \
  --client-key=~/pki/proxy/kube-proxy.key \
  --embed-certs=true \
  --kubeconfig=$KUBECONFIG_DST/kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster=${CLUSTER_NAME} \
  --user=system:kube-proxy \
  --kubeconfig=$KUBECONFIG_DST/kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=$KUBECONFIG_DST/kube-proxy.kubeconfig
```

## 2. Controller Manager kubeconfig
```bash
kubectl config set-cluster ${CLUSTER_NAME} \
  --certificate-authority=${CA_CRT} \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=$KUBECONFIG_DST/kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=~/pki/controller/kube-controller-manager.crt \
  --client-key=~/pki/controller/kube-controller-manager.key \
  --embed-certs=true \
  --kubeconfig=$KUBECONFIG_DST/kube-controller-manager.kubeconfig

kubectl config set-context default \
  --cluster=${CLUSTER_NAME} \
  --user=system:kube-controller-manager \
  --kubeconfig=$KUBECONFIG_DST/kube-controller-manager.kubeconfig

kubectl config use-context default --kubeconfig=$KUBECONFIG_DST/kube-controller-manager.kubeconfig
```

## 3. Scheduler kubeconfig
```bash
kubectl config set-cluster ${CLUSTER_NAME} \
  --certificate-authority=${CA_CRT} \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=$KUBECONFIG_DST/kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \
  --client-certificate=~/pki/scheduler/kube-scheduler.crt \
  --client-key=~/pki/scheduler/kube-scheduler.key \
  --embed-certs=true \
  --kubeconfig=$KUBECONFIG_DST/kube-scheduler.kubeconfig

kubectl config set-context default \
  --cluster=${CLUSTER_NAME} \
  --user=system:kube-scheduler \
  --kubeconfig=$KUBECONFIG_DST/kube-scheduler.kubeconfig

kubectl config use-context default --kubeconfig=$KUBECONFIG_DST/kube-scheduler.kubeconfig
```

## 4. Admin kubeconfig
```bash
kubectl config set-cluster ${CLUSTER_NAME} \
  --certificate-authority=${CA_CRT} \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=$KUBECONFIG_DST/admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=~/pki/admin/admin.crt \
  --client-key=~/pki/admin/admin.key \
  --embed-certs=true \
  --kubeconfig=$KUBECONFIG_DST/admin.kubeconfig

kubectl config set-context default \
  --cluster=${CLUSTER_NAME} \
  --user=admin \
  --kubeconfig=$KUBECONFIG_DST/admin.kubeconfig

kubectl config use-context default --kubeconfig=$KUBECONFIG_DST/admin.kubeconfig
```

## 5. Distribute
```bash
for m in master-1 master-2; do
  scp $KUBECONFIG_DST/admin.kubeconfig $KUBECONFIG_DST/kube-controller-manager.kubeconfig $KUBECONFIG_DST/kube-scheduler.kubeconfig $m:~/
done

for w in worker-1 worker-2; do
  scp $KUBECONFIG_DST/kube-proxy.kubeconfig $w:~/
done
```

## Next
Data encryption config: `06-data-encryption-keys-modern.md`.
