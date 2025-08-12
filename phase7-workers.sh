#!/bin/bash

#===============================================================================
# PHASE 7: BOOTSTRAP KUBERNETES WORKERS
# Configure and start worker nodes to join the cluster
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
if [[ ! -f "${SCRIPT_DIR}/.phase6_status" ]]; then
    log_error "Phase 6 not completed. Please run phase6-control-plane.sh first."
    exit 1
fi

log "=== PHASE 7: Bootstrap Kubernetes Workers ==="

# Function to configure worker node
configure_worker() {
    local node=$1
    local node_ip=$2
    
    log "Configuring worker node: $node ($node_ip)"
    
    # Create worker directories
    ssh vagrant@${node} "
        sudo mkdir -p /etc/cni/net.d /opt/cni/bin /var/lib/kubelet /var/lib/kube-proxy /var/lib/kubernetes /var/run/kubernetes
    " || {
        log_error "Failed to create directories on $node"
        return 1
    }
    
    # Copy worker binaries
    log "Copying worker binaries to $node..."
    scp kubectl kube-proxy kubelet vagrant@${node}:~/ || {
        log_error "Failed to copy binaries to $node"
        return 1
    }
    
    # Install binaries
    ssh vagrant@${node} "
        chmod +x kubectl kube-proxy kubelet &&
        sudo mv kubectl kube-proxy kubelet /usr/local/bin/
    " || {
        log_error "Failed to install binaries on $node"
        return 1
    }
    
    # Copy certificates and kubeconfigs
    log "Copying certificates and kubeconfigs to $node..."
    scp ${CONFIG_DIR}/${node}-key.pem ${CONFIG_DIR}/${node}.pem ${CONFIG_DIR}/ca.pem vagrant@${node}:~/ || {
        log_error "Failed to copy certificates to $node"
        return 1
    }
    
    scp ${CONFIG_DIR}/${node}.kubeconfig ${CONFIG_DIR}/kube-proxy.kubeconfig vagrant@${node}:~/ || {
        log_error "Failed to copy kubeconfigs to $node"
        return 1
    }
    
    # Move certificates to proper location
    ssh vagrant@${node} "
        sudo mv ${node}-key.pem ${node}.pem ca.pem /var/lib/kubelet/ &&
        sudo mv ${node}.kubeconfig /var/lib/kubelet/kubeconfig &&
        sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/
    " || {
        log_error "Failed to move certificates on $node"
        return 1
    }
    
    # Create kubelet configuration
    log "Creating kubelet configuration for $node..."
    ssh vagrant@${node} "
        cat > kubelet-config.yaml << EOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /var/lib/kubelet/ca.pem
authorization:
  mode: Webhook
clusterDomain: cluster.local
clusterDNS:
  - 10.32.0.10
podCIDR: ${CLUSTER_CIDR}
resolvConf: /run/systemd/resolve/resolv.conf
runtimeRequestTimeout: 15m
tlsCertFile: /var/lib/kubelet/${node}.pem
tlsPrivateKeyFile: /var/lib/kubelet/${node}-key.pem
registerNode: true
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
EOF
        sudo mv kubelet-config.yaml /var/lib/kubelet/
    " || {
        log_error "Failed to create kubelet config on $node"
        return 1
    }
    
    # Create kubelet systemd service
    log "Creating kubelet systemd service for $node..."
    ssh vagrant@${node} "
        cat > kubelet.service << 'EOF'
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        sudo mv kubelet.service /etc/systemd/system/
    " || {
        log_error "Failed to create kubelet service on $node"
        return 1
    }
    
    # Create kube-proxy configuration
    log "Creating kube-proxy configuration for $node..."
    ssh vagrant@${node} "
        cat > kube-proxy-config.yaml << EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: /var/lib/kube-proxy/kube-proxy.kubeconfig
mode: iptables
clusterCIDR: ${CLUSTER_CIDR}
EOF
        sudo mv kube-proxy-config.yaml /var/lib/kube-proxy/
    " || {
        log_error "Failed to create kube-proxy config on $node"
        return 1
    }
    
    # Create kube-proxy systemd service
    log "Creating kube-proxy systemd service for $node..."
    ssh vagrant@${node} "
        cat > kube-proxy.service << 'EOF'
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        sudo mv kube-proxy.service /etc/systemd/system/
    " || {
        log_error "Failed to create kube-proxy service on $node"
        return 1
    }
    
    # Start kubelet and kube-proxy services
    log "Starting kubelet and kube-proxy services on $node..."
    ssh vagrant@${node} "
        sudo systemctl daemon-reload &&
        sudo systemctl enable kubelet kube-proxy &&
        sudo systemctl start kubelet kube-proxy
    " || {
        log_error "Failed to start services on $node"
        return 1
    }
    
    # Wait for services to be active
    log "Waiting for services to be active on $node..."
    for service in kubelet kube-proxy; do
        retry_count=0
        max_retries=30
        while [[ $retry_count -lt $max_retries ]]; do
            if ssh vagrant@${node} "sudo systemctl is-active $service >/dev/null 2>&1"; then
                log_success "$service is active on $node"
                break
            else
                log_warn "$service not yet active on $node, retrying... ($((retry_count + 1))/$max_retries)"
                sleep 10
                ((retry_count++))
            fi
        done
        
        if [[ $retry_count -eq $max_retries ]]; then
            log_error "$service failed to become active on $node"
            ssh vagrant@${node} "sudo systemctl status $service --no-pager" || true
            return 1
        fi
    done
    
    log_success "Worker node $node configured successfully"
    return 0
}

