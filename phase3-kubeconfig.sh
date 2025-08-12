#!/bin/bash

#===============================================================================
# PHASE 3: KUBECONFIG GENERATION
# Generates kubeconfig files for all components
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

# Load common configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    source "${SCRIPT_DIR}/config.env"
else
    log_error "config.env file not found. Please run setup.sh first."
    exit 1
fi

# Check if previous phases completed
if [[ ! -f "${SCRIPT_DIR}/.phase2_status" ]]; then
    log_error "Phase 2 not completed. Please run phase2-certificates.sh first."
    exit 1
fi

log "=== PHASE 3: Generating Kubeconfig Files ==="

# Change to working directory
cd "${SCRIPT_DIR}" || {
    log_error "Failed to change to script directory"
    exit 1
}

# Check if kubectl is available
if ! command -v kubectl >/dev/null 2>&1; then
    log "kubectl not found, downloading..."
    wget -O kubectl "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubectl" || {
        log_error "Failed to download kubectl"
        exit 1
    }
    chmod +x kubectl || {
        log_error "Failed to make kubectl executable"
        exit 1
    }
    KUBECTL_CMD="./kubectl"
else
    KUBECTL_CMD="kubectl"
fi

# Create configs directory
mkdir -p "${CONFIG_DIR}" || {
    log_error "Failed to create configs directory"
    exit 1
}

cd "${CONFIG_DIR}" || {
    log_error "Failed to change to configs directory"
    exit 1
}

log "Working in: $(pwd)"

# 1. Generate Worker Kubeconfigs
log "Generating worker kubeconfigs..."
for worker in worker-1 worker-2; do
    log "Creating kubeconfig for ${worker}..."
    
    if [[ -f "${worker}.kubeconfig" ]]; then
        log "✓ ${worker}.kubeconfig already exists"
        continue
    fi
    
    # Set cluster
    ${KUBECTL_CMD} config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CERT_DIR}/ca.crt" \
        --embed-certs=true \
        --server=https://${LOADBALANCER_ADDRESS}:6443 \
        --kubeconfig="${worker}.kubeconfig" || {
        log_error "Failed to set cluster for ${worker}"
        exit 1
    }
    
    # Set credentials
    ${KUBECTL_CMD} config set-credentials system:node:${worker} \
        --client-certificate="${CERT_DIR}/${worker}.crt" \
        --client-key="${CERT_DIR}/${worker}.key" \
        --embed-certs=true \
        --kubeconfig="${worker}.kubeconfig" || {
        log_error "Failed to set credentials for ${worker}"
        exit 1
    }
    
    # Set context
    ${KUBECTL_CMD} config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:node:${worker} \
        --kubeconfig="${worker}.kubeconfig" || {
        log_error "Failed to set context for ${worker}"
        exit 1
    }
    
    # Use context
    ${KUBECTL_CMD} config use-context default --kubeconfig="${worker}.kubeconfig" || {
        log_error "Failed to use context for ${worker}"
        exit 1
    }
    
    log "✓ ${worker}.kubeconfig created"
done

# 2. Generate Kube-proxy Kubeconfig
log "Creating kube-proxy kubeconfig..."
if [[ ! -f "kube-proxy.kubeconfig" ]]; then
    ${KUBECTL_CMD} config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CERT_DIR}/ca.crt" \
        --embed-certs=true \
        --server=https://${LOADBALANCER_ADDRESS}:6443 \
        --kubeconfig=kube-proxy.kubeconfig || {
        log_error "Failed to set cluster for kube-proxy"
        exit 1
    }
    
    ${KUBECTL_CMD} config set-credentials system:kube-proxy \
        --client-certificate="${CERT_DIR}/kube-proxy.crt" \
        --client-key="${CERT_DIR}/kube-proxy.key" \
        --embed-certs=true \
        --kubeconfig=kube-proxy.kubeconfig || {
        log_error "Failed to set credentials for kube-proxy"
        exit 1
    }
    
    ${KUBECTL_CMD} config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-proxy \
        --kubeconfig=kube-proxy.kubeconfig || {
        log_error "Failed to set context for kube-proxy"
        exit 1
    }
    
    ${KUBECTL_CMD} config use-context default --kubeconfig=kube-proxy.kubeconfig || {
        log_error "Failed to use context for kube-proxy"
        exit 1
    }
    
    log "✓ kube-proxy.kubeconfig created"
else
    log "✓ kube-proxy.kubeconfig already exists"
fi

