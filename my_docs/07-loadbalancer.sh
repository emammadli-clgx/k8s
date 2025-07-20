#!/bin/bash
# Script: configure-loadbalancer.sh
# Purpose: Configure HAProxy as load balancer for Kubernetes API servers
# Run on: lb node

set -e

echo "=== Configuring HAProxy Load Balancer ==="

# Install HAProxy
echo "Installing HAProxy..."
sudo apt-get update
sudo apt-get install -y haproxy

# Configure HAProxy for Kubernetes
echo "Configuring HAProxy..."
cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg 
frontend kubernetes
    bind 192.168.5.30:6443
    option tcplog
    mode tcp
    default_backend kubernetes-master-nodes

backend kubernetes-master-nodes
    mode tcp
    balance roundrobin
    option tcp-check
    server master-1 192.168.5.11:6443 check fall 3 rise 2
    server master-2 192.168.5.12:6443 check fall 3 rise 2
EOF

# Restart HAProxy
echo "Restarting HAProxy service..."
sudo service haproxy restart

echo "=== Load balancer configured ==="
echo "Kubernetes API is now available at https://192.168.5.30:6443"