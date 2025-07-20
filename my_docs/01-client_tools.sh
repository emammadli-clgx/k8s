#!/bin/bash
# Script: install-kubectl.sh
# Purpose: Install kubectl on master-1 only
# Run from: master-1

set -e

echo "=== Installing kubectl on master-1 ==="

# Define kubectl version
KUBECTL_VERSION="v1.28.2"

# Download kubectl
echo "Downloading kubectl ${KUBECTL_VERSION}..."
wget https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl

# Make executable
chmod +x kubectl

# Move to /usr/local/bin
sudo mv kubectl /usr/local/bin/

echo "=== kubectl installation completed ==="