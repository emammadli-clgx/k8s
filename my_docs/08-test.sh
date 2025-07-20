#!/bin/bash
# test.sh - Test worker node setup
# Can be run on either worker-1 or master-1

set -e

# Define colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check which host we're running on
HOST=$(hostname)

if [ "$HOST" = "worker-1" ]; then
    echo -e "${YELLOW}=== Testing worker node components on worker-1 ===${NC}"
    
    # Check containerd status
    echo -e "\n${YELLOW}Checking containerd service:${NC}"
    if systemctl is-active --quiet containerd; then
        echo -e "${GREEN}✓ containerd is running${NC}"
        containerd_version=$(containerd --version)
        echo "Version: $containerd_version"
    else
        echo -e "${RED}✗ containerd is NOT running${NC}"
        echo "Status:"
        systemctl status containerd --no-pager | head -10
    fi
    
    # Check Docker is removed
    echo -e "\n${YELLOW}Checking Docker removal:${NC}"
    if ! command -v docker &> /dev/null; then
        echo -e "${GREEN}✓ Docker is not installed${NC}"
    else
        echo -e "${RED}✗ Docker is still installed${NC}"
        docker --version
    fi
    
    # Check containerd CRI functionality
    echo -e "\n${YELLOW}Testing containerd CRI functionality:${NC}"
    if sudo crictl info &>/dev/null; then
        echo -e "${GREEN}✓ containerd CRI is working${NC}"
        # Show runtime info summary
        sudo crictl info | grep -A 3 "RuntimeName"
    else
        echo -e "${RED}✗ containerd CRI test failed${NC}"
    fi
    
    # Check kubelet status
    echo -e "\n${YELLOW}Checking kubelet service:${NC}"
    if systemctl is-active --quiet kubelet; then
        echo -e "${GREEN}✓ kubelet is running${NC}"
        kubelet_version=$(/usr/local/bin/kubelet --version)
        echo "Version: $kubelet_version"
    else
        echo -e "${RED}✗ kubelet is NOT running${NC}"
        echo "Status:"
        systemctl status kubelet --no-pager | head -10
        
        # Show kubelet logs
        echo -e "\n${YELLOW}Latest kubelet logs:${NC}"
        journalctl -u kubelet -n 10 --no-pager
    fi
    
    # Check CNI plugins
    echo -e "\n${YELLOW}Checking CNI plugins:${NC}"
    if [ -d "/opt/cni/bin" ] && [ "$(ls -A /opt/cni/bin)" ]; then
        echo -e "${GREEN}✓ CNI plugins are installed${NC}"
        ls -la /opt/cni/bin | wc -l
    else
        echo -e "${RED}✗ CNI plugins are missing${NC}"
    fi
    
    # Check CNI configuration
    echo -e "\n${YELLOW}Checking CNI configuration:${NC}"
    if [ -d "/etc/cni/net.d" ] && [ "$(ls -A /etc/cni/net.d)" ]; then
        echo -e "${GREEN}✓ CNI configuration exists${NC}"
        ls -la /etc/cni/net.d
    else
        echo -e "${RED}✗ CNI configuration is missing${NC}"
    fi

elif [ "$HOST" = "master-1" ]; then
    echo -e "${YELLOW}=== Testing worker node registration from master-1 ===${NC}"
    
    # Check if node is registered
    echo -e "\n${YELLOW}Checking if worker-1 is registered:${NC}"
    if kubectl get node worker-1 --kubeconfig admin.kubeconfig &>/dev/null; then
        echo -e "${GREEN}✓ worker-1 is registered!${NC}"
        kubectl get node worker-1 --kubeconfig admin.kubeconfig -o wide
    else
        echo -e "${RED}✗ worker-1 is not registered${NC}"
        echo "Registered nodes:"
        kubectl get nodes --kubeconfig admin.kubeconfig || echo "No nodes registered"
    fi
    
    # Check if node is Ready
    NODE_STATUS=$(kubectl get node worker-1 --kubeconfig admin.kubeconfig -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
    if [ "$NODE_STATUS" = "True" ]; then
        echo -e "${GREEN}✓ worker-1 is in Ready state${NC}"
    elif [ "$NODE_STATUS" = "NotFound" ]; then
        echo -e "${RED}✗ Could not find worker-1 node${NC}"
    else
        echo -e "${RED}✗ worker-1 is NOT Ready (status: $NODE_STATUS)${NC}"
    fi
else
    echo -e "${RED}This script should be run on either worker-1 or master-1${NC}"
    exit 1
fi

echo -e "\n${YELLOW}=== Test completed ===${NC}"