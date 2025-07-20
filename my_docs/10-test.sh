#!/bin/bash
# test.sh - Test kubectl access to the Kubernetes cluster
# Run on: master-1

set -e

# Define colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Testing kubectl access to Kubernetes cluster ===${NC}"

# Test 1: Check API server connection
echo -e "\n${YELLOW}1. Checking API server connection:${NC}"
if kubectl cluster-info &>/dev/null; then
  echo -e "${GREEN}✓ Connected to Kubernetes control plane${NC}"
  kubectl cluster-info | head -1
else
  echo -e "${RED}✗ Failed to connect to Kubernetes control plane${NC}"
  echo "Check that:"
  echo " - API server is running"
  echo " - Load balancer (if any) is working"
  echo " - Network connectivity is available"
fi

# Test 2: Check control plane component health
echo -e "\n${YELLOW}2. Checking control plane component status:${NC}"
if kubectl get componentstatuses &>/dev/null; then
  echo -e "${GREEN}✓ Control plane components are healthy${NC}"
  kubectl get componentstatuses
else
  echo -e "${RED}✗ Failed to get component status${NC}"
fi

# Test 3: Check node registration
echo -e "\n${YELLOW}3. Checking node registration:${NC}"
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [ "$NODE_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✓ Found $NODE_COUNT registered node(s)${NC}"
  kubectl get nodes -o wide
else
  echo -e "${RED}✗ No nodes are registered in the cluster${NC}"
fi

# Test 4: Check detailed node information
echo -e "\n${YELLOW}4. Checking detailed node status:${NC}"
for node in $(kubectl get nodes -o name 2>/dev/null | cut -d/ -f2); do
  READY=$(kubectl get node $node -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "$READY" == "True" ]; then
    echo -e "${GREEN}✓ Node $node is Ready${NC}"
  else
    echo -e "${YELLOW}! Node $node is NotReady${NC}"
    echo "  - This is normal if pod networking is not yet configured"
  fi
done

echo -e "\n${YELLOW}=== kubectl verification completed ===${NC}"