# Download Kubernetes worker binaries if not present
log "Checking for Kubernetes worker binaries..."
for binary in kubectl kube-proxy kubelet; do
    if [[ ! -f "$binary" ]]; then
        log "Downloading $binary..."
        wget -q --show-progress --https-only --timestamping \
            "https://storage.googleapis.com/kubernetes-release/release/v${KUBERNETES_VERSION}/bin/linux/amd64/$binary" || {
            log_error "Failed to download $binary"
            exit 1
        }
        chmod +x $binary
        log_success "$binary downloaded"
    else
        log_success "$binary already exists"
    fi
done

# Configure worker nodes
log "Configuring worker nodes..."
for i in "${!WORKERS[@]}"; do
    WORKER_NAME="${WORKERS[$i]}"
    WORKER_IP="${WORKER_IPS[$i]}"
    
    log "Testing SSH connectivity to $WORKER_NAME ($WORKER_IP)..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes vagrant@${WORKER_NAME} exit 2>/dev/null; then
        log_success "SSH connection to $WORKER_NAME successful"
    else
        log_error "Cannot connect to $WORKER_NAME via SSH"
        exit 1
    fi
    
    if configure_worker "$WORKER_NAME" "$WORKER_IP"; then
        log_success "Worker $WORKER_NAME configured successfully"
    else
        log_error "Failed to configure worker $WORKER_NAME"
        exit 1
    fi
done

# Verify nodes are joining the cluster
log "Verifying nodes are joining the cluster..."
sleep 30  # Give nodes time to register

# Check with kubectl if available
if [[ -f "./kubectl" ]]; then
    KUBECTL_CMD="./kubectl"
elif command -v kubectl >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
else
    log_warn "kubectl not found, skipping node verification"
    KUBECTL_CMD=""
fi

if [[ -n "$KUBECTL_CMD" ]]; then
    KUBECONFIG_FILE="${CONFIG_DIR}/admin.kubeconfig"
    
    log "Checking cluster nodes..."
    if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes; then
        log_success "Nodes visible in cluster"
        
        # Wait for nodes to be Ready
        log "Waiting for worker nodes to be Ready..."
        for worker in "${WORKERS[@]}"; do
            retry_count=0
            max_retries=30
            while [[ $retry_count -lt $max_retries ]]; do
                node_status=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get node "$worker" --no-headers 2>/dev/null | awk '{print $2}' || echo "NotFound")
                if [[ "$node_status" == "Ready" ]]; then
                    log_success "Worker node $worker is Ready"
                    break
                elif [[ "$node_status" == "NotFound" ]]; then
                    log_warn "Worker node $worker not yet registered, waiting... ($((retry_count + 1))/$max_retries)"
                else
                    log_warn "Worker node $worker status: $node_status, waiting... ($((retry_count + 1))/$max_retries)"
                fi
                sleep 10
                ((retry_count++))
            done
            
            if [[ $retry_count -eq $max_retries ]]; then
                log_error "Worker node $worker did not become Ready in time"
                ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" describe node "$worker" || true
                exit 1
            fi
        done
    else
        log_warn "Could not verify cluster nodes with kubectl"
    fi
fi

# Verify worker services are running
log "Verifying worker services..."
for worker in "${WORKERS[@]}"; do
    log "Checking services on $worker..."
    for service in kubelet kube-proxy; do
        if ssh vagrant@${worker} "sudo systemctl is-active $service >/dev/null 2>&1"; then
            log_success "$service is running on $worker"
        else
            log_error "$service is not running on $worker"
            ssh vagrant@${worker} "sudo systemctl status $service --no-pager" || true
            exit 1
        fi
    done
done

# Create status file
echo "PHASE7_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase7_status"
for worker in "${WORKERS[@]}"; do
    echo "WORKER_${worker^^}_CONFIGURED=true" >> "${SCRIPT_DIR}/.phase7_status"
done

log_success "Phase 7: Kubernetes workers bootstrap completed successfully!"
log "Worker nodes are now part of the cluster and ready to run workloads."

exit 0
