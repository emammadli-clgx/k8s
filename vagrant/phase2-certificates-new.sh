#!/bin/bash
# Phase 2: Certificate Generation
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

log_warning() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $1${NC}"
}

# Check if we're on master-1
if [[ "$(hostname)" != "master-1" ]]; then
    log_error "This script must be run on master-1 node!"
    exit 1
fi

# Check if Phase 1 completed
if [[ ! -f "/home/vagrant/phase1_completed.txt" ]]; then
    log_error "Phase 1 not completed. Please run phase1-prerequisites.sh first."
    exit 1
fi

log "=== Phase 2: Certificate Generation ==="

# Create certificate directory
mkdir -p /home/vagrant/certs
cd /home/vagrant/certs

# Step 1: Generate CA Certificate
log ""
log "${YELLOW}Step 1: Generating CA Certificate...${NC}"

if [[ ! -f ca.key ]]; then
    openssl genrsa -out ca.key 2048
    log_success "CA private key generated"
else
    log_success "CA private key already exists"
fi

if [[ ! -f ca.crt ]]; then
    cat > ca.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_ca

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=Kubernetes
OU=Kubernetes The Hard Way
CN=Kubernetes CA

[ v3_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
EOF

    openssl req -new -x509 -key ca.key -sha256 -subj "/C=US/ST=CA/L=San Francisco/O=Kubernetes/OU=Kubernetes The Hard Way/CN=Kubernetes CA" -days 3650 -out ca.crt -extensions v3_ca -config ca.conf
    log_success "CA certificate generated"
else
    log_success "CA certificate already exists"
fi

# Step 2: Generate Admin Client Certificate
log ""
log "${YELLOW}Step 2: Generating Admin Client Certificate...${NC}"

if [[ ! -f admin.key ]]; then
    openssl genrsa -out admin.key 2048
    log_success "Admin private key generated"
fi

if [[ ! -f admin.crt ]]; then
    cat > admin.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=system:masters
OU=Kubernetes The Hard Way
CN=admin
EOF

    openssl req -new -key admin.key -out admin.csr -config admin.conf
    openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out admin.crt -days 365
    rm admin.csr
    log_success "Admin certificate generated"
fi

# Step 3: Generate Worker Node Certificates
log ""
log "${YELLOW}Step 3: Generating Worker Node Certificates...${NC}"

workers=("worker-1" "worker-2")
worker_ips=("192.168.56.21" "192.168.56.22")

for i in "${!workers[@]}"; do
    worker="${workers[i]}"
    worker_ip="${worker_ips[i]}"
    
    if [[ ! -f "${worker}.key" ]]; then
        openssl genrsa -out "${worker}.key" 2048
        log_success "${worker} private key generated"
    fi
    
    if [[ ! -f "${worker}.crt" ]]; then
        cat > "${worker}.conf" <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_req

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=system:nodes
OU=Kubernetes The Hard Way
CN=system:node:${worker}

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${worker}
IP.1 = ${worker_ip}
EOF

        openssl req -new -key "${worker}.key" -out "${worker}.csr" -config "${worker}.conf"
        openssl x509 -req -in "${worker}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${worker}.crt" -days 365 -extensions v3_req -extfile "${worker}.conf"
        rm "${worker}.csr"
        log_success "${worker} certificate generated"
    fi
done

# Step 4: Generate Controller Manager Certificate
log ""
log "${YELLOW}Step 4: Generating Controller Manager Certificate...${NC}"

if [[ ! -f kube-controller-manager.key ]]; then
    openssl genrsa -out kube-controller-manager.key 2048
    log_success "Controller Manager private key generated"
fi

if [[ ! -f kube-controller-manager.crt ]]; then
    cat > kube-controller-manager.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=system:kube-controller-manager
OU=Kubernetes The Hard Way
CN=system:kube-controller-manager
EOF

    openssl req -new -key kube-controller-manager.key -out kube-controller-manager.csr -config kube-controller-manager.conf
    openssl x509 -req -in kube-controller-manager.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-controller-manager.crt -days 365
    rm kube-controller-manager.csr
    log_success "Controller Manager certificate generated"
fi

# Step 5: Generate Scheduler Certificate
log ""
log "${YELLOW}Step 5: Generating Scheduler Certificate...${NC}"

if [[ ! -f kube-scheduler.key ]]; then
    openssl genrsa -out kube-scheduler.key 2048
    log_success "Scheduler private key generated"
fi

if [[ ! -f kube-scheduler.crt ]]; then
    cat > kube-scheduler.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=system:kube-scheduler
OU=Kubernetes The Hard Way
CN=system:kube-scheduler
EOF

    openssl req -new -key kube-scheduler.key -out kube-scheduler.csr -config kube-scheduler.conf
    openssl x509 -req -in kube-scheduler.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-scheduler.crt -days 365
    rm kube-scheduler.csr
    log_success "Scheduler certificate generated"
fi

# Step 6: Generate API Server Certificate
log ""
log "${YELLOW}Step 6: Generating API Server Certificate...${NC}"

if [[ ! -f kube-apiserver.key ]]; then
    openssl genrsa -out kube-apiserver.key 2048
    log_success "API Server private key generated"
fi

if [[ ! -f kube-apiserver.crt ]]; then
    cat > kube-apiserver.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_req

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=Kubernetes
OU=Kubernetes The Hard Way
CN=kubernetes

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
DNS.5 = master-1
DNS.6 = master-2
DNS.7 = lb
IP.1 = 10.32.0.1
IP.2 = 192.168.56.11
IP.3 = 192.168.56.12
IP.4 = 192.168.56.30
IP.5 = 127.0.0.1
EOF

    openssl req -new -key kube-apiserver.key -out kube-apiserver.csr -config kube-apiserver.conf
    openssl x509 -req -in kube-apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-apiserver.crt -days 365 -extensions v3_req -extfile kube-apiserver.conf
    rm kube-apiserver.csr
    log_success "API Server certificate generated"
fi

# Step 7: Generate Service Account Certificate
log ""
log "${YELLOW}Step 7: Generating Service Account Certificate...${NC}"

if [[ ! -f service-account.key ]]; then
    openssl genrsa -out service-account.key 2048
    log_success "Service Account private key generated"
fi

if [[ ! -f service-account.crt ]]; then
    cat > service-account.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=Kubernetes
OU=Kubernetes The Hard Way
CN=service-accounts
EOF

    openssl req -new -key service-account.key -out service-account.csr -config service-account.conf
    openssl x509 -req -in service-account.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out service-account.crt -days 365
    rm service-account.csr
    log_success "Service Account certificate generated"
fi

# Step 8: Copy certificates to all nodes
log ""
log "${YELLOW}Step 8: Distributing certificates to all nodes...${NC}"

# Copy CA certificate to all nodes
for node in master-2 worker-1 worker-2; do
    log "Copying CA certificate to $node..."
    ssh -o StrictHostKeyChecking=no vagrant@$node "mkdir -p /home/vagrant/certs"
    scp -o StrictHostKeyChecking=no ca.crt vagrant@$node:/home/vagrant/certs/
    log_success "CA certificate copied to $node"
done

# Copy worker certificates to worker nodes
workers=("worker-1" "worker-2")
for worker in "${workers[@]}"; do
    log "Copying worker certificates to $worker..."
    scp -o StrictHostKeyChecking=no "${worker}.key" "${worker}.crt" vagrant@$worker:/home/vagrant/certs/
    log_success "Worker certificates copied to $worker"
done

# Copy master certificates to master-2
log "Copying master certificates to master-2..."
master_certs=("kube-apiserver.key" "kube-apiserver.crt" "kube-controller-manager.key" "kube-controller-manager.crt" "kube-scheduler.key" "kube-scheduler.crt" "service-account.key" "service-account.crt")
for cert in "${master_certs[@]}"; do
    scp -o StrictHostKeyChecking=no "$cert" vagrant@master-2:/home/vagrant/certs/
done
log_success "Master certificates copied to master-2"

# Step 9: Verify certificates
log ""
log "${YELLOW}Step 9: Verifying certificates...${NC}"

log "Certificate summary:"
echo "==============================================="
echo "Certificate files generated:"
ls -la *.crt *.key | grep -v ".conf" || true
echo ""
echo "Certificate details:"
echo ""
echo "CA Certificate:"
openssl x509 -in ca.crt -text -noout | grep -E "(Subject:|Not After)" || true
echo ""
echo "API Server Certificate:"
openssl x509 -in kube-apiserver.crt -text -noout | grep -E "(Subject:|DNS:|IP:|Not After)" || true
echo ""
echo "==============================================="

# Create completion marker
echo "Phase 2 completed: $(date)" > /home/vagrant/phase2_completed.txt

log ""
log_success "🎉 Phase 2 (Certificate Generation) completed successfully!"
log ""
log "${CYAN}Certificates generated:${NC}"
log_success "  ✓ Certificate Authority (CA)"
log_success "  ✓ Admin client certificate"
log_success "  ✓ Worker node certificates"
log_success "  ✓ Controller Manager certificate"
log_success "  ✓ Scheduler certificate"
log_success "  ✓ API Server certificate"
log_success "  ✓ Service Account certificate"
log ""
log "${YELLOW}Next step: ./phase3-kubeconfig.sh${NC}"
