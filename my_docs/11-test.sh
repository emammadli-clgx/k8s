#!/bin/bash
# verify-network.sh - Verify pod networking deployment
# Run on: master-1

export KUBECONFIG=admin.kubeconfig

echo "=== Verifying pod network deployment ==="

# Check node status
echo "Node status:"
kubectl get nodes -o wide

# Check Weave pod status
echo "Weave pod status:"
kubectl get pods -n kube-system -l name=weave-net -o wide

# If any node has memory pressure, check the condition
for NODE in $(kubectl get nodes -o name | cut -d/ -f2); do
  if kubectl describe node $NODE | grep -q "MemoryPressure.*True"; then
    echo "Warning: $NODE has memory pressure"
    echo "Recommended: Increase the VM's memory allocation"
  fi
done

echo "=== Network verification completed ==="