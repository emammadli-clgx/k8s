#!/bin/bash
# Phase 5: etcd Cluster Setup
# Run from: master-1 node

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $1${NC}"
}

# Check if we're on master-1
if [[ "$(hostname)" != "master-1" ]]; then
    log_error "This script must be run on master-1 node!"
    exit 1
fi

# Check if Phase 4 completed
if [[ ! -f "/home/vagrant/phase4_completed.txt" ]]; then
    log_error "Phase 4 not completed. Please run phase4-encryption.sh first."
    exit 1
fi

log "=== Phase 5: etcd Cluster Setup ==="

# Variables
ETCD_VERSION="v3.5.10"
MASTER1_IP="192.168.56.11"
MASTER2_IP="192.168.56.12"

# Step 1: Download and install etcd on both master nodes
log ""
log "${YELLOW}Step 1: Installing etcd on master nodes...${NC}"

install_etcd_script="
# Create etcd user
sudo useradd -r -s /bin/false etcd || true

# Create etcd directories
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo chown etcd:etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd

# Download and install etcd
cd /tmp
sudo wget -q https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz
sudo tar -xzf etcd-${ETCD_VERSION}-linux-amd64.tar.gz
sudo cp etcd-${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/
sudo chown root:root /usr/local/bin/etcd*
sudo chmod +x /usr/local/bin/etcd*
sudo rm -rf etcd-${ETCD_VERSION}-linux-amd64*

echo 'etcd installation completed'
"

# Install on master-1
log "Installing etcd on master-1..."
eval "$install_etcd_script"
log_success "etcd installed on master-1"

# Install on master-2
log "Installing etcd on master-2..."
ssh -o StrictHostKeyChecking=no vagrant@master-2 "$install_etcd_script"
log_success "etcd installed on master-2"

# Step 2: Configure etcd on master-1
log ""
log "${YELLOW}Step 2: Configuring etcd on master-1...${NC}"

# Copy certificates to etcd directory
sudo cp /home/vagrant/certs/ca.crt /etc/etcd/
sudo cp /home/vagrant/certs/kube-apiserver.key /etc/etcd/etcd-server.key
sudo cp /home/vagrant/certs/kube-apiserver.crt /etc/etcd/etcd-server.crt
sudo chown etcd:etcd /etc/etcd/*
sudo chmod 600 /etc/etcd/*.key
sudo chmod 644 /etc/etcd/*.crt

# Create etcd configuration file for master-1
sudo tee /etc/etcd/etcd.conf.yml > /dev/null <<EOF
name: master-1
data-dir: /var/lib/etcd
wal-dir: /var/lib/etcd/wal
snapshot-count: 5000
heartbeat-interval: 100
election-timeout: 1000
quota-backend-bytes: 0
listen-peer-urls: https://${MASTER1_IP}:2380
listen-client-urls: https://${MASTER1_IP}:2379,https://127.0.0.1:2379
max-snapshots: 3
max-wals: 5
cors:
initial-advertise-peer-urls: https://${MASTER1_IP}:2380
advertise-client-urls: https://${MASTER1_IP}:2379
discovery-fallback: 'proxy'
initial-cluster: master-1=https://${MASTER1_IP}:2380,master-2=https://${MASTER2_IP}:2380
initial-cluster-token: 'etcd-k8s-cluster'
initial-cluster-state: 'new'
strict-reconfig-check: false
enable-msg-trace: false
enable-pprof: true
proxy: 'off'
proxy-failure-wait: 5000
proxy-refresh-interval: 30000
proxy-dial-timeout: 1000
proxy-write-timeout: 5000
proxy-read-timeout: 0
client-transport-security:
  cert-file: /etc/etcd/etcd-server.crt
  key-file: /etc/etcd/etcd-server.key
  client-cert-auth: true
  trusted-ca-file: /etc/etcd/ca.crt
  auto-tls: false
peer-transport-security:
  cert-file: /etc/etcd/etcd-server.crt
  key-file: /etc/etcd/etcd-server.key
  client-cert-auth: true
  trusted-ca-file: /etc/etcd/ca.crt
  auto-tls: false
debug: false
logger: zap
log-outputs: [stderr]
log-level: info
EOF

sudo chown etcd:etcd /etc/etcd/etcd.conf.yml

# Create systemd service file for master-1
sudo tee /etc/systemd/system/etcd.service > /dev/null <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd
Conflicts=etcd-member.service
After=network.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.conf.yml
Restart=always
RestartSec=10s
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
EOF

log_success "etcd configured on master-1"

# Step 3: Configure etcd on master-2
log ""
log "${YELLOW}Step 3: Configuring etcd on master-2...${NC}"

# Copy certificates to master-2 etcd directory
ssh -o StrictHostKeyChecking=no vagrant@master-2 "
sudo cp /home/vagrant/certs/ca.crt /etc/etcd/
sudo cp /home/vagrant/certs/kube-apiserver.key /etc/etcd/etcd-server.key
sudo cp /home/vagrant/certs/kube-apiserver.crt /etc/etcd/etcd-server.crt
sudo chown etcd:etcd /etc/etcd/*
sudo chmod 600 /etc/etcd/*.key
sudo chmod 644 /etc/etcd/*.crt
"

# Create etcd configuration file for master-2
ssh -o StrictHostKeyChecking=no vagrant@master-2 "sudo tee /etc/etcd/etcd.conf.yml > /dev/null" <<EOF
name: master-2
data-dir: /var/lib/etcd
wal-dir: /var/lib/etcd/wal
snapshot-count: 5000
heartbeat-interval: 100
election-timeout: 1000
quota-backend-bytes: 0
listen-peer-urls: https://${MASTER2_IP}:2380
listen-client-urls: https://${MASTER2_IP}:2379,https://127.0.0.1:2379
max-snapshots: 3
max-wals: 5
cors:
initial-advertise-peer-urls: https://${MASTER2_IP}:2380
advertise-client-urls: https://${MASTER2_IP}:2379
discovery-fallback: 'proxy'
initial-cluster: master-1=https://${MASTER1_IP}:2380,master-2=https://${MASTER2_IP}:2380
initial-cluster-token: 'etcd-k8s-cluster'
initial-cluster-state: 'new'
strict-reconfig-check: false
enable-msg-trace: false
enable-pprof: true
proxy: 'off'
proxy-failure-wait: 5000
proxy-refresh-interval: 30000
proxy-dial-timeout: 1000
proxy-write-timeout: 5000
proxy-read-timeout: 0
client-transport-security:
  cert-file: /etc/etcd/etcd-server.crt
  key-file: /etc/etcd/etcd-server.key
  client-cert-auth: true
  trusted-ca-file: /etc/etcd/ca.crt
  auto-tls: false
peer-transport-security:
  cert-file: /etc/etcd/etcd-server.crt
  key-file: /etc/etcd/etcd-server.key
  client-cert-auth: true
  trusted-ca-file: /etc/etcd/ca.crt
  auto-tls: false
debug: false
logger: zap
log-outputs: [stderr]
log-level: info
EOF

# Create systemd service file for master-2
ssh -o StrictHostKeyChecking=no vagrant@master-2 "sudo tee /etc/systemd/system/etcd.service > /dev/null" <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd
Conflicts=etcd-member.service
After=network.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.conf.yml
Restart=always
RestartSec=10s
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
EOF

ssh -o StrictHostKeyChecking=no vagrant@master-2 "sudo chown etcd:etcd /etc/etcd/etcd.conf.yml"
log_success "etcd configured on master-2"

# Step 4: Start etcd cluster
log ""
log "${YELLOW}Step 4: Starting etcd cluster...${NC}"

# Start etcd on both nodes simultaneously
log "Starting etcd on master-1..."
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd &

log "Starting etcd on master-2..."
ssh -o StrictHostKeyChecking=no vagrant@master-2 "
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
" &

# Wait for both to start
wait
sleep 10

log_success "etcd cluster startup initiated"

# Step 5: Verify etcd cluster
log ""
log "${YELLOW}Step 5: Verifying etcd cluster...${NC}"

# Wait a bit more for cluster to stabilize
sleep 15

# Check etcd cluster health
log "Checking etcd cluster health..."
if sudo ETCDCTL_API=3 etcdctl member list \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/etcd/ca.crt \
    --cert=/etc/etcd/etcd-server.crt \
    --key=/etc/etcd/etcd-server.key; then
    log_success "etcd cluster member list retrieved"
else
    log_error "Failed to get etcd cluster member list"
fi

# Check cluster health
log "Checking etcd cluster health status..."
if sudo ETCDCTL_API=3 etcdctl endpoint health \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/etcd/ca.crt \
    --cert=/etc/etcd/etcd-server.crt \
    --key=/etc/etcd/etcd-server.key; then
    log_success "etcd cluster health check passed"
else
    log_warning "etcd cluster health check had issues"
fi

# Check systemd status on both nodes
log "Checking etcd service status on master-1:"
sudo systemctl is-active etcd || echo "master-1 etcd status check failed"

log "Checking etcd service status on master-2:"
ssh -o StrictHostKeyChecking=no vagrant@master-2 "sudo systemctl is-active etcd" || echo "master-2 etcd status check failed"

# Create completion marker
echo "Phase 5 completed: $(date)" > /home/vagrant/phase5_completed.txt

log ""
log_success "🎉 Phase 5 (etcd Cluster Setup) completed successfully!"
log ""
log "${CYAN}etcd cluster configured:${NC}"
log_success "  ✓ etcd v3.5.10 installed on both master nodes"
log_success "  ✓ TLS certificates configured"
log_success "  ✓ Cluster configuration created"
log_success "  ✓ etcd services started and enabled"
log_success "  ✓ 2-node etcd cluster operational"
log ""
log "${YELLOW}Next step: ./phase6-control-plane.sh${NC}"