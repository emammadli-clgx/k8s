# Bootstrapping the Kubernetes Worker Nodes

In this lab, you will bootstrap two Kubernetes worker nodes. Docker is already installed on these nodes. We will now install the remaining Kubernetes components: `kubelet` and `kube-proxy`.

## Prerequisites

The commands in this lab must be run on each worker node: `worker-1` and `worker-2`. Log in to each worker node using SSH.

## Provisioning Kubelet Client Certificates

Kubernetes uses a special-purpose authorization mode called [Node Authorizer](https://kubernetes.io/docs/reference/access-authn-authz/node/) to authorize API requests made by kubelets. To be authorized, kubelets must use a credential that identifies them as being in the `system:nodes` group, with a username of `system:node:<nodeName>`.

### Generate a kubeconfig for each worker node

On `master-1`, generate a kubeconfig file for each worker node:

```bash
for instance in worker-1 worker-2; do
  LOADBALANCER_ADDRESS=192.168.5.30
  
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${LOADBALANCER_ADDRESS}:6443 \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=${instance}.pem \
    --client-key=${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${instance} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
done
```

### Copy the kubeconfig files to the worker nodes

```bash
for instance in worker-1 worker-2; do
  scp ${instance}.kubeconfig kube-proxy.kubeconfig vagrant@${instance}:~/
done
```

## Download and Install Worker Binaries

Log in to each worker node and run the following commands:

```bash
wget -q --show-progress --https-only --timestamping \
  https://storage.googleapis.com/kubernetes-release/release/v1.29.2/bin/linux/amd64/kubectl \
  https://storage.googleapis.com/kubernetes-release/release/v1.29.2/bin/linux/amd64/kube-proxy \
  https://storage.googleapis.com/kubernetes-release/release/v1.29.2/bin/linux/amd64/kubelet
```

Create the installation directories:

```bash
sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes
```

Install the worker binaries:

```bash
{
  chmod +x kubectl kube-proxy kubelet
  sudo mv kubectl kube-proxy kubelet /usr/local/bin/
}
```

### Configure the Kubelet

```bash
{
  sudo mv ${HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
  sudo mv ca.pem /var/lib/kubernetes/
}
```

Create the `kubelet-config.yaml` configuration file:

```bash
cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.96.0.10"
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/${HOSTNAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${HOSTNAME}-key.pem"
EOF
```

Create the `kubelet.service` systemd unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --network-plugin=cni \
  --register-node=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Configure the Kubernetes Proxy

```bash
sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
```

Create the `kube-proxy-config.yaml` configuration file:

```bash
cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "192.168.5.0/24"
EOF
```

Create the `kube-proxy.service` systemd unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Start the Worker Services

```bash
{
  sudo systemctl daemon-reload
  sudo systemctl enable kubelet kube-proxy
  sudo systemctl start kubelet kube-proxy
}
```

## Verification

Log in to `master-1` and list the registered nodes:

```bash
kubectl get nodes --kubeconfig admin.kubeconfig
```

> output

```
NAME       STATUS     ROLES    AGE   VERSION
worker-1   NotReady   <none>   1m    v1.29.2
worker-2   NotReady   <none>   1m    v1.29.2
```

> **Note:** It is expected for the worker nodes to be in a `NotReady` state at this point. This is because we have not yet configured networking.

Next: [Configuring `kubectl` for Remote Access](10-configuring-kubectl.md)