#!/bin/bash

# Update system packages
apt-get update
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Install containerd from Ubuntu repositories (more stable approach)
apt-get update
apt-get install -y containerd

# Create containerd configuration directory
mkdir -p /etc/containerd

# Generate default containerd configuration
containerd config default | tee /etc/containerd/config.toml

# Configure containerd to use systemd as the cgroup driver (required for Kubernetes)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Ensure containerd uses the correct sandbox image for Kubernetes
sed -i 's|sandbox_image = "registry.k8s.io/pause:3.6"|sandbox_image = "registry.k8s.io/pause:3.9"|g' /etc/containerd/config.toml

# Enable and start containerd service
systemctl enable containerd
systemctl daemon-reload
systemctl restart containerd

# Verify containerd is running
systemctl status containerd --no-pager -l

# Install runc (container runtime) if not already present
apt-get install -y runc

# Install CNI plugins (required for container networking)
apt-get install -y kubernetes-cni || {
    echo "Installing CNI plugins manually..."
    CNI_VERSION="v1.3.0"
    mkdir -p /opt/cni/bin
    curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz
}

# Verify containerd and runc versions
echo "=== Containerd Installation Complete ==="
containerd --version
runc --version

echo "Containerd configuration:"
cat /etc/containerd/config.toml | grep -E "(SystemdCgroup|sandbox_image)" || echo "Configuration may need verification"
