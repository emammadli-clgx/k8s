#!/bin/bash
# Script: test-etcd.sh
# Purpose: Test etcd cluster functionality
# Run on: master-1 (after both masters have etcd running)

set -e

echo "=== Testing etcd Cluster ==="

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

FAILED=0

# Check etcd binary exists
echo "Checking etcd installation..."
if command -v etcd &> /dev/null && command -v etcdctl &> /dev/null; then
    echo -e "  etcd binaries: ${GREEN}INSTALLED${NC}"
    etcd --version | head -1
    etcdctl version | head -1
else
    echo -e "  etcd binaries: ${RED}NOT FOUND${NC}"
    ((FAILED++))
fi

# Check etcd service on master-1
echo -e "\nChecking etcd service on master-1..."
if sudo systemctl is-active --quiet etcd; then
    echo -e "  Service status: ${GREEN}ACTIVE${NC}"
else
    echo -e "  Service status: ${RED}INACTIVE${NC}"
    ((FAILED++))
fi

# Check etcd service on master-2
echo -e "\nChecking etcd service on master-2..."
if ssh vagrant@master-2 "sudo systemctl is-active --quiet etcd" 2>/dev/null; then
    echo -e "  Service status: ${GREEN}ACTIVE${NC}"
else
    echo -e "  Service status: ${RED}INACTIVE${NC}"
    ((FAILED++))
fi

# Check etcd cluster members
echo -e "\nChecking etcd cluster members..."
MEMBER_OUTPUT=$(sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key 2>&1)

if [ $? -eq 0 ]; then
    echo -e "  Cluster access: ${GREEN}OK${NC}"
    echo "$MEMBER_OUTPUT" | while read line; do
        echo "  $line"
    done
    
    # Check both members are present
    if echo "$MEMBER_OUTPUT" | grep -q "master-1" && echo "$MEMBER_OUTPUT" | grep -q "master-2"; then
        echo -e "  Both members present: ${GREEN}YES${NC}"
    else
        echo -e "  Both members present: ${RED}NO${NC}"
        ((FAILED++))
    fi
else
    echo -e "  Cluster access: ${RED}FAILED${NC}"
    ((FAILED++))
fi

# Test etcd functionality
echo -e "\nTesting etcd functionality..."
TEST_KEY="test/key"
TEST_VALUE="Hello etcd"

# Write test value
sudo ETCDCTL_API=3 etcdctl put ${TEST_KEY} "${TEST_VALUE}" \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key &>/dev/null

if [ $? -eq 0 ]; then
    echo -e "  Write test: ${GREEN}PASS${NC}"
else
    echo -e "  Write test: ${RED}FAIL${NC}"
    ((FAILED++))
fi

# Read test value
READ_VALUE=$(sudo ETCDCTL_API=3 etcdctl get ${TEST_KEY} \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key 2>/dev/null | tail -1)

if [ "$READ_VALUE" == "$TEST_VALUE" ]; then
    echo -e "  Read test: ${GREEN}PASS${NC}"
else
    echo -e "  Read test: ${RED}FAIL${NC}"
    ((FAILED++))
fi

# Clean up test key
sudo ETCDCTL_API=3 etcdctl del ${TEST_KEY} \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key &>/dev/null

# Check cluster health
echo -e "\nChecking cluster health..."
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://192.168.5.11:2379,https://192.168.5.12:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key

# Summary
echo -e "\n=== Test Summary ==="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    echo "etcd cluster is running correctly on both master nodes."
else
    echo -e "${RED}$FAILED test(s) failed!${NC}"
    exit 1
fi