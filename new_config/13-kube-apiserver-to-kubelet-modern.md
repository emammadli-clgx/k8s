# RBAC: API Server Access to Kubelet (Modernized 2025)

## Why Update?
- Use stable RBAC API version (v1) instead of deprecated v1beta1
- Clarify subject naming; use user `kube-apiserver` only if client cert CN matches
- Minimize requested verbs (least privilege)

Confirm kube-apiserver client cert CN (from earlier generation we used CN=kube-apiserver). That subject is what we bind.

ClusterRole (scoped to needed node subresources):
```bash
cat <<'EOF' | kubectl apply --kubeconfig ~/kubeconfigs/admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kube-apiserver-to-kubelet
rules:
- apiGroups: ['']
  resources:
  - nodes/proxy
  - nodes/stats
  - nodes/log
  - nodes/spec
  - nodes/metrics
  verbs: ['get','list','watch','create','delete']
EOF
```
Reason: avoid wildcard '*' write verbs across the board.

Binding:
```bash
cat <<'EOF' | kubectl apply --kubeconfig ~/kubeconfigs/admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
- kind: User
  name: kube-apiserver
  apiGroup: rbac.authorization.k8s.io
EOF
```

Verification (after some pods running):
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig logs -n kube-system -l k8s-app=cilium --tail=1 || true
```

## Next
Deploy DNS (CoreDNS) modernized: `14-dns-addon-modern.md`.
