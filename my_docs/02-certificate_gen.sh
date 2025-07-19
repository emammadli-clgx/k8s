#!/bin/bash

# generate-certificates.sh
# Purpose: Generate all TLS certificates for Kubernetes cluster
# Run on: master-1

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CERT_DIR="./certs"
CA_DIR="${CERT_DIR}/ca"
CLIENT_DIR="${CERT_DIR}/client"
SERVER_DIR="${CERT_DIR}/server"
CERT_VALIDITY_DAYS=1000
KEY_SIZE=2048

# IP addresses from your setup
MASTER1_IP="192.168.5.11"
MASTER2_IP="192.168.5.12"
LB_IP="192.168.5.30"
KUBERNETES_SERVICE_IP="10.96.0.1"

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

# Setup directory structure
setup_directories() {
    log "Setting up certificate directory structure..."
    
    mkdir -p "${CA_DIR}"
    mkdir -p "${CLIENT_DIR}"
    mkdir -p "${SERVER_DIR}"
    
    # Set proper permissions
    chmod 700 "${CERT_DIR}"
    chmod 700 "${CA_DIR}"
    chmod 700 "${CLIENT_DIR}"
    chmod 700 "${SERVER_DIR}"
}

# Generate Certificate Authority - FIXED VERSION
generate_ca() {
    log "Generating Certificate Authority..."
    
    cd "${CA_DIR}"
    
    # Create CA config file
    cat > ca-config.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
[req_distinguished_name]
[v3_ca]
basicConstraints = CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
EOF
    
    # Generate CA private key
    openssl genrsa -out ca.key ${KEY_SIZE}
    chmod 600 ca.key
    
    # Generate CA certificate with proper CA extensions
    openssl req -new -x509 -key ca.key -subj "/CN=KUBERNETES-CA" \
        -out ca.crt -days ${CERT_VALIDITY_DAYS} \
        -config ca-config.cnf -extensions v3_ca
    
    chmod 644 ca.crt
    
    # Verify CA certificate was created with CA flag
    if [[ -f ca.crt ]] && openssl x509 -in ca.crt -text -noout | grep -q "CA:TRUE"; then
        log "CA certificate generated successfully with CA flag"
    else
        error "CA certificate generation failed or missing CA flag"
        return 1
    fi
    
    # Clean up config file
    rm -f ca-config.cnf
    
    cd - > /dev/null
}

# Generate client certificate
generate_client_cert() {
    local name=$1
    local cn=$2
    local org=${3:-""}
    
    log "Generating client certificate for ${name}..."
    
    cd "${CLIENT_DIR}"
    
    # Generate private key
    openssl genrsa -out "${name}.key" ${KEY_SIZE}
    chmod 600 "${name}.key"
    
    # Generate certificate signing request
    local subject="/CN=${cn}"
    if [[ -n "${org}" ]]; then
        subject="${subject}/O=${org}"
    fi
    
    openssl req -new -key "${name}.key" -subj "${subject}" -out "${name}.csr"
    
    # Sign certificate
    openssl x509 -req -in "${name}.csr" \
        -CA "../ca/ca.crt" -CAkey "../ca/ca.key" -CAcreateserial \
        -out "${name}.crt" -days ${CERT_VALIDITY_DAYS}
    
    chmod 644 "${name}.crt"
    
    # Verify certificate
    if openssl verify -CAfile "../ca/ca.crt" "${name}.crt" 2>/dev/null | grep -q "OK"; then
        log "Client certificate for ${name} generated successfully"
    else
        error "Client certificate validation failed for ${name}"
        return 1
    fi
    
    # Clean up CSR
    rm -f "${name}.csr"
    
    cd - > /dev/null
}

# Generate server certificate with SAN
generate_server_cert() {
    local name=$1
    local cn=$2
    local config_file=$3
    
    log "Generating server certificate for ${name}..."
    
    cd "${SERVER_DIR}"
    
    # Generate private key
    openssl genrsa -out "${name}.key" ${KEY_SIZE}
    chmod 600 "${name}.key"
    
    # Generate certificate signing request
    openssl req -new -key "${name}.key" -subj "/CN=${cn}" \
        -out "${name}.csr" -config "${config_file}"
    
    # Sign certificate
    openssl x509 -req -in "${name}.csr" \
        -CA "../ca/ca.crt" -CAkey "../ca/ca.key" -CAcreateserial \
        -out "${name}.crt" -days ${CERT_VALIDITY_DAYS} \
        -extensions v3_req -extfile "${config_file}"
    
    chmod 644 "${name}.crt"
    
    # Verify certificate
    if openssl verify -CAfile "../ca/ca.crt" "${name}.crt" 2>/dev/null | grep -q "OK"; then
        log "Server certificate for ${name} generated successfully"
    else
        error "Server certificate validation failed for ${name}"
        return 1
    fi
    
    # Clean up CSR
    rm -f "${name}.csr"
    
    cd - > /dev/null
}

# Create OpenSSL config for kube-apiserver
create_apiserver_config() {
    cat > "${SERVER_DIR}/openssl-apiserver.cnf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
DNS.5 = master-1
DNS.6 = master-2
DNS.7 = lb
IP.1 = ${KUBERNETES_SERVICE_IP}
IP.2 = ${MASTER1_IP}
IP.3 = ${MASTER2_IP}
IP.4 = ${LB_IP}
IP.5 = 127.0.0.1
EOF
}

