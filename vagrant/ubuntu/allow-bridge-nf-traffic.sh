#!/bin/bash

# Load the required kernel module first
modprobe br_netfilter

# Ensure the module loads on system boot
echo "br_netfilter" | tee /etc/modules-load.d/br_netfilter.conf

# Now enable the settings
sysctl net.bridge.bridge-nf-call-iptables=1
sysctl net.bridge.bridge-nf-call-ip6tables=1

# Make the settings persistent
cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

# Apply settings
sysctl --system