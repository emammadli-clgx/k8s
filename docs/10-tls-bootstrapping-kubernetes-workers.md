# TLS Bootstrapping Worker Nodes

In this lab, you will configure Kubernetes worker nodes to use TLS bootstrapping. This process allows worker nodes to generate their own certificate key pairs, submit certificate signing requests (CSRs) to the Kubernetes CA, retrieve signed certificates, and automatically join the cluster.

## Prerequisites

The commands in this lab must be run on each worker node: `worker-1` and `worker-2`. Log in to each worker node using SSH.

## Step 1: Configure the Binaries on the Worker Node

### Download and Install Worker Binaries

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

### Move the CA Certificate

Copy the `ca.pem` file (generated in a previous step) to `/var/lib/kubernetes/` on each worker node:

```bash
scp master-1:/home/vagrant/ca.pem /var/lib/kubernetes/
```

## Step 2: Create the Bootstrap Token

On `master-1`, create a bootstrap token. This token will be used by the kubelets to authenticate to the Kubernetes API server and submit CSRs.

Bootstrap tokens are of the form `abcdef.0123456789abcdef` (6 character token ID followed by 16 character token secret).

```bash
TOKEN_ID=$(head -c 3 /dev/urandom | od -x | head -n 1 | awk '{print $2}')
TOKEN_SECRET=$(head -c 8 /dev/urandom | od -x | head -n 1 | awk '{print $2}')
BOOTSTRAP_TOKEN="${TOKEN_ID}.${TOKEN_SECRET}"

cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${TOKEN_ID}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  description: "Bootstrap token for worker nodes"
  token-id: ${TOKEN_ID}
  token-secret: ${TOKEN_SECRET}
  expiration: $(date -d '+1 year' -u +%Y-%m-%dT%H:%M:%SZ)
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: system:bootstrappers:worker
EOF

echo "Bootstrap Token: ${BOOTSTRAP_TOKEN}"
```

## Step 3: Authorize Workers to Create and Approve CSRs

On `master-1`, create `ClusterRoleBinding`s to allow worker nodes to create and approve CSRs.

```bash
kubeclt create clusterrolebinding create-csrs-for-bootstrapping \
  --clusterrole=system:node-bootstrapper \
  --group=system:bootstrappers --kubeconfig admin.kubeconfig

kubeclt create clusterrolebinding auto-approve-csrs-for-group \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:nodeclient \
  --group=system:bootstrappers --kubeconfig admin.kubeconfig

kubeclt create clusterrolebinding auto-approve-renewals-for-nodes \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:selfnodeclient \
  --group=system:nodes --kubeconfig admin.kubeconfig
```

## Step 4: Configure Kubelet to TLS Bootstrap

On each worker node, create a bootstrap kubeconfig file. This file will contain the bootstrap token and information about the Kubernetes API server.

```bash
BOOTSTRAP_TOKEN="<YOUR_GENERATED_BOOTSTRAP_TOKEN>" # Replace with the token from Step 2
LOADBALANCER_ADDRESS=192.168.5.30

sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-cluster bootstrap \
  --server=https://${LOADBALANCER_ADDRESS}:6443 \
  --certificate-authority=/var/lib/kubernetes/ca.pem

sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-credentials kubelet-bootstrap \
  --token=${BOOTSTRAP_TOKEN}

sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-context default \
  --user=kubelet-bootstrap \
  --cluster=bootstrap

sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig use-context default
```

## Step 5: Create Kubelet Config File

On each worker node, create the `kubelet-config.yaml` configuration file:

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
EOF
```

## Step 6: Configure Kubelet Service

On each worker node, create the `kubelet.service` systemd unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --bootstrap-kubeconfig="/var/lib/kubelet/bootstrap-kubeconfig" \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --cert-dir=/var/lib/kubelet/pki/ \
  --rotate-certificates=true \
  --rotate-server-certificates=true \
  --network-plugin=cni \
  --register-node=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

## Step 7: Configure the Kubernetes Proxy

On each worker node, move the `kube-proxy.kubeconfig` into place:

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

## Step 8: Start the Worker Services

On each worker node:

```bash
{
  sudo systemctl daemon-reload
  sudo systemctl enable kubelet kube-proxy
  sudo systemctl start kubelet kube-proxy
}
```

## Step 9: Approve Server CSR

On `master-1`, list and approve the pending CSRs:

```bash
kubeclt get csr --kubeconfig admin.kubeconfig
# Example output:
# NAME        AGE   REQUESTOR             CONDITION
# csr-xxxxx   1m    system:node:worker-1  Pending

kubeclt certificate approve <csr-name> --kubeconfig admin.kubeconfig
```

## Verification

Log in to `master-1` and list the registered nodes:

```bash
kubeclt get nodes --kubeconfig admin.kubeconfig
```

> output

```
NAME       STATUS     ROLES    AGE   VERSION
worker-1   NotReady   <none>   1m    v1.29.2
worker-2   NotReady   <none>   1m    v1.29.2
```

> **Note:** It is expected for the worker nodes to be in a `NotReady` state at this point. This is because we have not yet configured networking.

Next: [Configuring `kubectl` for Remote Access](11-configuring-kubectl.md)