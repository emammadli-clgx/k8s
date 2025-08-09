# Configuring kubectl for Remote Access (Modernized 2025)

## Why Update?
- Use existing generated admin kubeconfig file instead of recreating where possible
- Clarify deprecation of `componentstatuses` (use /readyz & /livez endpoints)
- Provide context for multi-cluster contexts in one file

If you followed earlier steps you already created `admin.kubeconfig` targeting 127.0.0.1 for local use. Create a second context for the external load balancer if desired.

Variables:
```bash
LB=192.168.5.30
CLUSTER=kubernetes-the-hard-way
ADMIN_KUBECONFIG=~/kubeconfigs/admin.kubeconfig
```

Patch cluster server to LB for this kubeconfig (or duplicate file first):
```bash
kubectl config set-cluster ${CLUSTER} \
  --server=https://${LB}:6443 \
  --kubeconfig ${ADMIN_KUBECONFIG}
```
(Embedded CA cert remains.)

Optional create a context name showing it’s via LB:
```bash
kubectl config set-context ${CLUSTER}-lb \
  --cluster=${CLUSTER} --user=admin --kubeconfig ${ADMIN_KUBECONFIG}
kubectl config use-context ${CLUSTER}-lb --kubeconfig ${ADMIN_KUBECONFIG}
```

## Modern Health Checks
ComponentStatuses is deprecated/noisy. Prefer:
```bash
kubectl --kubeconfig ${ADMIN_KUBECONFIG} get --raw /readyz?verbose
kubectl --kubeconfig ${ADMIN_KUBECONFIG} get --raw /livez?verbose
```

List nodes:
```bash
kubectl --kubeconfig ${ADMIN_KUBECONFIG} get nodes -o wide
```
Expect NotReady workers until CNI applied.

## Multi-Cluster (Optional)
If you later add clusters, set separate contexts; avoid overwriting default context inadvertently.

## Next
API server to kubelet RBAC: `13-kube-apiserver-to-kubelet-modern.md`.
