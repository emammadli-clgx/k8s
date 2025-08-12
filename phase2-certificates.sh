#!/bin/bash

#===============================================================================
# PHASE 2: GENERATE CERTIFICATES
# Generate all required certificates for the Kubernetes cluster
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

# Check if previous phase completed
if [[ ! -f "${SCRIPT_DIR}/.phase1_status" ]]; then
    log_error "Phase 1 not completed. Please run phase1-prerequisites.sh first."
    exit 1
fi

log "=== PHASE 2: Generate Certificates ==="

# Change to script directory
cd "${SCRIPT_DIR}" || {
    log_error "Failed to change to script directory"
    exit 1
}

# Create certificate directory
mkdir -p "${CERT_DIR}" || {
    log_error "Failed to create certificate directory"
    exit 1
}

# Change to certificate directory  
cd "${CERT_DIR}" || {
    log_error "Failed to change to certificate directory"
    exit 1
}

# 1. Generate CA Certificate
log "Generating CA certificate..."

if [[ ! -f ca.key ]]; then
    openssl genrsa -out ca.key 2048 || {
        log_error "Failed to generate CA private key"
        exit 1
    }
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

    openssl req -new -x509 -key ca.key -sha256 -subj "/C=US/ST=CA/L=San Francisco/O=Kubernetes/OU=Kubernetes The Hard Way/CN=Kubernetes CA" -days 3650 -out ca.crt -extensions v3_ca -config ca.conf || {
        log_error "Failed to generate CA certificate"
        exit 1
    }
    log_success "CA certificate generated"
else
    log_success "CA certificate already exists"
fi

if ! openssl x509 -in ca.crt -text -noout | grep -q "Kubernetes CA"; then
    log_error "CA certificate validation failed"
    exit 1
fi

# 2. Generate Admin Client Certificate
log "Generating admin certificate..."
if [[ ! -f admin.key ]]; then
    openssl genrsa -out admin.key 2048 || {
        log_error "Failed to generate admin private key"
        exit 1
    }
fi

