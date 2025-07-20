#!/bin/bash
# Script: test-control-plane.sh
# Purpose: Test Kubernetes control plane functionality
# Run on: master-1

set -e

echo "=== Testing Kubernetes Control Plane ==="

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

FAILED=0

# Check required binaries
echo "Checking Kubernetes binaries..."
for binary in kube-apiserver kube-controller-manager kube-scheduler kubectl; do
    if command -v $binary &> /dev/null; then
        echo -e "  $binary: ${GREEN}INSTALLED${NC}"
        $binary --version | head -1
    else
        echo -e "  $binary: ${RED}NOT FOUND${NC}"
        ((FAILED++))
    fi
done

# Check services on master-1
echo -e "\nChecking services on master-1..."
for service in kube-apiserver kube-controller-manager kube-scheduler; do
    if sudo systemctl is-active --quiet $service; then
        echo -e "  $service: ${GREEN}ACTIVE${NC}"
    else
        echo -e "  $service: ${RED}INACTIVE${NC}"
        sudo systemctl status $service --no-pager || true
        ((FAILED++))
    fi
done

# Check services on master-2
echo -e "\nChecking services on master-2..."
for service in kube-apiserver kube-controller-manager kube-scheduler; do
    if ssh vagrant@master-2 "sudo systemctl is-active --quiet $service" 2>/dev/null; then
        echo -e "  $service: ${GREEN}ACTIVE${NC}"
    else
        echo -e "  $service: ${RED}INACTIVE${NC}"
        ssh vagrant@master-2 "sudo systemctl status $service --no-pager" || true
        ((FAILED++))
    fi
done

# Check component status using kubectl
echo -e "\nChecking component status with kubectl..."
if kubectl get componentstatuses --kubeconfig admin.kubeconfig &> /dev/null; then
    echo -e "  Component status: ${GREEN}AVAILABLE${NC}"
    kubectl get componentstatuses --kubeconfig admin.kubeconfig
else
    echo -e "  Component status: ${RED}UNAVAILABLE${NC}"
    ((FAILED++))
fi

# Test load balancer
echo -e "\nTesting HAProxy load balancer..."
if curl -s -k https://192.168.5.30:6443/version &> /dev/null; then
    echo -e "  Load balancer: ${GREEN}WORKING${NC}"
    curl -s -k https://192.168.5.30:6443/version
else
    echo -e "  Load balancer: ${RED}NOT WORKING${NC}"
    ((FAILED++))
fi

# Summary
echo -e "\n=== Test Summary ==="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    echo "Kubernetes control plane is running correctly."
else
    echo -e "${RED}$FAILED test(s) failed!${NC}"
    exit 1
fi