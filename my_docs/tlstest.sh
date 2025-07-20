#!/bin/bash
# test.sh - Test TLS bootstrapping setup
# Run on master-1 after worker setup

set -e

# Use admin.kubeconfig for all kubectl commands
export KUBECONFIG=admin.kubeconfig

# Define colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Testing TLS Bootstrapping of worker-2 ===${NC}"

# Step 1: Check if bootstrap token exists
echo -e "\n${YELLOW}Checking bootstrap token:${NC}"
if kubectl get secret bootstrap-token-07401b -n kube-system &>/dev/null; then
  echo -e "${GREEN}✓ Bootstrap token exists${NC}"
else
  echo -e "${RED}✗ Bootstrap token not found!${NC}"
  echo "Run prep-master.sh again to create the bootstrap token"
fi

# Step 2: Check CSRs
echo -e "\n${YELLOW}Checking Certificate Signing Requests:${NC}"
kubectl get csr

# Step 3: Check for pending CSRs and approve them
PENDING_CSRS=$(kubectl get csr 2>/dev/null | grep Pending | awk '{print $1}' 2>/dev/null)
if [ -n "$PENDING_CSRS" ]; then
  echo -e "\n${YELLOW}Approving pending CSRs:${NC}"
  for CSR in $PENDING_CSRS; do
    kubectl certificate approve "$CSR"
    echo "Approved CSR: $CSR"
  done
else
  echo "No pending CSRs found"
fi

# Step 4: Check node registration
echo -e "\n${YELLOW}Checking node registration:${NC}"
if kubectl get node worker-2 &>/dev/null; then
  echo -e "${GREEN}✓ worker-2 is registered!${NC}"
  kubectl get node worker-2 -o wide
else
  echo -e "${RED}✗ worker-2 is not registered yet${NC}"
  echo "Registered nodes:"
  kubectl get nodes
  
  # Add debugging suggestions
  echo -e "\n${YELLOW}Debugging suggestions if worker-2 is not registered:${NC}"
  echo "1. Check kubelet logs: ssh vagrant@worker-2 'sudo journalctl -u kubelet -n 20'"
  echo "2. Verify containerd is working: ssh vagrant@worker-2 'sudo systemctl status containerd'"
  echo "3. Check bootstrap token: kubectl -n kube-system get secret bootstrap-token-07401b"
fi

# Step 5: Check node status
if kubectl get node worker-2 &>/dev/null; then
  NODE_STATUS=$(kubectl get node worker-2 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "$NODE_STATUS" == "True" ]; then
    echo -e "${GREEN}✓ worker-2 is in Ready state${NC}"
  else
    echo -e "${YELLOW}! worker-2 is registered but not Ready${NC}"
    echo "This is normal if networking (CNI) is not yet fully configured"
  fi
fi

echo -e "\n${YELLOW}=== TLS Bootstrapping verification completed ===${NC}"