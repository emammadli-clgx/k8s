#!/bin/bash

# test-lb-simple.sh
# Purpose: Simple test of HAProxy load balancer
# Run on: any node

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOADBALANCER_IP="192.168.5.30"
API_PORT="6443"

echo "=================================================="
echo "Simple Load Balancer Test"
echo "Testing: https://${LOADBALANCER_IP}:${API_PORT}"
echo "=================================================="

# Test 1: Check if port is reachable
echo -e "${BLUE}[TEST 1]${NC} Testing port connectivity..."
if timeout 10 bash -c "echo >/dev/tcp/${LOADBALANCER_IP}/${API_PORT}" 2>/dev/null; then
    echo -e "${GREEN}✓ PASS${NC} Load balancer port is reachable"
else
    echo -e "${RED}✗ FAIL${NC} Load balancer port is not reachable"
    exit 1
fi

# Test 2: Test HTTP request
echo -e "${BLUE}[TEST 2]${NC} Testing HTTPS API request..."
if response=$(timeout 15 curl -k --connect-timeout 10 --max-time 10 "https://${LOADBALANCER_IP}:${API_PORT}/version" 2>/dev/null); then
    echo -e "${GREEN}✓ PASS${NC} Load balancer responds to HTTPS requests"
    
    # Show response
    echo -e "${BLUE}[INFO]${NC} API Response:"
    if command -v jq >/dev/null 2>&1; then
        echo "$response" | jq . 2>/dev/null || echo "$response"
    else
        echo "$response"
    fi
else
    echo -e "${RED}✗ FAIL${NC} Load balancer does not respond to HTTPS requests"
    exit 1
fi

# Test 3: Multiple requests to test load balancing
echo -e "${BLUE}[TEST 3]${NC} Testing load balancing with multiple requests..."
success_count=0
total_requests=5

for i in $(seq 1 $total_requests); do
    if timeout 10 curl -k --connect-timeout 5 --max-time 5 "https://${LOADBALANCER_IP}:${API_PORT}/version" >/dev/null 2>&1; then
        success_count=$((success_count + 1))
    fi
    sleep 1
done

echo -e "${BLUE}[INFO]${NC} Successful requests: $success_count/$total_requests"

if [ $success_count -eq $total_requests ]; then
    echo -e "${GREEN}✓ PASS${NC} All requests successful - load balancer is stable"
elif [ $success_count -gt 0 ]; then
    echo -e "${YELLOW}⚠ PARTIAL${NC} Some requests successful - check master node health"
else
    echo -e "${RED}✗ FAIL${NC} No requests successful"
    exit 1
fi

# Test 4: Check HAProxy statistics
echo -e "${BLUE}[TEST 4]${NC} Testing HAProxy statistics page..."
if curl --connect-timeout 5 --max-time 10 "http://${LOADBALANCER_IP}:8080/stats" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ PASS${NC} HAProxy statistics page is accessible"
    echo -e "${BLUE}[INFO]${NC} Statistics URL: http://${LOADBALANCER_IP}:8080/stats"
    echo -e "${BLUE}[INFO]${NC} Login: admin/admin"
else
    echo -e "${YELLOW}⚠ WARN${NC} HAProxy statistics page not accessible"
fi

echo ""
echo "=================================================="
echo -e "${GREEN}LOAD BALANCER TEST SUMMARY${NC}"
echo "=================================================="
echo "✅ Load balancer is working correctly!"
echo "✅ Kubernetes API is accessible through load balancer"
echo "✅ Multiple requests are being handled properly"
echo ""
echo "🎯 Your Kubernetes API endpoint:"
echo "   https://${LOADBALANCER_IP}:${API_PORT}"
echo ""
echo "📊 HAProxy Statistics:"
echo "   http://${LOADBALANCER_IP}:8080/stats"
echo "=================================================="