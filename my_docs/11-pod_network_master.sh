#!/bin/bash
# deploy-weave.sh - Deploy Weave network
# Run on: master-1

set -e

echo "=== Deploying Weave network ==="

# Make sure we're using the admin kubeconfig
export KUBECONFIG=admin.kubeconfig

# Deploy Weave network
echo "Applying Weave network manifest..."
kubectl apply -f "https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml"

echo "=== Weave deployment completed ==="
echo "Wait a few minutes for the network to initialize"