if [[ ! -f admin.crt ]]; then
    openssl req -new -key admin.key -subj "/C=US/ST=CA/L=San Francisco/O=system:masters/OU=Kubernetes The Hard Way/CN=admin" -out admin.csr || {
        log_error "Failed to generate admin CSR"
        exit 1
    }
    
    openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out admin.crt -days 365 -extensions v3_req_client -extfile <(cat <<EOF
[ v3_req_client ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF
) || {
        log_error "Failed to generate admin certificate"
        exit 1
    }
    rm admin.csr
    log_success "Admin certificate generated"
else
    log_success "Admin certificate already exists"
fi

# 3. Generate etcd Server Certificate
log "Generating etcd server certificate..."
if [[ ! -f etcd-server.key ]]; then
    openssl genrsa -out etcd-server.key 2048 || {
        log_error "Failed to generate etcd server private key"
        exit 1
    }
fi

if [[ ! -f etcd-server.crt ]]; then
    cat > etcd-server.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_req

[ req_distinguished_name ]
C=US
ST=CA
L=San Francisco
O=etcd
OU=Kubernetes The Hard Way
CN=etcd-server

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master-1
DNS.2 = master-2
DNS.3 = localhost
IP.1 = ${MASTER_IPS[0]}
IP.2 = ${MASTER_IPS[1]}
IP.3 = 127.0.0.1
EOF
    
    openssl req -new -key etcd-server.key -out etcd-server.csr -config etcd-server.conf || {
        log_error "Failed to generate etcd server CSR"
        exit 1
    }
    
    openssl x509 -req -in etcd-server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out etcd-server.crt -days 365 -extensions v3_req -extfile etcd-server.conf || {
        log_error "Failed to generate etcd server certificate"
        exit 1
    }
    rm etcd-server.csr
    log_success "etcd server certificate generated"
else
    log_success "etcd server certificate already exists"
fi

# 4. Generate Kubernetes API Server Certificate
log "Generating Kubernetes API server certificate..."
if [[ ! -f kube-apiserver.key ]]; then
    openssl genrsa -out kube-apiserver.key 2048 || {
        log_error "Failed to generate API server private key"
        exit 1
    }
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
CN=kube-apiserver

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster
DNS.5 = kubernetes.default.svc.cluster.local
DNS.6 = master-1
DNS.7 = master-2
DNS.8 = localhost
IP.1 = ${KUBERNETES_SERVICE_IP}
IP.2 = ${MASTER_IPS[0]}
IP.3 = ${MASTER_IPS[1]}
IP.4 = ${LOADBALANCER_ADDRESS}
IP.5 = 127.0.0.1
EOF
    
    openssl req -new -key kube-apiserver.key -out kube-apiserver.csr -config kube-apiserver.conf || {
        log_error "Failed to generate API server CSR"
        exit 1
    }
    
    openssl x509 -req -in kube-apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-apiserver.crt -days 365 -extensions v3_req -extfile kube-apiserver.conf || {
        log_error "Failed to generate API server certificate"
        exit 1
    }
    rm kube-apiserver.csr
    log_success "API server certificate generated"
else
    log_success "API server certificate already exists"
fi

# 5. Generate Service Account Key Pair
log "Generating service account certificate..."
if [[ ! -f service-account.key ]]; then
    openssl genrsa -out service-account.key 2048 || {
        log_error "Failed to generate service account private key"
        exit 1
    }
fi

if [[ ! -f service-account.crt ]]; then
    openssl req -new -key service-account.key -subj "/C=US/ST=CA/L=San Francisco/O=Kubernetes/OU=Kubernetes The Hard Way/CN=service-accounts" -out service-account.csr || {
        log_error "Failed to generate service account CSR"
        exit 1
    }
    
    openssl x509 -req -in service-account.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out service-account.crt -days 365 || {
        log_error "Failed to generate service account certificate"
        exit 1
    }
    rm service-account.csr
    log_success "Service account certificate generated"
else
    log_success "Service account certificate already exists"
fi

# 6. Generate Worker Certificates
for i in "${!WORKER_NODES[@]}"; do
    worker=${WORKER_NODES[$i]}
    worker_ip=${WORKER_IPS[$i]}
    
    log "Generating certificate for worker: $worker"
    
    if [[ ! -f ${worker}.key ]]; then
        openssl genrsa -out ${worker}.key 2048 || {
            log_error "Failed to generate ${worker} private key"
            exit 1
        }
    fi
    
    if [[ ! -f ${worker}.crt ]]; then
        cat > ${worker}.conf <<EOF
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
extendedKeyUsage = clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${worker}
IP.1 = ${worker_ip}
EOF
        
        openssl req -new -key ${worker}.key -out ${worker}.csr -config ${worker}.conf || {
            log_error "Failed to generate ${worker} CSR"
            exit 1
        }
        
        openssl x509 -req -in ${worker}.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out ${worker}.crt -days 365 -extensions v3_req -extfile ${worker}.conf || {
            log_error "Failed to generate ${worker} certificate"
            exit 1
        }
        rm ${worker}.csr
        log_success "${worker} certificate generated"
    else
        log_success "${worker} certificate already exists"
    fi
done

# 7. Generate Controller Manager Client Certificate  
log "Generating controller manager certificate..."
if [[ ! -f kube-controller-manager.key ]]; then
    openssl genrsa -out kube-controller-manager.key 2048 || {
        log_error "Failed to generate controller manager private key"
        exit 1
    }
fi

if [[ ! -f kube-controller-manager.crt ]]; then
    openssl req -new -key kube-controller-manager.key -subj "/C=US/ST=CA/L=San Francisco/O=system:kube-controller-manager/OU=Kubernetes The Hard Way/CN=system:kube-controller-manager" -out kube-controller-manager.csr || {
        log_error "Failed to generate controller manager CSR"
        exit 1
    }
    
    openssl x509 -req -in kube-controller-manager.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-controller-manager.crt -days 365 || {
        log_error "Failed to generate controller manager certificate"
        exit 1
    }
    rm kube-controller-manager.csr
    log_success "Controller manager certificate generated"
else
    log_success "Controller manager certificate already exists"
fi

# 8. Generate Scheduler Client Certificate
log "Generating scheduler certificate..."
if [[ ! -f kube-scheduler.key ]]; then
    openssl genrsa -out kube-scheduler.key 2048 || {
        log_error "Failed to generate scheduler private key"
        exit 1
    }
fi

if [[ ! -f kube-scheduler.crt ]]; then
    openssl req -new -key kube-scheduler.key -subj "/C=US/ST=CA/L=San Francisco/O=system:kube-scheduler/OU=Kubernetes The Hard Way/CN=system:kube-scheduler" -out kube-scheduler.csr || {
        log_error "Failed to generate scheduler CSR"
        exit 1
    }
    
    openssl x509 -req -in kube-scheduler.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-scheduler.crt -days 365 || {
        log_error "Failed to generate scheduler certificate"
        exit 1
    }
    rm kube-scheduler.csr
    log_success "Scheduler certificate generated"
else
    log_success "Scheduler certificate already exists"
fi

# 9. Generate Kube Proxy Client Certificate
log "Generating kube-proxy certificate..."
if [[ ! -f kube-proxy.key ]]; then
    openssl genrsa -out kube-proxy.key 2048 || {
        log_error "Failed to generate kube-proxy private key"
        exit 1
    }
fi

if [[ ! -f kube-proxy.crt ]]; then
    openssl req -new -key kube-proxy.key -subj "/C=US/ST=CA/L=San Francisco/O=system:node-proxier/OU=Kubernetes The Hard Way/CN=system:kube-proxy" -out kube-proxy.csr || {
        log_error "Failed to generate kube-proxy CSR"
        exit 1
    }
    
    openssl x509 -req -in kube-proxy.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-proxy.crt -days 365 || {
        log_error "Failed to generate kube-proxy certificate"
        exit 1
    }
    rm kube-proxy.csr
    log_success "Kube-proxy certificate generated"
else
    log_success "Kube-proxy certificate already exists"
fi

# Clean up temporary files
rm -f *.conf *.csr

# Convert .crt files to .pem format for compatibility with Kubernetes ecosystem
log "Converting certificates to PEM format for Kubernetes compatibility..."
for cert in *.crt; do
    if [[ -f "$cert" ]]; then
        pem_name="${cert%.crt}.pem"
        cp "$cert" "$pem_name"
        log_success "Converted $cert to $pem_name"
    fi
done

# Also create .pem versions of keys for consistency
for key in *.key; do
    if [[ -f "$key" ]]; then
        pem_name="${key%.key}-key.pem"
        cp "$key" "$pem_name"
        log_success "Created $pem_name from $key"
    fi
done

# Special handling for ca.crt -> ca.pem
if [[ -f "ca.crt" ]]; then
    cp ca.crt ca.pem
    log_success "Created ca.pem from ca.crt"
fi

# Verify all certificates
log "Verifying generated certificates..."
REQUIRED_CERTS=(
    "ca.crt"
    "admin.crt"
    "etcd-server.crt"
    "kube-apiserver.crt"
    "service-account.crt"
    "worker-1.crt"
    "worker-2.crt"
    "kube-controller-manager.crt"
    "kube-scheduler.crt"
    "kube-proxy.crt"
)

for cert in "${REQUIRED_CERTS[@]}"; do
    if [[ ! -f "$cert" ]]; then
        log_error "Certificate $cert not found"
        exit 1
    fi
    
    # Verify certificate is valid
    if ! openssl x509 -in "$cert" -text -noout >/dev/null 2>&1; then
        log_error "Certificate $cert is invalid"
        exit 1
    fi
    
    log_success "Certificate $cert is valid"
done

# List generated certificates
log "Certificate summary:"
ls -la *.crt *.key *.pem 2>/dev/null | while read -r line; do
    log "$line"
done

# Create status file
echo "PHASE2_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase2_status"
echo "CERTIFICATES_DIR=${CERT_DIR}" >> "${SCRIPT_DIR}/.phase2_status"

log_success "Phase 2: Certificate generation completed successfully"
log ""
log "Next step: Run phase3-kubeconfig.sh"

exit 0
