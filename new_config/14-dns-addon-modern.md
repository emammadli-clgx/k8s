# DNS Add-on (CoreDNS) (Modernized 2025)

## Why Update?
- Use current CoreDNS manifest from official Kubernetes repo
- Validate service IP matches cluster service CIDR (10.96.0.10)
- Add readiness verification and troubleshooting steps

## Install CoreDNS
Fetch and apply a version-aligned manifest (example for v1.30):
```bash
curl -L -o coredns.yaml https://raw.githubusercontent.com/kubernetes/kubernetes/v1.30.4/cluster/addons/dns/coredns/coredns.yaml.in
# Replace template variables if needed (the .in file may require substitution in some releases). If already processed, skip.
# Ensure ClusterIP 10.96.0.10 matches your service CIDR first IP.
grep -q '10.96.0.10' coredns.yaml || sed -i 's/ClusterIP: .*/ClusterIP: 10.96.0.10/' coredns.yaml || true
kubectl --kubeconfig ~/admin.kubeconfig apply -f coredns.yaml
```

(Alternatively use a packaged manifest from your distribution if present.)

## Verification
```bash
kubectl --kubeconfig ~/admin.kubeconfig -n kube-system get deploy coredns
kubectl --kubeconfig ~/admin.kubeconfig -n kube-system get pods -l k8s-app=kube-dns -w
```
Wait for READY 1/1 (or 2/2 if dual containers).

## Basic DNS Test
```bash
kubectl --kubeconfig ~/admin.kubeconfig run dns-test --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl --kubeconfig ~/admin.kubeconfig exec dns-test -- nslookup kubernetes.default
```
Should resolve to 10.96.0.1.

Cleanup (optional):
```bash
kubectl --kubeconfig ~/admin.kubeconfig delete pod dns-test
```

## Next
Smoke tests: `15-smoke-test-modern.md`.