# 3. Generate Kube-controller-manager Kubeconfig
log "Creating kube-controller-manager kubeconfig..."
if [[ ! -f "kube-controller-manager.kubeconfig" ]]; then
    ${KUBECTL_CMD} config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CERT_DIR}/ca.crt" \
        --embed-certs=true \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=kube-controller-manager.kubeconfig || {
        log_error "Failed to set cluster for kube-controller-manager"
        exit 1
    }
    
    ${KUBECTL_CMD} config set-credentials system:kube-controller-manager \
        --client-certificate="${CERT_DIR}/kube-controller-manager.crt" \
        --client-key="${CERT_DIR}/kube-controller-manager.key" \
        --embed-certs=true \
        --kubeconfig=kube-controller-manager.kubeconfig || {
        log_error "Failed to set credentials for kube-controller-manager"
        exit 1
    }
    
    ${KUBECTL_CMD} config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-controller-manager \
        --kubeconfig=kube-controller-manager.kubeconfig || {
        log_error "Failed to set context for kube-controller-manager"
        exit 1
    }
    
    ${KUBECTL_CMD} config use-context default --kubeconfig=kube-controller-manager.kubeconfig || {
        log_error "Failed to use context for kube-controller-manager"
        exit 1
    }
    
    log "✓ kube-controller-manager.kubeconfig created"
else
    log "✓ kube-controller-manager.kubeconfig already exists"
fi

# 4. Generate Kube-scheduler Kubeconfig
log "Creating kube-scheduler kubeconfig..."
if [[ ! -f "kube-scheduler.kubeconfig" ]]; then
    ${KUBECTL_CMD} config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CERT_DIR}/ca.crt" \
        --embed-certs=true \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=kube-scheduler.kubeconfig || {
        log_error "Failed to set cluster for kube-scheduler"
        exit 1
    }
    
    ${KUBECTL_CMD} config set-credentials system:kube-scheduler \
        --client-certificate="${CERT_DIR}/kube-scheduler.crt" \
        --client-key="${CERT_DIR}/kube-scheduler.key" \
        --embed-certs=true \
        --kubeconfig=kube-scheduler.kubeconfig || {
        log_error "Failed to set credentials for kube-scheduler"
        exit 1
    }
    
    ${KUBECTL_CMD} config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-scheduler \
        --kubeconfig=kube-scheduler.kubeconfig || {
        log_error "Failed to set context for kube-scheduler"
        exit 1
    }
    
    ${KUBECTL_CMD} config use-context default --kubeconfig=kube-scheduler.kubeconfig || {
        log_error "Failed to use context for kube-scheduler"
        exit 1
    }
    
    log "✓ kube-scheduler.kubeconfig created"
else
    log "✓ kube-scheduler.kubeconfig already exists"
fi

# 5. Generate Admin Kubeconfig
log "Creating admin kubeconfig..."
if [[ ! -f "admin.kubeconfig" ]]; then
    ${KUBECTL_CMD} config set-cluster kubernetes-the-hard-way \
        --certificate-authority="${CERT_DIR}/ca.crt" \
        --embed-certs=true \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=admin.kubeconfig || {
        log_error "Failed to set cluster for admin"
        exit 1
    }
    
    ${KUBECTL_CMD} config set-credentials admin \
        --client-certificate="${CERT_DIR}/admin.crt" \
        --client-key="${CERT_DIR}/admin.key" \
        --embed-certs=true \
        --kubeconfig=admin.kubeconfig || {
        log_error "Failed to set credentials for admin"
        exit 1
    }
    
    ${KUBECTL_CMD} config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=admin \
        --kubeconfig=admin.kubeconfig || {
        log_error "Failed to set context for admin"
        exit 1
    }
    
    ${KUBECTL_CMD} config use-context default --kubeconfig=admin.kubeconfig || {
        log_error "Failed to use context for admin"
        exit 1
    }
    
    log "✓ admin.kubeconfig created"
else
    log "✓ admin.kubeconfig already exists"
fi

# Verify all kubeconfig files
log "Verifying generated kubeconfig files..."
REQUIRED_KUBECONFIGS=(
    "worker-1.kubeconfig"
    "worker-2.kubeconfig"
    "kube-proxy.kubeconfig"
    "kube-controller-manager.kubeconfig"
    "kube-scheduler.kubeconfig"
    "admin.kubeconfig"
)

for kubeconfig in "${REQUIRED_KUBECONFIGS[@]}"; do
    if [[ ! -f "$kubeconfig" ]]; then
        log_error "Kubeconfig $kubeconfig not found"
        exit 1
    fi
    
    # Verify kubeconfig is valid YAML
    if ! ${KUBECTL_CMD} config view --kubeconfig="$kubeconfig" >/dev/null 2>&1; then
        log_error "Kubeconfig $kubeconfig is invalid"
        exit 1
    fi
    
    log "✓ $kubeconfig verified"
done

# List generated kubeconfig files
log "Kubeconfig summary:"
ls -la *.kubeconfig | while read -r line; do
    log "$line"
done

# Create status file
echo "PHASE3_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase3_status"
echo "KUBECONFIGS_DIR=${CONFIG_DIR}" >> "${SCRIPT_DIR}/.phase3_status"

log_success "Phase 3: Kubeconfig generation completed successfully"
log ""
log "Next step: Run phase4-encryption.sh"

exit 0
