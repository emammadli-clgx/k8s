#!/bin/bash

#===============================================================================
# PHASE 6: CONTROL PLANE SETUP
# Bootstraps Kubernetes control plane components on master nodes
#===============================================================================

# Exit on any error
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
if [[ ! -f "${SCRIPT_DIR}/.phase5_status" ]]; then
    log_error "Phase 5 not completed. Please run phase5-etcd.sh first."
    exit 1
fi

log "=== PHASE 6: Bootstrapping Control Plane ==="
log "Kubernetes Version: ${KUBERNETES_VERSION}"

# Function to bootstrap control plane on a single node
bootstrap_control_plane_node() {
    local node=$1
    
    log "Setting up control plane on ${node}..."
    
    # Check SSH connectivity
    if ! ssh -o ConnectTimeout=5 vagrant@${node} "echo 'SSH test successful'" >/dev/null 2>&1; then
        log_error "Cannot SSH to ${node}"
        return 1
    fi
    
    # Download and install Kubernetes binaries
    ssh vagrant@${node} "
        # Check if binaries are already installed
        if [[ -f /usr/local/bin/kube-apiserver ]] && [[ -f /usr/local/bin/kube-controller-manager ]] && [[ -f /usr/local/bin/kube-scheduler ]]; then
            echo 'Control plane binaries already installed, checking versions...'
            api_version=\\\$(/usr/local/bin/kube-apiserver --version | cut -d' ' -f2)
            if [[ \\\"\\\$api_version\\\" == \\\"${KUBERNETES_VERSION}\\\" ]]; then
                echo '✓ Control plane ${KUBERNETES_VERSION} already installed'
                exit 0
            else
                echo 'Different version installed, updating...'
            fi
        fi
        
        echo 'Downloading Kubernetes control plane binaries...'
        wget -q --show-progress --https-only --timestamping \\
            \"https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/amd64/kube-apiserver\" \\
            \"https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/amd64/kube-controller-manager\" \\
            \"https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/amd64/kube-scheduler\" \\
            \"https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubectl\" || exit 1
        
        echo 'Installing binaries...'
        chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl || exit 1
        sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/ || exit 1
        
        echo 'Verifying installations...'
        kube-apiserver --version || exit 1
        kube-controller-manager --version || exit 1
        kube-scheduler --version || exit 1
        kubectl version --client || exit 1
        
        echo '✓ Control plane binaries installation completed'
    " || {
        log_error "Failed to install control plane binaries on ${node}"
        return 1
    }
    
    # Create directories and setup configuration
    ssh vagrant@${node} "
        echo 'Creating Kubernetes directories...'
        sudo mkdir -p /etc/kubernetes/config /var/lib/kubernetes/ || exit 1
        
        echo 'Getting internal IP...'
        INTERNAL_IP=\\\$(ip addr show enp0s8 | grep 'inet ' | awk '{print \\\$2}' | cut -d / -f 1)
        echo \"Internal IP: \\\$INTERNAL_IP\"
        
        if [[ -z \\\"\\\$INTERNAL_IP\\\" ]]; then
            echo 'Failed to get internal IP'
            exit 1
        fi
        
        echo '✓ Directories and IP configuration completed'
    " || {
        log_error "Failed to setup directories on ${node}"
        return 1
    }
    
    # Create API server service
    log "Creating kube-apiserver service on ${node}..."
    cat > "/tmp/kube-apiserver-${node}.service" <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=\${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.crt \\
  --etcd-certfile=/var/lib/kubernetes/etcd-server.crt \\
  --etcd-keyfile=/var/lib/kubernetes/etcd-server.key \\
  --etcd-servers=https://192.168.5.11:2379,https://192.168.5.12:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.crt \\
  --kubelet-client-certificate=/var/lib/kubernetes/kube-apiserver.crt \\
  --kubelet-client-key=/var/lib/kubernetes/kube-apiserver.key \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-account.crt \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account.key \\
  --service-account-issuer=https://${LOADBALANCER_ADDRESS}:6443 \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kube-apiserver.crt \\
  --tls-private-key-file=/var/lib/kubernetes/kube-apiserver.key \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Create controller manager service
    cat > "/tmp/kube-controller-manager-${node}.service" <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=${CLUSTER_CIDR} \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.crt \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca.key \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.crt \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account.key \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Create scheduler service
    cat > "/tmp/kube-scheduler-${node}.service" <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Create scheduler config
    cat > "/tmp/kube-scheduler-config-${node}.yaml" <<EOF
apiVersion: kubescheduler.config.k8s.io/v1beta3
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
leaderElection:
  leaderElect: true
EOF

    # Copy service files to node
    scp "/tmp/kube-apiserver-${node}.service" vagrant@${node}:/tmp/kube-apiserver.service || {
        log_error "Failed to copy API server service to ${node}"
        return 1
    }
    
    scp "/tmp/kube-controller-manager-${node}.service" vagrant@${node}:/tmp/kube-controller-manager.service || {
        log_error "Failed to copy controller manager service to ${node}"
        return 1
    }
    
    scp "/tmp/kube-scheduler-${node}.service" vagrant@${node}:/tmp/kube-scheduler.service || {
        log_error "Failed to copy scheduler service to ${node}"
        return 1
    }
    
    scp "/tmp/kube-scheduler-config-${node}.yaml" vagrant@${node}:/tmp/kube-scheduler.yaml || {
        log_error "Failed to copy scheduler config to ${node}"
        return 1
    }
    
    # Install service files
    ssh vagrant@${node} "
        echo 'Installing service files...'
        sudo mv /tmp/kube-apiserver.service /etc/systemd/system/ || exit 1
        sudo mv /tmp/kube-controller-manager.service /etc/systemd/system/ || exit 1
        sudo mv /tmp/kube-scheduler.service /etc/systemd/system/ || exit 1
        sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/config/ || exit 1
        
        echo 'Reloading systemd...'
        sudo systemctl daemon-reload || exit 1
        
        echo 'Enabling services...'
        sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler || exit 1
        
        echo '✓ Control plane services setup completed on ${node}'
    " || {
        log_error "Failed to setup services on ${node}"
        return 1
    }
    
    log "✓ Control plane setup completed on ${node}"
    return 0
}

# Copy certificates and configs to all master nodes
log "Copying certificates and configs to master nodes..."
for i in "${!MASTER_NODES[@]}"; do
    node=${MASTER_NODES[$i]}
    
    log "Copying files to ${node}..."
    
    # Copy certificates
    scp "${CERT_DIR}/ca.crt" "${CERT_DIR}/ca.key" "${CERT_DIR}/kube-apiserver.crt" "${CERT_DIR}/kube-apiserver.key" \
        "${CERT_DIR}/service-account.key" "${CERT_DIR}/service-account.crt" \
        "${CERT_DIR}/etcd-server.key" "${CERT_DIR}/etcd-server.crt" \
        vagrant@${node}:~/ || {
        log_error "Failed to copy certificates to ${node}"
        exit 1
    }
    
    # Copy configs
    scp "${CONFIG_DIR}/encryption-config.yaml" \
        "${CONFIG_DIR}/kube-controller-manager.kubeconfig" \
        "${CONFIG_DIR}/kube-scheduler.kubeconfig" \
        "${CONFIG_DIR}/admin.kubeconfig" \
        vagrant@${node}:~/ || {
        log_error "Failed to copy configs to ${node}"
        exit 1
    }
    
    # Move files to proper locations
    ssh vagrant@${node} "
        sudo mv ca.crt ca.key kube-apiserver.crt kube-apiserver.key \\
            service-account.key service-account.crt \\
            etcd-server.key etcd-server.crt \\
            encryption-config.yaml \\
            kube-controller-manager.kubeconfig \\
            kube-scheduler.kubeconfig /var/lib/kubernetes/ || exit 1
        
        echo '✓ Files moved to /var/lib/kubernetes/ on ${node}'
    " || {
        log_error "Failed to move files on ${node}"
        exit 1
    }
    
    log "✓ Files copied to ${node}"
done

# Bootstrap control plane on all nodes
for node in "${MASTER_NODES[@]}"; do
    if ! bootstrap_control_plane_node "${node}"; then
        log_error "Failed to bootstrap control plane on ${node}"
        exit 1
    fi
done

# Start services on all masters
log "Starting control plane services on all master nodes..."
for node in "${MASTER_NODES[@]}"; do
    log "Starting services on ${node}..."
    ssh vagrant@${node} "
        echo 'Starting control plane services...'
        sudo systemctl start kube-apiserver || exit 1
        sleep 5
        sudo systemctl start kube-controller-manager || exit 1
        sleep 2
        sudo systemctl start kube-scheduler || exit 1
        
        echo 'Verifying services are running...'
        if sudo systemctl is-active kube-apiserver kube-controller-manager kube-scheduler; then
            echo '✓ All services are running on ${node}'
        else
            echo '✗ Some services failed to start on ${node}'
            sudo systemctl status kube-apiserver kube-controller-manager kube-scheduler --no-pager
            exit 1
        fi
    " || {
        log_error "Failed to start services on ${node}"
        exit 1
    }
    
    log "✓ Services started on ${node}"