# Create OpenSSL config for etcd
create_etcd_config() {
    cat > "${SERVER_DIR}/openssl-etcd.cnf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = master-1
DNS.2 = master-2
DNS.3 = localhost
IP.1 = ${MASTER1_IP}
IP.2 = ${MASTER2_IP}
IP.3 = 127.0.0.1
EOF
}

# Distribute certificates to master nodes
distribute_certificates() {
    log "Distributing certificates to master nodes..."
    
    # Create distribution directory
    local dist_dir="${CERT_DIR}/distribution"
    mkdir -p "${dist_dir}"
    
    # Copy required certificates for each master
    cp "${CA_DIR}/ca.crt" "${CA_DIR}/ca.key" "${dist_dir}/"
    cp "${SERVER_DIR}/kube-apiserver.key" "${SERVER_DIR}/kube-apiserver.crt" "${dist_dir}/"
    cp "${CLIENT_DIR}/service-account.key" "${CLIENT_DIR}/service-account.crt" "${dist_dir}/"
    cp "${SERVER_DIR}/etcd-server.key" "${SERVER_DIR}/etcd-server.crt" "${dist_dir}/"
    
    # Copy to master-2 (master-1 already has them locally)
    log "Copying certificates to master-2..."
    if scp -o StrictHostKeyChecking=no "${dist_dir}"/* vagrant@master-2:~/; then
        log "Certificates copied to master-2 successfully"
    else
        error "Failed to copy certificates to master-2"
        return 1
    fi
    
    # Set proper permissions on master-2
    ssh -o StrictHostKeyChecking=no vagrant@master-2 'chmod 600 *.key; chmod 644 *.crt'
    
    log "Certificate distribution completed"
}

# Display certificate information
display_certificate_info() {
    log "Displaying certificate information..."
    
    echo ""
    echo "Generated Certificates:"
    echo "======================"
    
    # CA Certificate
    if [[ -f "${CA_DIR}/ca.crt" ]]; then
        echo "CA Certificate:"
        echo "  Subject: $(openssl x509 -in "${CA_DIR}/ca.crt" -noout -subject | cut -d= -f2-)"
        echo "  Valid until: $(openssl x509 -in "${CA_DIR}/ca.crt" -noout -enddate | cut -d= -f2)"
        echo "  CA Flag: $(openssl x509 -in "${CA_DIR}/ca.crt" -text -noout | grep -o 'CA:TRUE\|CA:FALSE')"
        echo ""
    fi
    
    # Client Certificates
    echo "Client Certificates:"
    for cert_file in "${CLIENT_DIR}"/*.crt; do
        if [[ -f "$cert_file" ]]; then
            local cert_name=$(basename "$cert_file" .crt)
            echo "  ${cert_name}:"
            echo "    Subject: $(openssl x509 -in "$cert_file" -noout -subject | cut -d= -f2-)"
            echo "    Valid until: $(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)"
        fi
    done
    echo ""
    
    # Server Certificates
    echo "Server Certificates:"
    for cert_file in "${SERVER_DIR}"/*.crt; do
        if [[ -f "$cert_file" ]]; then
            local cert_name=$(basename "$cert_file" .crt)
            echo "  ${cert_name}:"
            echo "    Subject: $(openssl x509 -in "$cert_file" -noout -subject | cut -d= -f2-)"
            echo "    Valid until: $(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)"
        fi
    done
}

# Main execution
main() {
    echo "=================================================="
    echo "Kubernetes TLS Certificate Generation"
    echo "Certificate Validity: ${CERT_VALIDITY_DAYS} days"
    echo "Key Size: ${KEY_SIZE} bits"
    echo "=================================================="
    
    # Check if running on master-1
    local current_hostname=$(hostname)
    if [[ "$current_hostname" != "master-1" ]] && [[ "$current_hostname" != "kubernetes-ha-master-1" ]]; then
        error "This script must be run on master-1"
        exit 1
    fi
    
    # Check prerequisites
    if ! command -v openssl &> /dev/null; then
        error "OpenSSL is not installed"
        exit 1
    fi
    
    # Setup directories
    setup_directories
    
    # Generate CA
    generate_ca
    
    # Generate client certificates
    generate_client_cert "admin" "admin" "system:masters"
    generate_client_cert "kube-controller-manager" "system:kube-controller-manager"
    generate_client_cert "kube-proxy" "system:kube-proxy"
    generate_client_cert "kube-scheduler" "system:kube-scheduler"
    generate_client_cert "service-account" "service-accounts"
    
    # Create server certificate configs
    create_apiserver_config
    create_etcd_config
    
    # Generate server certificates
    generate_server_cert "kube-apiserver" "kube-apiserver" "openssl-apiserver.cnf"
    generate_server_cert "etcd-server" "etcd-server" "openssl-etcd.cnf"
    
    # Distribute certificates
    distribute_certificates
    
    # Display certificate information
    display_certificate_info
    
    log "All certificates generated successfully!"
    
    # Display summary
    echo ""
    echo "=================================================="
    echo "CERTIFICATE SUMMARY"
    echo "=================================================="
    echo "CA Certificate: ${CA_DIR}/ca.crt"
    echo "Client Certificates: ${CLIENT_DIR}/"
    echo "Server Certificates: ${SERVER_DIR}/"
    echo ""
    echo "Certificates have been distributed to master-2"
    echo "Certificate validity: ${CERT_VALIDITY_DAYS} days"
    echo "=================================================="
}

# Run main function
main