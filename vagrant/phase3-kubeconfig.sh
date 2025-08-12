#!/bin/bash
# Phase 3: Kubeconfig Generation  
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

# Check if Phase 2 completed
if [[ ! -f "/home/vagrant/phase2_completed.txt" ]]; then
    log_error "Phase 2 not completed. Please run phase2-certificates.sh first."
    exit 1
fi

log "=== Phase 3: Kubeconfig Generation ==="

cd /home/vagrant/certs

# Step 0: Install kubectl if not present
log ""
log "${YELLOW}Step 0: Installing kubectl...${NC}"
if ! command -v kubectl &> /dev/null; then
    log "kubectl not found, installing..."
    
    # Download kubectl
    curl -LO "https://dl.k8s.io/release/v1.28.4/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    
    log_success "kubectl installed"
else
    log_success "kubectl already installed"
fi

# Variables
KUBERNETES_PUBLIC_ADDRESS="192.168.56.30"  # Load balancer IP

# Step 1: Generate worker kubeconfig files
log ""
log "${YELLOW}Step 1: Generating worker kubeconfig files...${NC}"

workers=("worker-1" "worker-2")
for worker in "${workers[@]}"; do
    log "Generating kubeconfig for $worker..."
    
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=ca.crt \
        --embed-certs=true \
        --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
        --kubeconfig=${worker}.kubeconfig

    kubectl config set-credentials system:node:${worker} \
        --client-certificate=${worker}.crt \
        --client-key=${worker}.key \
        --embed-certs=true \
        --kubeconfig=${worker}.kubeconfig

    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:node:${worker} \
        --kubeconfig=${worker}.kubeconfig

    kubectl config use-context default --kubeconfig=${worker}.kubeconfig

    log_success "${worker} kubeconfig generated"
done

# Step 2: Generate kube-proxy kubeconfig (first need kube-proxy cert)
log ""
log "${YELLOW}Step 2: Generating kube-proxy certificate and kubeconfig...${NC}"

# Generate kube-proxy certificate if not exists
if [[ ! -f kube-proxy.key ]]; then
    openssl genrsa -out kube-proxy.key 2048
    log_success "kube-proxy private key generated"
fi

if [[ ! -f kube-proxy.crt ]]; then
    cat > kube-proxy.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=system:node-proxier
OU=Kubernetes The Hard Way
CN=system:kube-proxy
EOF

    openssl req -new -key kube-proxy.key -out kube-proxy.csr -config kube-proxy.conf
    openssl x509 -req -in kube-proxy.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-proxy.crt -days 365
    rm kube-proxy.csr
    log_success "kube-proxy certificate generated"
fi

kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
    --client-certificate=kube-proxy.crt \
    --client-key=kube-proxy.key \
    --embed-certs=true \
    --kubeconfig=kube-proxy.kubeconfig

kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
log_success "kube-proxy kubeconfig generated"

# Step 3: Generate controller manager kubeconfig
log ""
log "${YELLOW}Step 3: Generating controller manager kubeconfig...${NC}"

kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=kube-controller-manager.crt \
    --client-key=kube-controller-manager.key \
    --embed-certs=true \
    --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig=kube-controller-manager.kubeconfig

kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
log_success "controller manager kubeconfig generated"

# Step 4: Generate scheduler kubeconfig
log ""
log "${YELLOW}Step 4: Generating scheduler kubeconfig...${NC}"

kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \
    --client-certificate=kube-scheduler.crt \
    --client-key=kube-scheduler.key \
    --embed-certs=true \
    --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig=kube-scheduler.kubeconfig

kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
log_success "scheduler kubeconfig generated"

# Step 5: Generate admin kubeconfig
log ""
log "${YELLOW}Step 5: Generating admin kubeconfig...${NC}"

kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=admin.kubeconfig

kubectl config set-credentials admin \
    --client-certificate=admin.crt \
    --client-key=admin.key \
    --embed-certs=true \
    --kubeconfig=admin.kubeconfig

kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig=admin.kubeconfig

kubectl config use-context default --kubeconfig=admin.kubeconfig
log_success "admin kubeconfig generated"

# Step 6: Distribute kubeconfig files
log ""
log "${YELLOW}Step 6: Distributing kubeconfig files...${NC}"

# Copy worker kubeconfig files to worker nodes
for worker in "${workers[@]}"; do
    log "Copying kubeconfig files to $worker..."
    scp -o StrictHostKeyChecking=no ${worker}.kubeconfig kube-proxy.kubeconfig vagrant@${worker}:/home/vagrant/
    log_success "Kubeconfig files copied to $worker"
done

# Copy controller kubeconfig files to master-2
log "Copying controller kubeconfig files to master-2..."
scp -o StrictHostKeyChecking=no admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig vagrant@master-2:/home/vagrant/certs/
log_success "Controller kubeconfig files copied to master-2"

# Step 7: Verify kubeconfig files
log ""
log "${YELLOW}Step 7: Verifying kubeconfig files...${NC}"

log "Kubeconfig files generated:"
echo "==============================================="
ls -la *.kubeconfig
echo ""
echo "Admin kubeconfig clusters:"
kubectl config view --kubeconfig=admin.kubeconfig --flatten=false
echo "==============================================="

# Create completion marker
echo "Phase 3 completed: $(date)" > /home/vagrant/phase3_completed.txt

log ""
log_success "🎉 Phase 3 (Kubeconfig Generation) completed successfully!"
log ""
log "${CYAN}Kubeconfig files generated:${NC}"
log_success "  ✓ Worker node kubeconfig files" 
log_success "  ✓ kube-proxy kubeconfig"
log_success "  ✓ Controller Manager kubeconfig"
log_success "  ✓ Scheduler kubeconfig"
log_success "  ✓ Admin kubeconfig"
log ""
log "${YELLOW}Next step: ./phase4-encryption.sh${NC}"