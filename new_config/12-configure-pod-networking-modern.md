# Configure Pod Networking (Modernized 2025)

## Why Update?
- Weave Net still works, but newer CNIs (Cilium, Calico) offer eBPF performance/features.
- Demonstrate choice; default here: Cilium (eBPF, NetworkPolicy, observability) with fallback to Weave instructions.

## Pod CIDR
Original Weave implicit pod CIDR 10.32.0.0/12 is fine. Ensure no overlap with service CIDR (10.96.0.0/24). If you change Pod CIDR later you must recreate cluster; choose now.

## Option A: Cilium (Recommended)
### Install Cilium CLI (on admin host/master-1)
```bash
CILIUM_CLI_VERSION=v0.16.12
ARCH=amd64
curl -L --remote-name https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz
curl -L --remote-name https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz.sha256sum
sha256sum -c cilium-linux-${ARCH}.tar.gz.sha256sum
sudo tar -C /usr/local/bin -xzf cilium-linux-${ARCH}.tar.gz
rm cilium-linux-${ARCH}.tar.gz*
```

### Deploy
```bash
cilium install --kubeconfig ~/kubeconfigs/admin.kubeconfig --set cluster.name=kthw --set ipam.mode=kubernetes
```
(Uses kube-apiserver IPAM; pod CIDRs assigned automatically.)

### Verify
```bash
cilium status --kubeconfig ~/kubeconfigs/admin.kubeconfig
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get pods -n kube-system -l k8s-app=cilium
```
Nodes should move to Ready.

## Option B: Weave Net (Legacy Style)
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version --kubeconfig ~/kubeconfigs/admin.kubeconfig | base64 | tr -d '\n')"
```
Check:
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig -n kube-system get pods -l name=weave-net
```

## Option C: Calico (Policy Focus)
```bash
curl https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml -O
# Optionally edit POD_CIDR in manifest if required.
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig apply -f calico.yaml
```

## Test DNS & Networking (after CoreDNS deployed later or if installed by default)
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig create deployment test-nginx --image=nginx:stable-alpine
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig expose deployment test-nginx --port 80
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig run curl --image=curlimages/curl -i --restart=Never --rm -it -- curl -s test-nginx.default.svc.cluster.local
```

## Next
API server to kubelet config or DNS addon depending on sequence: continue with `13-kube-apiserver-to-kubelet-modern.md`.
