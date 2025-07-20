#!/bin/bash
# Script: test-kubeconfigs.sh
# Purpose: Test that all kubeconfig files are generated and distributed correctly
# Run from: master-1

set -e

echo "=== Testing Kubernetes Configuration Files ==="

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

FAILED=0

# Check kubeconfigs in certificates directory
echo "Checking kubeconfigs in ~/certificates..."
KUBECONFIGS=(
    "kube-proxy.kubeconfig"
    "kube-controller-manager.kubeconfig"
    "kube-scheduler.kubeconfig"
    "admin.kubeconfig"
)

for config in "${KUBECONFIGS[@]}"; do
    if [ -f ~/certificates/$config ]; then
        echo -e "  $config: ${GREEN}EXISTS${NC}"
    else
        echo -e "  $config: ${RED}MISSING${NC}"
        ((FAILED++))
    fi
done

# Check master kubeconfigs on master-1
echo -e "\nChecking kubeconfigs on master-1..."
MASTER_CONFIGS=(
    "admin.kubeconfig"
    "kube-controller-manager.kubeconfig"
    "kube-scheduler.kubeconfig"
)

for config in "${MASTER_CONFIGS[@]}"; do
    if [ -f ~/$config ]; then
        echo -e "  $config: ${GREEN}EXISTS${NC}"
    else
        echo -e "  $config: ${RED}MISSING${NC}"
        ((FAILED++))
    fi
done

# Check master kubeconfigs on master-2
echo -e "\nChecking kubeconfigs on master-2..."
for config in "${MASTER_CONFIGS[@]}"; do
    if ssh vagrant@master-2 "test -f ~/$config" 2>/dev/null; then
        echo -e "  $config: ${GREEN}EXISTS${NC}"
    else
        echo -e "  $config: ${RED}MISSING${NC}"
        ((FAILED++))
    fi
done

# Check kube-proxy kubeconfig on workers
echo -e "\nChecking kube-proxy kubeconfig on worker nodes..."
for instance in worker-1 worker-2; do
    if ssh vagrant@${instance} "test -f ~/kube-proxy.kubeconfig" 2>/dev/null; then
        echo -e "  ${instance}: ${GREEN}EXISTS${NC}"
    else
        echo -e "  ${instance}: ${RED}MISSING${NC}"
        ((FAILED++))
    fi
done

# Verify kubeconfig contents by parsing the actual files
echo -e "\nVerifying kubeconfig contents..."

# Check admin kubeconfig
if grep -q "user: admin" ~/admin.kubeconfig && \
   grep -q "name: kubernetes-the-hard-way" ~/admin.kubeconfig && \
   grep -q "server: https://127.0.0.1:6443" ~/admin.kubeconfig; then
    echo -e "  admin.kubeconfig: ${GREEN}VALID${NC}"
else
    echo -e "  admin.kubeconfig: ${RED}INVALID${NC}"
    ((FAILED++))
fi

# Check kube-proxy kubeconfig uses load balancer
if grep -q "server: https://192.168.5.30:6443" ~/certificates/kube-proxy.kubeconfig && \
   grep -q "user: system:kube-proxy" ~/certificates/kube-proxy.kubeconfig; then
    echo -e "  kube-proxy.kubeconfig: ${GREEN}VALID${NC} (using load balancer)"
else
    echo -e "  kube-proxy.kubeconfig: ${RED}INVALID${NC}"
    ((FAILED++))
fi

# Check controller-manager uses localhost
if grep -q "server: https://127.0.0.1:6443" ~/kube-controller-manager.kubeconfig && \
   grep -q "user: system:kube-controller-manager" ~/kube-controller-manager.kubeconfig; then
    echo -e "  controller-manager.kubeconfig: ${GREEN}VALID${NC} (using localhost)"
else
    echo -e "  controller-manager.kubeconfig: ${RED}INVALID${NC}"
    ((FAILED++))
fi

# Check scheduler uses localhost
if grep -q "server: https://127.0.0.1:6443" ~/kube-scheduler.kubeconfig && \
   grep -q "user: system:kube-scheduler" ~/kube-scheduler.kubeconfig; then
    echo -e "  scheduler.kubeconfig: ${GREEN}VALID${NC} (using localhost)"
else
    echo -e "  scheduler.kubeconfig: ${RED}INVALID${NC}"
    ((FAILED++))
fi

# Verify file sizes (should be > 5000 bytes with embedded certs)
echo -e "\nVerifying kubeconfig file sizes..."
for config in "${MASTER_CONFIGS[@]}"; do
    SIZE=$(stat -c%s ~/$config 2>/dev/null || echo 0)
    if [ $SIZE -gt 5000 ]; then
        echo -e "  $config: ${GREEN}OK${NC} ($SIZE bytes)"
    else
        echo -e "  $config: ${RED}TOO SMALL${NC} ($SIZE bytes)"
        ((FAILED++))
    fi
done

# Show kubectl version
echo -e "\nkubectl version:"
kubectl version --client

# Summary
echo -e "\n=== Test Summary ==="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    echo "All kubeconfig files have been generated and distributed successfully."
else
    echo -e "${RED}$FAILED test(s) failed!${NC}"
    exit 1
fi