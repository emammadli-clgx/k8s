#!/bin/bash

#===============================================================================
# PHASE 5: ETCD CLUSTER SETUP
# Bootstraps etcd cluster on master nodes
#===============================================================================

# Exit on any erro
set -euo pipefail

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $1" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"
}

# Load common configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    source "${SCRIPT_DIR}/config.env"
else
    log_error "config.env file not found. Please run setup.sh first."
    exit 1
fi

# Check if previous phases completed
if [[ ! -f "${SCRIPT_DIR}/.phase4_status" ]]; then
    log_error "Phase 4 not completed. Please run phase4-encryption.sh first."
    exit 1
fi

log "=== PHASE 5: Bootstrapping etcd Cluster ==="
log "etcd Version: ${ETCD_VERSION}"
log "Master nodes: ${MASTER_NODES[*]}"

# Function to bootstrap etcd on a single node
bootstrap_etcd_node() {
    local node=$1
    local node_ip=$2
    
    log "Setting up etcd on ${node} (${node_ip})..."
    
    # Check SSH connectivity
    if ! ssh -o ConnectTimeout=5 vagrant@${node} "echo 'SSH test successful'" >/dev/null 2>&1; then
        log_error "Cannot SSH to ${node}"
        return 1
    fi
    
    # Download and install etcd
    ssh vagrant@${node} "
        # Check if etcd is already installed
        if [[ -f /usr/local/bin/etcd ]]; then
            echo 'etcd already installed, checking version...'
            etcd_version=\\\$(/usr/local/bin/etcd --version | head -n1 | cut -d' ' -f3)
            if [[ \\\"\\\$etcd_version\\\" == \\\"${ETCD_VERSION}\\\" ]]; then
                echo '✓ etcd ${ETCD_VERSION} already installed'
                exit 0
            else
                echo 'Different etcd version installed, updating...'
            fi
        fi
        
        echo 'Downloading etcd ${ETCD_VERSION}...'
        wget -q --show-progress --https-only --timestamping \\
            \"https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz\" || exit 1
        
        echo 'Extracting etcd...'
        tar -xf etcd-${ETCD_VERSION}-linux-amd64.tar.gz || exit 1
        
        echo 'Installing etcd binaries...'
        sudo cp etcd-${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/ || exit 1
        
        echo 'Verifying etcd installation...'
        etcd --version || exit 1
        etcdctl version || exit 1
        
        echo '✓ etcd installation completed'
    " || {
        log_error "Failed to install etcd on ${node}"
        return 1
    }
    
    # Create etcd service file
    local etcd_name="$node"
    local initial_cluster=""
    for i in "${!MASTER_NODES[@]}"; do
        if [[ $i -gt 0 ]]; then
            initial_cluster+=","
        fi
        initial_cluster+="${MASTER_NODES[$i]}=https://${MASTER_IPS[$i]}:2380"
    done
    
    log "Creating etcd service for ${node}..."
    cat > "/tmp/etcd-${node}.service" <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${etcd_name} \\
  --cert-file=/etc/etcd/etcd-server.pem \\
  --key-file=/etc/etcd/etcd-server-key.pem \\
  --peer-cert-file=/etc/etcd/etcd-server.pem \\
  --peer-key-file=/etc/etcd/etcd-server-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${node_ip}:2380 \\
  --listen-peer-urls https://${node_ip}:2380 \\
  --listen-client-urls https://${node_ip}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${node_ip}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster ${initial_cluster} \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd \\
  --snapshot-count=10000 \\
  --heartbeat-interval=100 \\
  --election-timeout=1000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Copy service file to node
    scp "/tmp/etcd-${node}.service" vagrant@${node}:/tmp/etcd.service || {
        log_error "Failed to copy etcd service file to ${node}"
        return 1
    }
    
    # Install service file and setup directories
    ssh vagrant@${node} "
        echo 'Installing etcd service...'
        sudo mv /tmp/etcd.service /etc/systemd/system/etcd.service || exit 1
        
        echo 'Creating etcd directories...'
        sudo mkdir -p /etc/etcd /var/lib/etcd || exit 1
        sudo chmod 700 /var/lib/etcd || exit 1
        
        echo 'Reloading systemd...'
        sudo systemctl daemon-reload || exit 1
        
        echo 'Enabling etcd service...'
        sudo systemctl enable etcd || exit 1
        
        echo '✓ etcd service setup completed on ${node}'
    " || {
        log_error "Failed to setup etcd service on ${node}"
        return 1
    }
    
    log "✓ etcd setup completed on ${node}"
    return 0
}

# Copy certificates to all master nodes
log "Copying etcd certificates to master nodes..."
for i in "${!MASTER_NODES[@]}"; do
    node=${MASTER_NODES[$i]}
    
    log "Copying certificates to ${node}..."
    
    # Check if certificates exist
    if [[ ! -f "${CERT_DIR}/ca.pem" ]] || [[ ! -f "${CERT_DIR}/etcd-server-key.pem" ]] || [[ ! -f "${CERT_DIR}/etcd-server.pem" ]]; then
        log_error "etcd certificates not found in ${CERT_DIR}"
        exit 1
    fi
    
    # Copy certificates
    scp "${CERT_DIR}/ca.pem" "${CERT_DIR}/etcd-server-key.pem" "${CERT_DIR}/etcd-server.pem" vagrant@${node}:~/ || {
        log_error "Failed to copy certificates to ${node}"
        exit 1
    }
    
    # Move certificates to proper location
    ssh vagrant@${node} "
        sudo mkdir -p /etc/etcd || exit 1
        sudo mv ~/ca.pem ~/etcd-server-key.pem ~/etcd-server.pem /etc/etcd/ || exit 1
        sudo chmod 600 /etc/etcd/etcd-server-key.pem || exit 1
        echo '✓ Certificates installed on ${node}'
    " || {
        log_error "Failed to install certificates on ${node}"
        exit 1
    }
    
    log "✓ Certificates copied to ${node}"
