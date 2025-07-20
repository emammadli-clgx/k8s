#!/bin/bash
# Script: bootstrap-etcd.sh
# Purpose: Bootstrap etcd on master nodes
# Run on: BOTH master-1 and master-2

set -e

echo "=== Bootstrapping etcd on $(hostname) ==="

# Define etcd version
ETCD_VERSION="v3.5.9"

# Download and install etcd binaries
echo "Downloading etcd ${ETCD_VERSION}..."
wget -q --show-progress --https-only --timestamping \
  "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"

echo "Extracting and installing etcd..."
{
  tar -xvf etcd-${ETCD_VERSION}-linux-amd64.tar.gz
  sudo mv etcd-${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/
}

# Configure etcd
echo "Configuring etcd..."
{
  sudo mkdir -p /etc/etcd /var/lib/etcd
  sudo cp ca.crt etcd-server.key etcd-server.crt /etc/etcd/
}

# Get internal IP address
INTERNAL_IP=$(ip addr show enp0s8 | grep "inet " | awk '{print $2}' | cut -d / -f 1)
echo "Internal IP: ${INTERNAL_IP}"

# Get etcd name
ETCD_NAME=$(hostname -s)
echo "ETCD name: ${ETCD_NAME}"

# Create systemd service file
echo "Creating etcd service file..."
cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/etcd-server.crt \\
  --key-file=/etc/etcd/etcd-server.key \\
  --peer-cert-file=/etc/etcd/etcd-server.crt \\
  --peer-key-file=/etc/etcd/etcd-server.key \\
  --trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster master-1=https://192.168.5.11:2380,master-2=https://192.168.5.12:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Start etcd
echo "Starting etcd service..."
{
  sudo systemctl daemon-reload
  sudo systemctl enable etcd
  sudo systemctl start etcd
}

echo "=== etcd bootstrap completed on $(hostname) ==="
echo "Note: Run this script on BOTH master-1 and master-2"