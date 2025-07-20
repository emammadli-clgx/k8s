#!/bin/bash
# run.sh - TLS Bootstrapping Setup for worker-2
# Run on worker-2

set -e

echo "=== Setting up worker-2 with TLS Bootstrapping ==="

# Step 1: Download and Install Worker Binaries
echo "Downloading Kubernetes binaries..."
K8S_VERSION="v1.28.4"
wget -q --show-progress --https-only --timestamping \
  "https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
  "https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kube-proxy" \
  "https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubelet"

echo "Creating installation directories..."
sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

echo "Installing worker binaries..."
{
  chmod +x kubectl kube-proxy kubelet
  sudo mv kubectl kube-proxy kubelet /usr/local/bin/
}

echo "Moving CA certificate..."
sudo mv ca.crt /var/lib/kubernetes/

# Step 2: Configure containerd with CRI plugin
echo "Configuring containerd with CRI plugin..."
sudo mkdir -p /etc/containerd/
cat <<EOF | sudo tee /etc/containerd/config.toml
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"

[grpc]
  address = "/run/containerd/containerd.sock"

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.9"
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
EOF

# Restart containerd
echo "Restarting containerd..."
sudo systemctl restart containerd

# Step 3: Install CNI plugins
echo "Installing CNI plugins..."
CNI_VERSION="v1.3.0"
wget -q --show-progress --https-only --timestamping \
  "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-${CNI_VERSION}.tgz
rm -f cni-plugins-linux-amd64-${CNI_VERSION}.tgz

# Create basic CNI configuration
echo "Creating CNI configuration..."
cat <<EOF | sudo tee /etc/cni/net.d/10-containerd-net.conf
{
  "cniVersion": "0.4.0",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "10.22.0.0/16"
          }]
        ],
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF

# Step 4: Configure Bootstrap Kubeconfig
echo "Creating bootstrap kubeconfig..."
sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-cluster bootstrap \
  --server='https://192.168.5.30:6443' \
  --certificate-authority=/var/lib/kubernetes/ca.crt

sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-credentials kubelet-bootstrap \
  --token=07401b.f395accd246ae52d

sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-context bootstrap \
  --user=kubelet-bootstrap \
  --cluster=bootstrap

sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig use-context bootstrap

# Step 5: Configure Kubelet
echo "Creating kubelet configuration..."
cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.crt"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.96.0.10"
resolvConf: "/run/systemd/resolve/resolv.conf"
cgroupDriver: "systemd"
EOF

# Step 6: Create kubelet service
echo "Creating kubelet service..."
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --bootstrap-kubeconfig="/var/lib/kubelet/bootstrap-kubeconfig" \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --cert-dir=/var/lib/kubelet/pki/ \\
  --rotate-certificates=true \\
  --rotate-server-certificates=true \\
  --register-node=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Step 7: Configure kube-proxy
echo "Creating kube-proxy configuration..."
cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "192.168.5.0/24"
EOF

# Create a temporary kubeconfig for kube-proxy using token auth
cat <<EOF | sudo tee /var/lib/kube-proxy/kubeconfig
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /var/lib/kubernetes/ca.crt
    server: https://192.168.5.30:6443
  name: default
contexts:
- context:
    cluster: default
    user: system:kube-proxy
  name: default
current-context: default
users:
- name: system:kube-proxy
  user:
    token: 07401b.f395accd246ae52d
EOF

echo "Creating kube-proxy service..."
cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Step 8: Start services
echo "Starting kubelet and kube-proxy services..."
{
  sudo systemctl daemon-reload
  sudo systemctl enable kubelet kube-proxy
  sudo systemctl start kubelet kube-proxy
}

echo "=== TLS bootstrapping setup completed on worker-2 ==="
echo "Run test.sh on master-1 to verify node registration and approve CSRs"