done

# Bootstrap etcd on all nodes (prepare services)
for i in "${!MASTER_NODES[@]}"; do
    node=${MASTER_NODES[$i]}
    node_ip=${MASTER_IPS[$i]}
    
    if ! bootstrap_etcd_node "${node}" "${node_ip}"; then
        log_error "Failed to bootstrap etcd on ${node}"
        exit 1
    fi
done

# Start etcd services simultaneously (required for cluster formation)
log "Starting etcd services on all nodes simultaneously..."
for i in "${!MASTER_NODES[@]}"; do
    node=${MASTER_NODES[$i]}
    
    log "Starting etcd on ${node}..."
    ssh vagrant@${node} "
        # Clean any existing etcd data
        sudo rm -rf /var/lib/etcd/member 2>/dev/null || true
        
        echo 'Starting etcd service (will wait for cluster peers)...'
        sudo systemctl start etcd &
        
        echo '✓ etcd start command issued on ${node}'
    " || {
        log_error "Failed to start etcd on ${node}"
        exit 1
    }
    
    # Small delay between starts
    sleep 2
done

# Wait for etcd cluster to form
log "Waiting for etcd cluster to form and stabilize..."
sleep 15

# Verify etcd cluster health
log "Verifying etcd cluster health..."
retry_count=0
max_retries=10

while [[ $retry_count -lt $max_retries ]]; do
    log "Checking etcd cluster health (attempt $((retry_count + 1))/${max_retries})..."
    
    # Try to check cluster health from master-1
    if ssh vagrant@master-1 "
        sudo ETCDCTL_API=3 etcdctl member list \\
            --endpoints=https://127.0.0.1:2379 \\
            --cacert=/etc/etcd/ca.crt \\
            --cert=/etc/etcd/etcd-server.crt \\
            --key=/etc/etcd/etcd-server.key 2>/dev/null
    "; then
        log_success "etcd cluster is healthy!"
        break
    fi
    
    ((retry_count++))
    if [[ $retry_count -eq $max_retries ]]; then
        log_error "etcd cluster failed to become healthy after ${max_retries} attempts"
        
        # Show detailed status from all nodes
        for node in "${MASTER_NODES[@]}"; do
            log "etcd status on ${node}:"
            ssh vagrant@${node} "
                echo 'Service status:'
                sudo systemctl is-active etcd || echo 'INACTIVE'
                echo 'Recent logs:'
                sudo journalctl -u etcd --no-pager -n 10 --since '5 minutes ago' || true
            "
        done
        
        exit 1
    fi
    
    log "Waiting 10 seconds before retry..."
    sleep 10
done

# Final health check and member list
log "Final etcd cluster verification..."
ssh vagrant@master-1 "
    echo 'Cluster member list:'
    sudo ETCDCTL_API=3 etcdctl member list \\
        --endpoints=https://127.0.0.1:2379 \\
        --cacert=/etc/etcd/ca.crt \\
        --cert=/etc/etcd/etcd-server.crt \\
        --key=/etc/etcd/etcd-server.key
        
    echo
    echo 'Endpoint health:'
    sudo ETCDCTL_API=3 etcdctl endpoint health \\
        --endpoints=https://192.168.5.11:2379,https://192.168.5.12:2379 \\
        --cacert=/etc/etcd/ca.crt \\
        --cert=/etc/etcd/etcd-server.crt \\
        --key=/etc/etcd/etcd-server.key
" || {
    log_error "Final etcd verification failed"
    exit 1
}

# Clean up temporary files
rm -f /tmp/etcd-*.service

# Create status file
echo "PHASE5_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase5_status"
echo "ETCD_VERSION=${ETCD_VERSION}" >> "${SCRIPT_DIR}/.phase5_status"
echo "ETCD_NODES=${MASTER_NODES[*]}" >> "${SCRIPT_DIR}/.phase5_status"

log_success "Phase 5: etcd cluster setup completed successfully"
log ""
log "etcd cluster is now running and healthy on all master nodes"
log "Next step: Run phase6-control-plane.sh"

exit 0
