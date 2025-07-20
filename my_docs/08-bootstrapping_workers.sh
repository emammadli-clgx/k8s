#!/bin/bash
# run.sh - Uninstall Docker, install containerd, and configure Kubernetes worker
# Run on: worker-1

set -e

echo "=== Setting up Kubernetes Worker with containerd ==="

# Step 1: Stop services and remove Docker
echo "Stopping kubelet and removing Docker..."
sudo systemctl stop kubelet || true
sudo systemctl disable docker || true
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true

# Step 2: Install containerd
echo "Installing containerd..."
sudo apt-get update
sudo apt-get install -y containerd

# Step 3: Configure containerd for Kubernetes
echo "Configuring containerd..."
sudo mkdir -p /etc/containerd
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

# Step 4: Restart containerd
echo "Restarting containerd..."
sudo systemctl restart containerd
sudo systemctl enable containerd

# Step 5: Install crictl tool
echo "Installing crictl tool..."
CRICTL_VERSION="v1.29.0"
wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -zxf crictl-$CRICTL_VERSION-linux-amd64.tar.gz
rm -f crictl-$CRICTL_VERSION-linux-amd64.tar.gz

# Configure crictl default runtime
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# Step 6: Install CNI plugins if needed
echo "Installing CNI plugins..."
if [ ! -d "/opt/cni/bin" ] || [ -z "$(ls -A /opt/cni/bin 2>/dev/null)" ]; then
  sudo mkdir -p /opt/cni/bin
  CNI_VERSION="v1.3.0"
  wget -q "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
  sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-${CNI_VERSION}.tgz
fi

# Step 7: Configure CNI networking
echo "Configuring CNI networking..."
sudo mkdir -p /etc/cni/net.d
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

# Step 8: Configure kubelet
echo "Configuring kubelet..."
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

# Step 9: Configure kubelet service
echo "Creating kubelet service file..."
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --register-node=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Step 10: Fix permissions on certificates
echo "Fixing certificate permissions..."
sudo chmod 644 /var/lib/kubernetes/ca.crt
sudo chmod 600 /var/lib/kubelet/worker-1.key
sudo chmod 644 /var/lib/kubelet/worker-1.crt
sudo chmod 600 /var/lib/kubelet/kubeconfig

# Step 11: Start kubelet
echo "Starting kubelet service..."
sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl restart kubelet

echo "=== Worker setup completed ==="
echo "Run test.sh to verify the installation"