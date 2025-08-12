#!/bin/bash

#===============================================================================
# PHASE 2: CERTIFICATE GENERATION
# Generates all required certificates for the Kubernetes cluster
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

# Check if phase 1 completed
if [[ ! -f "${SCRIPT_DIR}/.phase1_status" ]]; then
    log_error "Phase 1 not completed. Please run phase1-prerequisites.sh first."
    exit 1
fi

log "=== PHASE 2: Generating Certificates ==="

# Change to working directory
cd "${SCRIPT_DIR}" || {
    log_error "Failed to change to script directory"
    exit 1
}

# Check if openssl is available
if ! command -v openssl >/dev/null 2>&1; then
    log_error "openssl not found. Please install openssl."
    exit 1
fi

# Create certificates directory
mkdir -p "${CERT_DIR}" || {
    log_error "Failed to create certificates directory"
    exit 1
}

cd "${CERT_DIR}" || {
    log_error "Failed to change to certificates directory"
    exit 1
}

log "Working in: $(pwd)"

# 1. Generate Certificate Authority (CA)
log "Generating Certificate Authority..."
if [[ ! -f ca.key ]]; then
    openssl genrsa -out ca.key 2048 || {
        log_error "Failed to generate CA private key"
        exit 1
    }
    log "✓ CA private key generated"
else
    log "✓ CA private key already exists"
fi

if [[ ! -f ca.crt ]]; then
    cat > ca.conf <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = San Francisco
O = Kubernetes
OU = Kubernetes The Hard Way
CN = Kubernetes CA

[v3_ca]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = CA:true
EOF

    openssl req -new -x509 -key ca.key -sha256 -subj "/C=US/ST=CA/L=San Francisco/O=Kubernetes/OU=Kubernetes The Hard Way/CN=Kubernetes CA" -days 3650 -out ca.crt -extensions v3_ca -config ca.conf || {
        log_error "Failed to generate CA certificate"
        exit 1
    }
    log "✓ CA certificate generated"
else
    log "✓ CA certificate already exists"
fi

# Verify CA certificate
if ! openssl x509 -in ca.crt -text -noout | grep -q "Kubernetes CA"; then
    log_error "CA certificate verification failed"
    exit 1
fi

# 2. Generate Admin Client Certificate
log "Generating Admin client certificate..."
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
[v3_req_client]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
) || {
        log_error "Failed to generate admin certificate"
        exit 1
    }
    rm admin.csr
    log "✓ Admin certificate generated"
else
    log "✓ Admin certificate already exists"
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
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = San Francisco
O = Kubernetes
OU = Kubernetes The Hard Way
CN = etcd-server

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = master-1
DNS.3 = master-2
IP.1 = 127.0.0.1
IP.2 = 192.168.5.11
IP.3 = 192.168.5.12
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
    log "✓ etcd server certificate generated"
else
    log "✓ etcd server certificate already exists"
fi

# 4. Generate Kube API Server Certificate
log "Generating kube-apiserver certificate..."
if [[ ! -f kube-apiserver.key ]]; then
    openssl genrsa -out kube-apiserver.key 2048 || {
        log_error "Failed to generate kube-apiserver private key"
        exit 1
    }
fi

if [[ ! -f kube-apiserver.crt ]]; then
    cat > kube-apiserver.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = San Francisco
O = Kubernetes
OU = Kubernetes The Hard Way
CN = kube-apiserver

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster
DNS.5 = kubernetes.default.svc.cluster.local
DNS.6 = master-1
DNS.7 = master-2
DNS.8 = localhost
IP.1 = 10.32.0.1
IP.2 = 127.0.0.1
IP.3 = 192.168.5.11
IP.4 = 192.168.5.12
IP.5 = 192.168.5.30
EOF

    openssl req -new -key kube-apiserver.key -out kube-apiserver.csr -config kube-apiserver.conf || {
        log_error "Failed to generate kube-apiserver CSR"
        exit 1
    }
    
    openssl x509 -req -in kube-apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-apiserver.crt -days 365 -extensions v3_req -extfile kube-apiserver.conf || {
        log_error "Failed to generate kube-apiserver certificate"
        exit 1
    }
    rm kube-apiserver.csr
    log "✓ kube-apiserver certificate generated"
else
    log "✓ kube-apiserver certificate already exists"
fi

# 5. Generate Service Account Certificate
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
    log "✓ Service account certificate generated"
else
    log "✓ Service account certificate already exists"
fi

# 6. Generate Worker Node Certificates
log "Generating worker node certificates..."
for worker in worker-1 worker-2; do
    if [[ ! -f ${worker}.key ]]; then
        openssl genrsa -out ${worker}.key 2048 || {
            log_error "Failed to generate ${worker} private key"
            exit 1
        }
    fi
    
    if [[ ! -f ${worker}.crt ]]; then
        # Get worker IP based on name
        case $worker in
            worker-1) worker_ip="192.168.5.21" ;;
            worker-2) worker_ip="192.168.5.22" ;;
        esac
        
        cat > ${worker}.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = San Francisco
O = system:nodes
OU = Kubernetes The Hard Way
CN = system:node:${worker}

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
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
        log "✓ ${worker} certificate generated"
    else
        log "✓ ${worker} certificate already exists"
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
    log "✓ Controller manager certificate generated"
else
    log "✓ Controller manager certificate already exists"
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
    log "✓ Scheduler certificate generated"
else
    log "✓ Scheduler certificate already exists"
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
    log "✓ Kube-proxy certificate generated"
else
    log "✓ Kube-proxy certificate already exists"
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
    
    log "✓ $cert verified"
done

# Clean up temporary config files
rm -f *.conf

# List generated certificates
log "Certificate summary:"
ls -la *.crt *.key | while read -r line; do
    log "$line"
done

# Create status file
echo "PHASE2_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase2_status"
echo "CERTIFICATES_DIR=${CERT_DIR}" >> "${SCRIPT_DIR}/.phase2_status"

log_success "Phase 2: Certificate generation completed successfully"
log ""
log "Next step: Run phase3-kubeconfig.sh"

exit 0
