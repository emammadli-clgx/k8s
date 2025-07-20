#!/bin/bash
# install-cni.sh - Install CNI plugins for Weave network
# Run on: worker-1 and worker-2

set -e

echo "=== Installing CNI plugins for Weave network ==="

# Install CNI plugins
echo "Installing CNI plugins..."
CNI_VERSION="v1.3.0"
wget -q --show-progress --https-only --timestamping \
  "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"

# Create directory and extract
sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-${CNI_VERSION}.tgz
rm -f cni-plugins-linux-amd64-${CNI_VERSION}.tgz

# Create CNI config directory
sudo mkdir -p /etc/cni/net.d

echo "=== CNI plugin installation completed ==="