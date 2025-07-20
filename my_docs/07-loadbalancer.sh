#!/bin/bash

# setup-loadbalancer-working.sh
# Purpose: Working HAProxy setup for Kubernetes API servers
# Run on: loadbalancer node (192.168.5.30)

set -euo pipefail

# Configuration
LOADBALANCER_IP="192.168.5.30"
MASTER1_IP="192.168.5.11"
MASTER2_IP="192.168.5.12"
API_PORT="6443"

echo "=================================================="
echo "Setting up Working HAProxy Load Balancer"
echo "=================================================="

# Stop HAProxy
sudo systemctl stop haproxy 2>/dev/null || true

# Create working HAProxy configuration
sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<EOF
global
    log stdout local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    mode tcp
    log global
    option tcplog
    option dontlognull
    option log-health-checks
    retries 3
    timeout connect 10s
    timeout client 1m
    timeout server 1m
    timeout check 10s

# Kubernetes API Server Frontend
frontend kubernetes-api
    bind ${LOADBALANCER_IP}:${API_PORT}
    mode tcp
    option tcplog
    default_backend kubernetes-master-nodes

# Kubernetes API Server Backend
backend kubernetes-master-nodes
    mode tcp
    balance roundrobin
    option log-health-checks
    
    # Simple TCP connect health check
    server master-1 ${MASTER1_IP}:${API_PORT} check inter 5s fall 3 rise 2
    server master-2 ${MASTER2_IP}:${API_PORT} check inter 5s fall 3 rise 2

# HAProxy Statistics
listen stats
    bind ${LOADBALANCER_IP}:8080
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE
    stats hide-version
    stats realm HAProxy\ Statistics
    stats auth admin:admin
EOF

# Test configuration
echo "Testing HAProxy configuration..."
if sudo haproxy -c -f /etc/haproxy/haproxy.cfg; then
    echo "✓ Configuration is valid"
else
    echo "✗ Configuration is invalid"
    exit 1
fi

# Start HAProxy
echo "Starting HAProxy..."
sudo systemctl enable haproxy
sudo systemctl start haproxy

# Wait and verify
sleep 10

if sudo systemctl is-active --quiet haproxy; then
    echo "✓ HAProxy service is running"
else
    echo "✗ HAProxy service failed to start"
    exit 1
fi

# Test the load balancer
echo "Testing load balancer..."
if timeout 15 curl -k "https://${LOADBALANCER_IP}:${API_PORT}/version" >/dev/null 2>&1; then
    echo "✓ Load balancer is working"
    echo ""
    echo "🎉 SUCCESS! Load balancer is ready"
    echo ""
    echo "Kubernetes API: https://${LOADBALANCER_IP}:${API_PORT}"
    echo "Statistics: http://${LOADBALANCER_IP}:8080/stats (admin/admin)"
else
    echo "⚠ Load balancer might need more time to stabilize"
    echo "Check manually with: curl -k https://${LOADBALANCER_IP}:${API_PORT}/version"
fi

echo "=================================================="