done

# Wait for API servers to be ready
log "Waiting for API servers to be ready..."
sleep 10

# Verify API server health
log "Verifying API server health..."
retry_count=0
max_retries=12

while [[ $retry_count -lt $max_retries ]]; do
    log "Testing API server connectivity (attempt $((retry_count + 1))/${max_retries})..."
    
    if curl -s --cacert "${CERT_DIR}/ca.crt" \
        --cert "${CERT_DIR}/admin.crt" \
        --key "${CERT_DIR}/admin.key" \
        "https://127.0.0.1:6443/healthz" | grep -q "ok"; then
        log_success "API server is responding to health checks!"
        break
    fi
    
    ((retry_count++))
    if [[ $retry_count -eq $max_retries ]]; then
        log_error "API server failed to become healthy after ${max_retries} attempts"
        
        # Show detailed status
        for node in "${MASTER_NODES[@]}"; do
            log "Control plane status on ${node}:"
            ssh vagrant@${node} "
                echo 'Service statuses:'
                sudo systemctl is-active kube-apiserver kube-controller-manager kube-scheduler || true
                echo 'Recent API server logs:'
                sudo journalctl -u kube-apiserver --no-pager -n 10 --since '5 minutes ago' || true
            "
        done
        
        exit 1
    fi
    
    log "Waiting 10 seconds before retry..."
    sleep 10
done

# Test API server with kubectl
log "Testing API server with kubectl..."
if ! kubectl --kubeconfig="${CONFIG_DIR}/admin.kubeconfig" get componentstatuses; then
    log_error "Failed to get component statuses"
    exit 1
fi

# Clean up temporary files
rm -f /tmp/kube-*-*.service /tmp/kube-*-*.yaml

# Create status file
echo "PHASE6_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase6_status"
echo "CONTROL_PLANE_NODES=${MASTER_NODES[*]}" >> "${SCRIPT_DIR}/.phase6_status"

log_success "Phase 6: Control plane setup completed successfully"
log ""
log "Kubernetes control plane is now running on all master nodes"
log "API server is accessible at: https://127.0.0.1:6443"
log "Next step: Run phase7-workers.sh"

exit 0
