# Provisioning Pod Network

We will use [Weave Net](https://www.weave.works/docs/net/latest/kubernetes/kube-addon/) as our pod networking solution.

### Install CNI plugins

Download the CNI Plugins on each of the worker nodes (`worker-1` and `worker-2`):

```bash
wget -q --show-progress --https-only --timestamping 
  https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz
```

Extract it to `/opt/cni/bin` directory:

```bash
sudo tar -xzvf cni-plugins-linux-amd64-v1.4.0.tgz  --directory /opt/cni/bin/
```

### Deploy Weave Network

Deploy Weave Net. Run this command only once from `master-1`:

```bash
kubectl apply -f "https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml"
```

Weave Net uses a POD CIDR of `10.32.0.0/12` by default.

## Verification

List the registered Kubernetes nodes from `master-1`:

```bash
kubectl get nodes --kubeconfig admin.kubeconfig
```

> output

```
NAME       STATUS   ROLES    AGE   VERSION
worker-1   Ready    <none>   2m    v1.29.2
worker-2   Ready    <none>   2m    v1.29.2
```

Check the status of the Weave Net pods:

```bash
kubectl get pods -n kube-system --kubeconfig admin.kubeconfig
```

> output

```
NAME              READY   STATUS    RESTARTS   AGE
weave-net-xxxxx   2/2     Running   0          2m
weave-net-yyyyy   2/2     Running   0          2m
```

Next: [Kube API Server to Kubelet Connectivity](13-kube-apiserver-to-kubelet.md)
