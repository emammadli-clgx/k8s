# Smoke Test (Modernized 2025)

## 1. Data Encryption Validation
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig create secret generic kthw-secret --from-literal=mykey=mydata
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key get /registry/secrets/default/kthw-secret | hexdump -C | head
```
Expect `k8s:enc:aescbc:v1:key1` prefix.
Cleanup:
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig delete secret kthw-secret
```

## 2. Deployment & Service
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig create deployment nginx --image=nginx:stable-alpine
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig rollout status deploy/nginx
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig expose deployment nginx --type=NodePort --port 80
PORT=$(kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')
curl -s http://worker-1:${PORT} | grep -i nginx || curl -s http://worker-2:${PORT} | grep -i nginx
```

## 3. Logs & Exec
```bash
POD=$(kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig logs $POD | head -n1 || true
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig exec $POD -- nginx -v
```

## 4. Port Forward (Optional)
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig port-forward deploy/nginx 8080:80 &
sleep 2
curl -I http://127.0.0.1:8080 | head -n1
kill %1
```

## 5. Cluster Info
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get nodes -o wide
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get cs || true   # may show deprecation warnings
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get pods -A
```

## Cleanup (Optional)
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig delete svc nginx
grpcurl # (if installed for future tests) – ignore if unavailable
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig delete deploy nginx
```

## Next
(Optional) Run extended conformance: `16-e2e-tests-modern.md`.
