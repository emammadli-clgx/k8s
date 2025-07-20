#!/bin/bash
# run.sh - Configure kubectl for admin access
# Run on: master-1

set -e

echo "=== Configuring kubectl for admin access ==="

# Check for admin.kubeconfig file
if [ ! -f "admin.kubeconfig" ]; then
  echo "Error: admin.kubeconfig not found in current directory"
  echo "Please run this script from the directory containing your admin.kubeconfig"
  exit 1
fi

# Set the admin.kubeconfig as the default kubeconfig
mkdir -p ~/.kube
cp admin.kubeconfig ~/.kube/config
chmod 600 ~/.kube/config

# Also set KUBECONFIG for the current session
export KUBECONFIG=$(pwd)/admin.kubeconfig

# Verify kubectl can connect to the cluster
if kubectl cluster-info &>/dev/null; then
  echo "Success: kubectl configured and connected to the cluster"
else
  echo "Warning: kubectl is configured but couldn't connect to the cluster"
  echo "Please check your network connection and API server status"
fi

echo "=== kubectl configuration completed ==="
echo "You can now use kubectl commands without specifying --kubeconfig"