#!/bin/bash

# Load the required kernel modules first
modprobe br_netfilter
modprobe overlay

# Ensure the modules load on system boot
cat > /etc/modules-load.d/k8s.conf <<EOF
br_netfilter
overlay
EOF

# Configure sysctl parameters required by Kubernetes
cat > /etc/sysctl.d/kubernetes.conf <<EOF
# Enable bridge netfilter
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1

# Enable IP forwarding
net.ipv4.ip_forward = 1

# Disable swap accounting (recommended for Kubernetes)
vm.swappiness = 0

# Network optimizations for containers
net.netfilter.nf_conntrack_max = 1000000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
EOF

# Apply settings immediately
sysctl --system

# Disable swap permanently (required for Kubernetes)
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "System configured for Kubernetes with containerd runtime"
