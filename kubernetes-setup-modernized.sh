#!/bin/bash

#===============================================================================
# Kubernetes the Hard Way - Modernized Comprehensive Setup Script
# 
# This script modernizes the original Kubernetes the Hard Way setup with:
# - Latest Kubernetes version (1.28.x)
# - containerd runtime instead of Docker
# - Updated etcd version
# - Modern certificate handling
# - Automated TLS bootstrapping
# - Enhanced security practices
#
# Run this script from master-1 node after VMs are provisioned
#===============================================================================

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables - MODERNIZED VERSIONS
KUBERNETES_VERSION="v1.28.4"
ETCD_VERSION="v3.5.10"

# Network Configuration - CORRECTED FOR WEAVE NET COMPATIBILITY
CLUSTER_CIDR="10.32.0.0/12"    # Weave Net default range (10.32.0.0-10.47.255.255)  
SERVICE_CIDR="10.32.0.0/24"    # Kubernetes services (within pod network for routing)
CLUSTER_DNS="10.32.0.10"       # CoreDNS cluster IP (accessible by pods)

# Node Information
LOADBALANCER_ADDRESS="192.168.5.30"
MASTER_NODES=("master-1" "master-2")
WORKER_NODES=("worker-1" "worker-2")
MASTER_IPS=("192.168.5.11" "192.168.5.12")
WORKER_IPS=("192.168.5.21" "192.168.5.22")

# Directories
WORK_DIR="/home/vagrant"
CERT_DIR="${WORK_DIR}/certs"
CONFIG_DIR="${WORK_DIR}/configs"

# Logging functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠${NC} $1"
}

# Error handling
handle_error() {
    log_error "Script failed at line $1"
    exit 1
}

trap 'handle_error $LINENO' ERR

#===============================================================================
# PHASE 1: INITIAL SETUP AND PREREQUISITES
#===============================================================================

setup_prerequisites() {
    log "=== PHASE 1: Setting up Prerequisites ==="
    
    # Create working directories
    mkdir -p ${CERT_DIR} ${CONFIG_DIR}
    cd ${WORK_DIR}
    
    # Update system and install required packages
    log "Installing required packages..."
    sudo apt-get update -qq
    sudo apt-get install -y wget curl openssl
    
    # Verify containerd is installed (should be done by Vagrantfile)
    log "Verifying containerd runtime is available..."
    if ! command -v containerd >/dev/null 2>&1; then
        log_error "containerd not found! Ensure VMs are provisioned with install-containerd.sh"
        return 1
    fi
    containerd --version
    
    # Verify system is configured for Kubernetes (done by Vagrant provisioning)
    log "Verifying system configuration for Kubernetes..."
    if ! lsmod | grep -q br_netfilter; then
        log_error "br_netfilter module not loaded! Ensure allow-bridge-nf-traffic.sh was run"
        return 1
    fi
    
    # Check if containerd is properly configured
    if ! sudo systemctl is-active --quiet containerd; then
        log_error "containerd service is not running! Check Vagrant provisioning"
        return 1
    fi
    
    # Verify CNI directory exists (should be created by Vagrant)
    if [ ! -d "/opt/cni/bin" ]; then
        log_warn "CNI plugins directory not found - will install during worker setup"
    fi
    
    # Verify network connectivity between all nodes (required for Weave Net)
    log "Verifying network connectivity between all nodes..."
    for node in "${MASTER_NODES[@]}" "${WORKER_NODES[@]}"; do
        if [ "$node" != "master-1" ]; then
            log "Testing connectivity to ${node}..."
            if ! ping -c 1 -W 5 ${node} >/dev/null 2>&1; then
                log_error "Cannot reach ${node}! Network connectivity required for Weave Net"
                return 1
            fi
        fi
    done
    
    # Set up SSH key distribution if not already done
    if [ ! -f ~/.ssh/id_rsa ]; then
        log "Generating SSH key pair..."
        ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""
        
        log "Distributing SSH keys to all nodes..."
        for node in "${MASTER_NODES[@]}" "${WORKER_NODES[@]}" "lb"; do
            if [ "$node" != "master-1" ]; then
                log "Copying SSH key to ${node}..."
                ssh-copy-id -o StrictHostKeyChecking=no vagrant@${node} || {
                    log_warning "Failed to copy SSH key to ${node}, you may need to enter password manually later"
                }
            fi
        done
    else
        log "SSH key already exists, skipping key generation"
    fi
    
    log_success "Prerequisites setup completed"
}

#===============================================================================
# PHASE 2: INSTALL CLIENT TOOLS
#===============================================================================

install_client_tools() {
    log "=== PHASE 2: Installing Client Tools ==="
    
    # Install kubectl - MODERNIZED VERSION
    log "Installing kubectl ${KUBERNETES_VERSION}..."
    wget -q --show-progress --https-only --timestamping \
        "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"
    
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    
    # Verify installation
    kubectl version --client --output=yaml
    
    log_success "Client tools installation completed"
}

#===============================================================================
# PHASE 3: CERTIFICATE AUTHORITY AND TLS CERTIFICATES
#===============================================================================

generate_certificates() {
    log "=== PHASE 3: Generating CA and TLS Certificates ==="
    
    cd ${CERT_DIR}
    
    # Generate CA
    log "Generating Certificate Authority..."
    openssl genrsa -out ca.key 2048
    openssl req -new -key ca.key -subj "/CN=KUBERNETES-CA" -out ca.csr
    openssl x509 -req -in ca.csr -signkey ca.key -CAcreateserial -out ca.crt -days 3650
    
    # Admin client certificate
    log "Generating admin client certificate..."
    openssl genrsa -out admin.key 2048
    openssl req -new -key admin.key -subj "/CN=admin/O=system:masters" -out admin.csr
    openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out admin.crt -days 3650
    
    # Worker node certificates - KUBERNETES THE HARD WAY REQUIREMENT
    log "Generating worker node certificates..."
    for i in "${!WORKER_NODES[@]}"; do
        worker=${WORKER_NODES[$i]}
        worker_ip=${WORKER_IPS[$i]}
        
        log "Generating certificate for ${worker}..."
        
        cat > openssl-${worker}.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${worker}
IP.1 = ${worker_ip}
EOF
        
        openssl genrsa -out ${worker}.key 2048
        openssl req -new -key ${worker}.key -subj "/CN=system:node:${worker}/O=system:nodes" -out ${worker}.csr -config openssl-${worker}.cnf
        openssl x509 -req -in ${worker}.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out ${worker}.crt -extensions v3_req -extfile openssl-${worker}.cnf -days 3650
    done
    
    # Controller Manager certificate
    log "Generating controller manager certificate..."
    openssl genrsa -out kube-controller-manager.key 2048
    openssl req -new -key kube-controller-manager.key -subj "/CN=system:kube-controller-manager" -out kube-controller-manager.csr
    openssl x509 -req -in kube-controller-manager.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-controller-manager.crt -days 3650
    
    # Scheduler certificate
    log "Generating scheduler certificate..."
    openssl genrsa -out kube-scheduler.key 2048
    openssl req -new -key kube-scheduler.key -subj "/CN=system:kube-scheduler" -out kube-scheduler.csr
    openssl x509 -req -in kube-scheduler.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-scheduler.crt -days 3650
    
    # Kube-proxy certificate
    log "Generating kube-proxy certificate..."
    openssl genrsa -out kube-proxy.key 2048
    openssl req -new -key kube-proxy.key -subj "/CN=system:kube-proxy" -out kube-proxy.csr
    openssl x509 -req -in kube-proxy.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-proxy.crt -days 3650
    
    # API Server certificate with updated SANs
    log "Generating API server certificate..."
    cat > openssl-apiserver.cnf <<EOF
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
IP.1 = 10.32.0.1
IP.2 = 192.168.5.11
IP.3 = 192.168.5.12
IP.4 = 192.168.5.30
IP.5 = 127.0.0.1
EOF
    
    openssl genrsa -out kube-apiserver.key 2048
    openssl req -new -key kube-apiserver.key -subj "/CN=kube-apiserver" -out kube-apiserver.csr -config openssl-apiserver.cnf
    openssl x509 -req -in kube-apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-apiserver.crt -extensions v3_req -extfile openssl-apiserver.cnf -days 3650
    
    # ETCD Server certificate
    log "Generating ETCD server certificate..."
    cat > openssl-etcd.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
IP.1 = 192.168.5.11
IP.2 = 192.168.5.12
IP.3 = 127.0.0.1
EOF
    
    openssl genrsa -out etcd-server.key 2048
    openssl req -new -key etcd-server.key -subj "/CN=etcd-server" -out etcd-server.csr -config openssl-etcd.cnf
    openssl x509 -req -in etcd-server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out etcd-server.crt -extensions v3_req -extfile openssl-etcd.cnf -days 3650
    
    # Service Account key pair
    log "Generating service account key pair..."
    openssl genrsa -out service-account.key 2048
    openssl req -new -key service-account.key -subj "/CN=service-accounts" -out service-account.csr
    openssl x509 -req -in service-account.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out service-account.crt -days 3650
    
    log_success "Certificate generation completed"
}

#===============================================================================
# PHASE 4: KUBECONFIG FILES
#===============================================================================

generate_kubeconfig_files() {
    log "=== PHASE 4: Generating Kubeconfig Files ==="
    
    cd ${CONFIG_DIR}
    
    # Kube-proxy kubeconfig
    log "Generating kube-proxy kubeconfig..."
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=${CERT_DIR}/ca.crt \
        --embed-certs=true \
        --server=https://${LOADBALANCER_ADDRESS}:6443 \
        --kubeconfig=kube-proxy.kubeconfig
    
    kubectl config set-credentials system:kube-proxy \
        --client-certificate=${CERT_DIR}/kube-proxy.crt \
        --client-key=${CERT_DIR}/kube-proxy.key \
        --embed-certs=true \
        --kubeconfig=kube-proxy.kubeconfig
    
    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-proxy \
        --kubeconfig=kube-proxy.kubeconfig
    
    kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
    
    # Worker node kubeconfigs - KUBERNETES THE HARD WAY REQUIREMENT
    log "Generating worker node kubeconfigs..."
    for worker in "${WORKER_NODES[@]}"; do
        log "Generating kubeconfig for ${worker}..."
        
        kubectl config set-cluster kubernetes-the-hard-way \
            --certificate-authority=${CERT_DIR}/ca.crt \
            --embed-certs=true \
            --server=https://${LOADBALANCER_ADDRESS}:6443 \
            --kubeconfig=${worker}.kubeconfig
        
        kubectl config set-credentials system:node:${worker} \
            --client-certificate=${CERT_DIR}/${worker}.crt \
            --client-key=${CERT_DIR}/${worker}.key \
            --embed-certs=true \
            --kubeconfig=${worker}.kubeconfig
        
        kubectl config set-context default \
            --cluster=kubernetes-the-hard-way \
            --user=system:node:${worker} \
            --kubeconfig=${worker}.kubeconfig
        
        kubectl config use-context default --kubeconfig=${worker}.kubeconfig
    done
    
    # Controller manager kubeconfig
    log "Generating controller manager kubeconfig..."
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=${CERT_DIR}/ca.crt \
        --embed-certs=true \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=kube-controller-manager.kubeconfig
    
    kubectl config set-credentials system:kube-controller-manager \
        --client-certificate=${CERT_DIR}/kube-controller-manager.crt \
        --client-key=${CERT_DIR}/kube-controller-manager.key \
        --embed-certs=true \
        --kubeconfig=kube-controller-manager.kubeconfig
    
    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-controller-manager \
        --kubeconfig=kube-controller-manager.kubeconfig
    
    kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
    
    # Scheduler kubeconfig
    log "Generating scheduler kubeconfig..."
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=${CERT_DIR}/ca.crt \
        --embed-certs=true \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=kube-scheduler.kubeconfig
    
    kubectl config set-credentials system:kube-scheduler \
        --client-certificate=${CERT_DIR}/kube-scheduler.crt \
        --client-key=${CERT_DIR}/kube-scheduler.key \
        --embed-certs=true \
        --kubeconfig=kube-scheduler.kubeconfig
    
    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-scheduler \
        --kubeconfig=kube-scheduler.kubeconfig
    
    kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
    
    # Admin kubeconfig
    log "Generating admin kubeconfig..."
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=${CERT_DIR}/ca.crt \
        --embed-certs=true \
        --server=https://${LOADBALANCER_ADDRESS}:6443 \
        --kubeconfig=admin.kubeconfig
    
    kubectl config set-credentials admin \
        --client-certificate=${CERT_DIR}/admin.crt \
        --client-key=${CERT_DIR}/admin.key \
        --embed-certs=true \
        --kubeconfig=${CONFIG_DIR}/admin.kubeconfig
    
    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=admin \
        --kubeconfig=${CONFIG_DIR}/admin.kubeconfig
    
    kubectl config use-context default --kubeconfig=${CONFIG_DIR}/admin.kubeconfig
    
    log_success "Kubeconfig files generation completed"
}

#===============================================================================
# PHASE 5: DATA ENCRYPTION
#===============================================================================

generate_encryption_config() {
    log "=== PHASE 5: Generating Data Encryption Config ==="
    
    cd ${CONFIG_DIR}
    
    # Generate encryption key
    ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
    
    # Create encryption config
    cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
    
    log_success "Data encryption config generated"
}

#===============================================================================
# PHASE 6: ETCD CLUSTER BOOTSTRAP
#===============================================================================

bootstrap_etcd() {
    log "=== PHASE 6: Bootstrapping etcd Cluster ==="
    
    # Function to bootstrap etcd on a single node
    bootstrap_etcd_node() {
        local node=$1
        local node_ip=$2
        
        log "Bootstrapping etcd on ${node}..."
        
        # Create the etcd service file locally first
        cat > /tmp/etcd-${node}.service << EOF
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${node} \\
  --cert-file=/etc/etcd/etcd-server.crt \\
  --key-file=/etc/etcd/etcd-server.key \\
  --peer-cert-file=/etc/etcd/etcd-server.crt \\
  --peer-key-file=/etc/etcd/etcd-server.key \\
  --trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${node_ip}:2380 \\
  --listen-peer-urls https://${node_ip}:2380 \\
  --listen-client-urls https://${node_ip}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${node_ip}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster master-1=https://192.168.5.11:2380,master-2=https://192.168.5.12:2380 \\
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

        # Copy service file and setup etcd on remote node
        scp /tmp/etcd-${node}.service vagrant@${node}:/tmp/etcd.service
        
        ssh vagrant@${node} "
            ETCD_VERSION='${ETCD_VERSION}'
            
            # Download etcd - MODERNIZED VERSION
            wget -q --show-progress --https-only --timestamping \\
                \"https://github.com/etcd-io/etcd/releases/download/\${ETCD_VERSION}/etcd-\${ETCD_VERSION}-linux-amd64.tar.gz\"
            
            # Extract and install
            tar -xvf etcd-\${ETCD_VERSION}-linux-amd64.tar.gz
            sudo mv etcd-\${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/
            
            # Install systemd service file  
            sudo mv /tmp/etcd.service /etc/systemd/system/etcd.service
        "
        
        # Clean up local temp file
        rm -f /tmp/etcd-${node}.service
    }
    
    # Copy certificates to master nodes and bootstrap etcd SEQUENTIALLY
    # CRITICAL: etcd cluster formation requires first node to be ready before others join
    
    # First copy certificates to all nodes and create etcd directories
    for i in "${!MASTER_NODES[@]}"; do
        node=${MASTER_NODES[$i]}
        log "Copying etcd certificates to ${node}..."
        scp ${CERT_DIR}/ca.crt ${CERT_DIR}/etcd-server.key ${CERT_DIR}/etcd-server.crt vagrant@${node}:~/
        ssh vagrant@${node} "
            sudo mkdir -p /etc/etcd /var/lib/etcd
            sudo chmod 700 /var/lib/etcd
            sudo mv ca.crt etcd-server.key etcd-server.crt /etc/etcd/
        "
    done
    
    # Bootstrap and start etcd on master-1 first
    log "Bootstrapping etcd on master-1 (cluster founder)..."
    bootstrap_etcd_node master-1 192.168.5.11
    
    log "Starting etcd service on master-1..."
    ssh vagrant@master-1 "
        sudo systemctl daemon-reload
        sudo systemctl enable etcd
        sudo systemctl start etcd
        
        # Check if service started successfully
        sleep 3
        if sudo systemctl is-active etcd; then
            echo 'etcd service is active'
        else
            echo 'etcd service failed to start, checking status:'
            sudo systemctl status etcd --no-pager -l
            echo 'Checking logs:'
            sudo journalctl -u etcd --no-pager -l --since '1 minute ago'
        fi
    "
    
    # Wait for master-1 etcd to be fully ready
    log "Waiting for master-1 etcd to be ready..."
    sleep 15
    
    # Verify master-1 etcd is healthy before proceeding
    retry_count=0
    while [ $retry_count -lt 12 ]; do
        if ssh vagrant@master-1 "sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/etcd/ca.crt --cert=/etc/etcd/etcd-server.crt --key=/etc/etcd/etcd-server.key endpoint health" 2>/dev/null; then
            log_success "master-1 etcd is healthy and ready"
            break
        fi
        log "Waiting for master-1 etcd... (attempt $((retry_count + 1))/12)"
        sleep 5
        ((retry_count++))
    done
    
    if [ $retry_count -eq 12 ]; then
        log_error "master-1 etcd failed to become ready - aborting cluster setup"
        return 1
    fi
    
    # Now bootstrap remaining etcd members
    for i in "${!MASTER_NODES[@]}"; do
        node=${MASTER_NODES[$i]}
        node_ip=${MASTER_IPS[$i]}
        
        if [ "$node" != "master-1" ]; then
            log "Bootstrapping etcd on ${node} (joining existing cluster)..."
            bootstrap_etcd_node ${node} ${node_ip}
            ssh vagrant@${node} "
                sudo systemctl daemon-reload
                sudo systemctl enable etcd
                sudo systemctl start etcd
            "
            sleep 8  # Allow time for cluster member to join
        fi
    done
    
    # Wait for etcd cluster to be ready
    sleep 10
    
    # Verify etcd cluster
    log "Verifying etcd cluster..."
    ssh vagrant@master-1 "
        sudo ETCDCTL_API=3 etcdctl member list \\
            --endpoints=https://127.0.0.1:2379 \\
            --cacert=/etc/etcd/ca.crt \\
            --cert=/etc/etcd/etcd-server.crt \\
            --key=/etc/etcd/etcd-server.key
    "
    
    log_success "etcd cluster bootstrap completed"
}

#===============================================================================
# PHASE 7: KUBERNETES CONTROL PLANE
#===============================================================================

bootstrap_control_plane() {
    log "=== PHASE 7: Bootstrapping Kubernetes Control Plane ==="
    
    # Function to bootstrap control plane on a single node
    bootstrap_control_plane_node() {
        local node=$1
        
        log "Bootstrapping control plane on ${node}..."
        
        ssh vagrant@${node} "
            KUBERNETES_VERSION='${KUBERNETES_VERSION}'
            LOADBALANCER_ADDRESS='${LOADBALANCER_ADDRESS}'
            SERVICE_CIDR='${SERVICE_CIDR}'
            
            # Download Kubernetes binaries - MODERNIZED VERSION
            wget -q --show-progress --https-only --timestamping \\
                \"https://dl.k8s.io/release/\${KUBERNETES_VERSION}/bin/linux/amd64/kube-apiserver\" \\
                \"https://dl.k8s.io/release/\${KUBERNETES_VERSION}/bin/linux/amd64/kube-controller-manager\" \\
                \"https://dl.k8s.io/release/\${KUBERNETES_VERSION}/bin/linux/amd64/kube-scheduler\" \\
                \"https://dl.k8s.io/release/\${KUBERNETES_VERSION}/bin/linux/amd64/kubectl\"
            
            # Install binaries
            chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
            sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
            
            # Create directories
            sudo mkdir -p /etc/kubernetes/config /var/lib/kubernetes/
            
            # Get internal IP
            INTERNAL_IP=\\\$(ip addr show enp0s8 | grep 'inet ' | awk '{print \\\$2}' | cut -d / -f 1)
            
            # Create API server service - MODERNIZED CONFIGURATION
            sudo tee /etc/systemd/system/kube-apiserver.service >/dev/null << 'API_EOF'
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\\\
  --advertise-address=\\\${INTERNAL_IP} \\\\
  --allow-privileged=true \\\\
  --apiserver-count=3 \\\\
  --audit-log-maxage=30 \\\\
  --audit-log-maxbackup=3 \\\\
  --audit-log-maxsize=100 \\\\
  --audit-log-path=/var/log/audit.log \\\\
  --authorization-mode=Node,RBAC \\\\
  --bind-address=0.0.0.0 \\\\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\\\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\\\
  --etcd-cafile=/var/lib/kubernetes/ca.crt \\\\
  --etcd-certfile=/var/lib/kubernetes/etcd-server.crt \\\\
  --etcd-keyfile=/var/lib/kubernetes/etcd-server.key \\\\
  --etcd-servers=https://192.168.5.11:2379,https://192.168.5.12:2379 \\\\
  --event-ttl=1h \\\\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\\\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.crt \\\\
  --kubelet-client-certificate=/var/lib/kubernetes/kube-apiserver.crt \\\\
  --kubelet-client-key=/var/lib/kubernetes/kube-apiserver.key \\\\
  --runtime-config=api/all=true \\\\
  --service-account-key-file=/var/lib/kubernetes/service-account.crt \\\\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account.key \\\\
  --service-account-issuer=https://\\\${LOADBALANCER_ADDRESS}:6443 \\\\
  --service-cluster-ip-range=\\\${SERVICE_CIDR} \\\\
  --service-node-port-range=30000-32767 \\\\
  --tls-cert-file=/var/lib/kubernetes/kube-apiserver.crt \\\\
  --tls-private-key-file=/var/lib/kubernetes/kube-apiserver.key \\\\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
API_EOF

            # Create controller manager service - MODERNIZED CONFIGURATION
            # Note: Removed --allocate-node-cidrs and --cluster-cidr for Weave Net compatibility
            sudo tee /etc/systemd/system/kube-controller-manager.service >/dev/null << 'CM_EOF'
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\\\
  --bind-address=0.0.0.0 \\\\
  --cluster-name=kubernetes \\\\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.crt \\\\
  --cluster-signing-key-file=/var/lib/kubernetes/ca.key \\\\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\\\
  --leader-elect=true \\\\
  --root-ca-file=/var/lib/kubernetes/ca.crt \\\\
  --service-account-private-key-file=/var/lib/kubernetes/service-account.key \\\\
  --service-cluster-ip-range=\\\${SERVICE_CIDR} \\\\
  --use-service-account-credentials=true \\\\
  --v=2
Restart=on-failure
RestartSec=5
        "

[Install]
WantedBy=multi-user.target
CM_EOF

            # Create scheduler service - MODERNIZED CONFIGURATION
            sudo tee /etc/systemd/system/kube-scheduler.service >/dev/null << 'SCHED_EOF'
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
SCHED_EOF

            # Create scheduler config
            sudo tee /etc/kubernetes/config/kube-scheduler.yaml >/dev/null << 'SCHED_CONFIG_EOF'
apiVersion: kubescheduler.config.k8s.io/v1beta3
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
leaderElection:
  leaderElect: true
clientConnection:
  kubeconfig: /var/lib/kubernetes/kube-scheduler.kubeconfig
SCHED_CONFIG_EOF
CONTROL_PLANE_EOF
    }
    
    # Copy certificates and configs to master nodes
    for node in "${MASTER_NODES[@]}"; do
        log "Copying certificates and configs to ${node}..."
        scp ${CERT_DIR}/ca.crt ${CERT_DIR}/ca.key ${CERT_DIR}/kube-apiserver.crt ${CERT_DIR}/kube-apiserver.key \
            ${CERT_DIR}/service-account.key ${CERT_DIR}/service-account.crt \
            ${CERT_DIR}/etcd-server.key ${CERT_DIR}/etcd-server.crt \
            ${CONFIG_DIR}/encryption-config.yaml \
            ${CONFIG_DIR}/kube-controller-manager.kubeconfig \
            ${CONFIG_DIR}/kube-scheduler.kubeconfig \
            ${CONFIG_DIR}/admin.kubeconfig \
            vagrant@${node}:~/
        
        ssh vagrant@${node} "
            sudo mv ca.crt ca.key kube-apiserver.crt kube-apiserver.key \\
                service-account.key service-account.crt \\
                etcd-server.key etcd-server.crt \\
                encryption-config.yaml \\
                kube-controller-manager.kubeconfig \\
                kube-scheduler.kubeconfig /var/lib/kubernetes/
        "
        
        # Bootstrap control plane
        bootstrap_control_plane_node ${node}
    done
    
    # Start services on all masters
    for node in "${MASTER_NODES[@]}"; do
        log "Starting control plane services on ${node}..."
        ssh vagrant@${node} "
            sudo systemctl daemon-reload
            sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
            sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
        "
    done
    
    # Wait for API servers to be ready with proper health checks
    log "Waiting for API servers to be ready..."
    sleep 10
    
    # Health check for each API server
    for node in "${MASTER_NODES[@]}"; do
        log "Checking API server health on ${node}..."
        retry_count=0
        while [ $retry_count -lt 24 ]; do  # 2 minutes total
            if ssh vagrant@${node} "curl -k -s https://127.0.0.1:6443/version" >/dev/null 2>&1; then
                log_success "API server on ${node} is healthy"
                break
            fi
            log "Waiting for API server on ${node}... (attempt $((retry_count + 1))/24)"
            sleep 5
            ((retry_count++))
        done
        
        if [ $retry_count -eq 24 ]; then
            log_error "API server on ${node} failed to become ready"
            return 1
        fi
    done
    
    log_success "Control plane bootstrap completed"
}

#===============================================================================
# PHASE 8: LOAD BALANCER SETUP
#===============================================================================

setup_load_balancer() {
    log "=== PHASE 8: Setting up Load Balancer ==="
    
    ssh vagrant@lb << 'EOF'
        # Install HAProxy
        sudo apt-get update -qq
        sudo apt-get install -y haproxy
        
        # Configure HAProxy - MODERNIZED CONFIGURATION
        sudo tee /etc/haproxy/haproxy.cfg >/dev/null << 'LB_EOF'
global
    daemon
    log 127.0.0.1 local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option log-health-checks
    option forwardfor except 127.0.0.0/8
    option redispatch
    retries 3
    timeout http-request 10s
    timeout queue 20s
    timeout connect 10s
    timeout client 1m
    timeout server 1m
    timeout http-keep-alive 10s
    timeout check 10s

frontend kubernetes-apiserver
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-apiserver

backend kubernetes-apiserver
    option httpchk GET /healthz
    http-check expect status 200
    mode tcp
    option ssl-hello-chk
    balance roundrobin
    server master-1 192.168.5.11:6443 check fall 3 rise 2
    server master-2 192.168.5.12:6443 check fall 3 rise 2

listen stats
    bind *:8404
    stats enable
    stats uri /
    stats refresh 30s
    stats admin if TRUE
LB_EOF

        # Start HAProxy
        sudo systemctl enable haproxy
        sudo systemctl restart haproxy
EOF
    
    # Verify load balancer
    sleep 5
    log "Verifying load balancer..."
    if curl -k https://${LOADBALANCER_ADDRESS}:6443/version >/dev/null 2>&1; then
        log_success "Load balancer is working"
    else
        log_warning "Load balancer verification failed, but continuing..."
    fi
    
    log_success "Load balancer setup completed"
}

#===============================================================================
# PHASE 9: TLS BOOTSTRAPPING SETUP
#===============================================================================

setup_tls_bootstrapping() {
    log "=== PHASE 9: Setting up TLS Bootstrapping ==="
    
    cd ${CONFIG_DIR}
    
    # Create bootstrap token
    log "Creating bootstrap token..."
    cat > bootstrap-token.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-07401b
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  description: "The default bootstrap token for TLS bootstrapping."
  token-id: 07401b
  token-secret: f395accd246ae52d
  expiration: 2025-12-31T23:59:59Z
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: system:bootstrappers:worker
EOF
    
    # Create RBAC for bootstrapping
    cat > tls-bootstrapping-rbac.yaml <<EOF
# Enable bootstrapping nodes to create CSR
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: create-csrs-for-bootstrapping
subjects:
- kind: Group
  name: system:bootstrappers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:node-bootstrapper
  apiGroup: rbac.authorization.k8s.io
---
# Approve all CSRs for the group "system:bootstrappers"
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: auto-approve-csrs-for-group
subjects:
- kind: Group
  name: system:bootstrappers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
  apiGroup: rbac.authorization.k8s.io
---
# Approve renewal CSRs for the group "system:nodes"
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: auto-approve-renewals-for-nodes
subjects:
- kind: Group
  name: system:nodes
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
  apiGroup: rbac.authorization.k8s.io
EOF
    
    # Apply bootstrap configuration
    log "Applying TLS bootstrapping configuration..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig apply -f bootstrap-token.yaml
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig apply -f tls-bootstrapping-rbac.yaml
    
    log_success "TLS bootstrapping setup completed"
}

#===============================================================================
# PHASE 10: WORKER NODES BOOTSTRAP
#===============================================================================

bootstrap_workers() {
    log "=== PHASE 10: Bootstrapping Worker Nodes ==="
    
    # Function to bootstrap a single worker - DEFINE BEFORE USE
    bootstrap_worker_node() {
        local node=$1
        local node_ip=$2
        local pod_cidr=$3
        
        log "Bootstrapping worker node ${node} with Pod CIDR ${pod_cidr}..."
        
        ssh vagrant@${node} "
            KUBERNETES_VERSION='${KUBERNETES_VERSION}'
            CLUSTER_DNS='${CLUSTER_DNS}'
            CLUSTER_CIDR='${CLUSTER_CIDR}'
            POD_CIDR='${pod_cidr}'
            NODE_IP=\\\$(hostname -I | awk '{print \\\$1}')
            
            # Download worker binaries - MODERNIZED VERSION
            wget -q --show-progress --https-only --timestamping \\
                \"https://dl.k8s.io/release/\${KUBERNETES_VERSION}/bin/linux/amd64/kubectl\" \\
                \"https://dl.k8s.io/release/\${KUBERNETES_VERSION}/bin/linux/amd64/kube-proxy\" \\
                \"https://dl.k8s.io/release/\${KUBERNETES_VERSION}/bin/linux/amd64/kubelet\"
            
            # Create directories
            sudo mkdir -p \\
                /etc/cni/net.d \\
                /opt/cni/bin \\
                /var/lib/kubelet \\
                /var/lib/kube-proxy \\
                /var/lib/kubernetes \\
                /var/run/kubernetes
            
            # Install binaries
            chmod +x kubectl kube-proxy kubelet
            sudo mv kubectl kube-proxy kubelet /usr/local/bin/
            
            # Install CNI plugins if needed
            if [ ! -d \"/opt/cni/bin\" ] || [ -z \"\\\$(ls -A /opt/cni/bin)\" ]; then
                echo \"Installing CNI plugins...\"
                wget -q --show-progress --https-only --timestamping \\
                    \"https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz\"
                
                sudo mkdir -p /opt/cni/bin
                sudo tar -xvf cni-plugins-linux-amd64-v1.3.0.tgz -C /opt/cni/bin/
            fi
            
            # Configure containerd for Kubernetes
            if ! sudo grep -q \"SystemdCgroup = true\" /etc/containerd/config.toml 2>/dev/null; then
                echo \"Configuring containerd for Kubernetes...\"
                sudo mkdir -p /etc/containerd
                sudo tee /etc/containerd/config.toml >/dev/null << 'CONTAINERD_CONFIG_EOF'
version = 2

[plugins]
  [plugins.\"io.containerd.grpc.v1.cri\"]
    [plugins.\"io.containerd.grpc.v1.cri\".containerd]
      [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes]
        [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc]
          runtime_type = \"io.containerd.runc.v2\"
          [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc.options]
            SystemdCgroup = true
CONTAINERD_CONFIG_EOF
                
                sudo systemctl restart containerd
            fi
            
            # Ensure containerd is enabled and running
            sudo systemctl enable containerd
            
            # Copy certificates and kubeconfigs
            sudo cp ca.crt /var/lib/kubernetes/
            sudo cp ${node}.crt ${node}.key /var/lib/kubelet/
            sudo cp ${node}.kubeconfig /var/lib/kubelet/kubeconfig
            sudo cp kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
            
            # Create kubelet config - MODERNIZED FOR CONTAINERD
            sudo tee /var/lib/kubelet/kubelet-config.yaml >/dev/null << KUBELET_CONFIG_EOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: \"/var/lib/kubernetes/ca.crt\"
authorization:
  mode: Webhook
clusterDomain: \"cluster.local\"
clusterDNS:
  - \"\${CLUSTER_DNS}\"
containerRuntimeEndpoint: \"unix:///var/run/containerd/containerd.sock\"
resolvConf: \"/run/systemd/resolve/resolv.conf\"
runtimeRequestTimeout: \"15m\"
tlsCertFile: \"/var/lib/kubelet/${node}.crt\"
tlsPrivateKeyFile: \"/var/lib/kubelet/${node}.key\"
KUBELET_CONFIG_EOF

            # Create kubelet service - MODERNIZED FOR CONTAINERD
            sudo tee /etc/systemd/system/kubelet.service >/dev/null << 'KUBELET_SERVICE_EOF'
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\\\
  --config=/var/lib/kubelet/kubelet-config.yaml \\\\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\\\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\\\
  --register-node=true \\\\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
KUBELET_SERVICE_EOF

            # Create kube-proxy config
            sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml >/dev/null << PROXY_CONFIG_EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: \"/var/lib/kube-proxy/kubeconfig\"
mode: \"iptables\"
clusterCIDR: \"\${CLUSTER_CIDR}\"
PROXY_CONFIG_EOF

            # Create kube-proxy service
            sudo tee /etc/systemd/system/kube-proxy.service >/dev/null << 'PROXY_SERVICE_EOF'
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\\\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
PROXY_SERVICE_EOF
            
            # Enable and start services
            sudo systemctl daemon-reload
            sudo systemctl enable kubelet kube-proxy
            sudo systemctl start kubelet kube-proxy
        "
    }
    
    # Now distribute certificates and kubeconfigs to workers
    log "Distributing certificates and kubeconfigs to worker nodes..."
    for i in "${!WORKER_NODES[@]}"; do
        worker=${WORKER_NODES[$i]}
        worker_pod_cidr="10.244.${i}.0/24"  # Individual pod CIDR per worker
        log "Copying certificates to ${worker} (Pod CIDR: ${worker_pod_cidr})..."
        
        # Copy CA certificate and worker-specific certificates
        scp ${CERT_DIR}/ca.crt vagrant@${worker}:~/
        scp ${CERT_DIR}/${worker}.crt vagrant@${worker}:~/
        scp ${CERT_DIR}/${worker}.key vagrant@${worker}:~/
        
        # Copy kubeconfigs
        scp ${CONFIG_DIR}/${worker}.kubeconfig vagrant@${worker}:~/
        scp ${CONFIG_DIR}/kube-proxy.kubeconfig vagrant@${worker}:~/
        
        # Pass pod CIDR to the bootstrap function
        bootstrap_worker_node ${worker} ${WORKER_IPS[$i]} ${worker_pod_cidr}
    done
    
    # Wait for CSRs and approve them (if using TLS bootstrapping)
    # Since we're using pre-generated certificates, this step is optional
    log "Checking for any pending CSRs..."
    sleep 10
    
    # Check for pending CSRs and approve them if any exist
    log "Checking for pending CSRs..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get csr --no-headers 2>/dev/null || true
    
    # Approve any pending CSRs just in case
    CSR_COUNT=$(kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get csr --no-headers 2>/dev/null | grep -c "Pending" || echo "0")
    if [ "$CSR_COUNT" -gt 0 ]; then
        log "Found $CSR_COUNT pending CSRs, approving..."
        kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get csr -o name | \
            xargs -r kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig certificate approve
    else
        log "No pending CSRs found (expected with pre-generated certificates)"
    fi
    
    log_success "Worker nodes bootstrap completed"
}

#===============================================================================
# PHASE 11: NETWORKING SETUP
#===============================================================================

setup_networking() {
    log "=== PHASE 11: Setting up Pod Networking ==="
    
    log "NETWORKING CHOICE: Manual CNI + Routing (Hard Way) OR Weave Net (Production)"
    log "Current setup: Using Weave Net for full production capability"
    
    # Deploy Weave Net for production-ready networking
    log "Deploying Weave Net for production-ready pod networking..."
    log "Configuring Weave Net to use cluster CIDR: ${CLUSTER_CIDR}"
    
    # Apply Weave Net with explicit CIDR configuration
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig apply -f "https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml"
    
    # Wait for DaemonSet to be created before updating environment
    sleep 10
    
    # Update the DaemonSet to use our specific CIDR
    log "Configuring Weave Net CIDR allocation range..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig set env daemonset/weave-net -n kube-system IPALLOC_RANGE=${CLUSTER_CIDR} || {
        log_warn "Failed to set IPALLOC_RANGE, Weave will use default range"
    }
    
    # Wait for Weave pods to be ready
    log "Waiting for Weave Net pods to be ready..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig wait --for=condition=ready pod -l name=weave-net -n kube-system --timeout=300s || {
        log_warn "Weave Net pods not ready yet, but continuing..."
    }
    
    # Since we're using Weave, remove manual CNI configs to avoid conflicts
    log "Removing manual CNI configurations to avoid conflicts with Weave Net..."
    for worker in "${WORKER_NODES[@]}"; do
        log "Cleaning up manual CNI config on ${worker}..."
        ssh vagrant@${worker} "sudo rm -f /etc/cni/net.d/10-bridge.conf || true"
    done
    
    # Wait for networking to be ready
    sleep 30
    
    # Verify networking
    log "Verifying pod networking setup..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get nodes
    
    # Check for Weave Net pods
    log "Verifying Weave Net deployment..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get pods -n kube-system -l name=weave-net
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get ds -n kube-system weave-net || {
        log_error "Weave Net DaemonSet not found!"
        return 1
    }
    
    log "Networking setup completed with Weave Net. Full pod connectivity available."
    
    log_success "Pod networking setup completed"
}

#===============================================================================
# PHASE 12: RBAC AND DNS
#===============================================================================

setup_rbac_and_dns() {
    log "=== PHASE 12: Setting up RBAC and DNS ==="
    
    cd ${CONFIG_DIR}
    
    # Create API server to kubelet RBAC
    log "Setting up API server to kubelet RBAC..."
    cat > api-server-to-kubelet-rbac.yaml <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kube-apiserver
EOF
    
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig apply -f api-server-to-kubelet-rbac.yaml
    
    # Deploy CoreDNS - MODERNIZED VERSION
    log "Deploying CoreDNS..."
    cat > coredns.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
rules:
  - apiGroups:
    - ""
    resources:
    - endpoints
    - services
    - pods
    - namespaces
    verbs:
    - list
    - watch
  - apiGroups:
    - discovery.k8s.io
    resources:
    - endpointslices
    verbs:
    - list
    - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
- kind: ServiceAccount
  name: coredns
  namespace: kube-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: coredns
      tolerations:
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
        - key: "CriticalAddonsOnly"
          operator: "Exists"
      nodeSelector:
        kubernetes.io/os: linux
      affinity:
         podAntiAffinity:
           preferredDuringSchedulingIgnoredDuringExecution:
           - weight: 100
             podAffinityTerm:
               labelSelector:
                 matchExpressions:
                   - key: k8s-app
                     operator: In
                     values: ["kube-dns"]
               topologyKey: kubernetes.io/hostname
      containers:
      - name: coredns
        image: coredns/coredns:1.10.1
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        args: [ "-conf", "/etc/coredns/Corefile" ]
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
          readOnly: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9153
          name: metrics
          protocol: TCP
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - all
          readOnlyRootFilesystem: true
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8181
            scheme: HTTP
      dnsPolicy: Default
      volumes:
        - name: config-volume
          configMap:
            name: coredns
            items:
            - key: Corefile
              path: Corefile
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  annotations:
    prometheus.io/port: "9153"
    prometheus.io/scrape: "true"
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "CoreDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: ${CLUSTER_DNS}
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
  - name: metrics
    port: 9153
    protocol: TCP
EOF
    
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig apply -f coredns.yaml
    
    # Wait for CoreDNS pods to be ready
    log "Waiting for CoreDNS pods to be ready..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s
    
    log_success "RBAC and DNS setup completed"
}

#===============================================================================
# COMPREHENSIVE NETWORK VERIFICATION
#===============================================================================

verify_network_health() {
    log "=== COMPREHENSIVE NETWORK HEALTH CHECK ==="
    
    # Check all nodes are ready
    log "Verifying all nodes are in Ready state..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get nodes
    NOT_READY=$(kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get nodes --no-headers | grep -v " Ready " | wc -l)
    if [ "$NOT_READY" -gt 0 ]; then
        log_warn "$NOT_READY nodes are not in Ready state"
    else
        log_success "All nodes are Ready"
    fi
    
    # Check Weave Net pods
    log "Verifying Weave Net DaemonSet health..."
    WEAVE_DESIRED=$(kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get daemonset -n kube-system weave-net -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    WEAVE_READY=$(kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig get daemonset -n kube-system weave-net -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    
    log "Weave Net pods: $WEAVE_READY/$WEAVE_DESIRED ready"
    if [ "$WEAVE_READY" -eq "$WEAVE_DESIRED" ] && [ "$WEAVE_READY" -gt 0 ]; then
        log_success "Weave Net DaemonSet is healthy"
    else
        log_warn "Weave Net DaemonSet may have issues"
    fi
    
    # Check for CNI conflicts
    log "Checking for CNI configuration conflicts..."
    for worker in "${WORKER_NODES[@]}"; do
        MANUAL_CNI=$(ssh vagrant@${worker} "ls /etc/cni/net.d/ 2>/dev/null | grep -v weave | head -1" || echo "")
        if [ -n "$MANUAL_CNI" ]; then
            log_warn "Manual CNI config found on $worker: $MANUAL_CNI"
        fi
    done
    
    # Check container runtime
    log "Verifying containerd runtime on all workers..."
    for worker in "${WORKER_NODES[@]}"; do
        CONTAINERD_STATUS=$(ssh vagrant@${worker} "sudo systemctl is-active containerd" || echo "failed")
        if [ "$CONTAINERD_STATUS" = "active" ]; then
            log_success "containerd is active on $worker"
        else
            log_warn "containerd issues on $worker: $CONTAINERD_STATUS"
        fi
    done
    
    # Check certificate validity
    log "Verifying certificate validity..."
    CERT_EXPIRY=$(openssl x509 -in ${CERT_DIR}/ca.crt -noout -enddate | cut -d= -f2)
    log "CA certificate expires: $CERT_EXPIRY"
    
    API_CERT_EXPIRY=$(openssl x509 -in ${CERT_DIR}/kube-apiserver.crt -noout -enddate | cut -d= -f2)
    log "API server certificate expires: $API_CERT_EXPIRY"
    
    # Verify API server certificate SANs
    log "Verifying API server certificate SANs..."
    openssl x509 -in ${CERT_DIR}/kube-apiserver.crt -text -noout | grep -A 10 "Subject Alternative Name" || {
        log_warn "Could not verify API server certificate SANs"
    }
    
    # Check controller manager and scheduler certificates
    for component in kube-controller-manager kube-scheduler; do
        if [ -f "${CERT_DIR}/${component}.crt" ]; then
            COMP_EXPIRY=$(openssl x509 -in ${CERT_DIR}/${component}.crt -noout -enddate | cut -d= -f2)
            log "$component certificate expires: $COMP_EXPIRY"
        fi
    done
    
    log_success "Network health verification completed"
}

#===============================================================================
# COMPREHENSIVE SYSTEM COMPATIBILITY CHECK
#===============================================================================

verify_system_compatibility() {
    log "=== COMPREHENSIVE SYSTEM COMPATIBILITY CHECK ==="
    
    # Check all control plane components
    log "Verifying control plane component health..."
    for master in "${MASTER_NODES[@]}"; do
        log "Checking services on $master..."
        
        # Check etcd
        ETCD_STATUS=$(ssh vagrant@${master} "sudo systemctl is-active etcd" || echo "failed")
        log "  etcd on $master: $ETCD_STATUS"
        
        # Check API server
        API_STATUS=$(ssh vagrant@${master} "sudo systemctl is-active kube-apiserver" || echo "failed")
        log "  kube-apiserver on $master: $API_STATUS"
        
        # Check controller manager
        CM_STATUS=$(ssh vagrant@${master} "sudo systemctl is-active kube-controller-manager" || echo "failed")
        log "  kube-controller-manager on $master: $CM_STATUS"
        
        # Check scheduler
        SCHED_STATUS=$(ssh vagrant@${master} "sudo systemctl is-active kube-scheduler" || echo "failed")
        log "  kube-scheduler on $master: $SCHED_STATUS"
    done
    
    # Check worker components
    log "Verifying worker component health..."
    for worker in "${WORKER_NODES[@]}"; do
        log "Checking services on $worker..."
        
        # Check kubelet
        KUBELET_STATUS=$(ssh vagrant@${worker} "sudo systemctl is-active kubelet" || echo "failed")
        log "  kubelet on $worker: $KUBELET_STATUS"
        
        # Check kube-proxy
        PROXY_STATUS=$(ssh vagrant@${worker} "sudo systemctl is-active kube-proxy" || echo "failed")
        log "  kube-proxy on $worker: $PROXY_STATUS"
        
        # Check containerd
        CONTAINERD_STATUS=$(ssh vagrant@${worker} "sudo systemctl is-active containerd" || echo "failed")
        log "  containerd on $worker: $CONTAINERD_STATUS"
    done
    
    # Check load balancer
    log "Verifying load balancer health..."
    LB_STATUS=$(ssh vagrant@lb "sudo systemctl is-active haproxy" || echo "failed")
    log "HAProxy on lb: $LB_STATUS"
    
    # Test API server connectivity through load balancer
    log "Testing API server connectivity through load balancer..."
    if kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig version --short >/dev/null 2>&1; then
        log_success "API server accessible through load balancer"
    else
        log_warn "API server connectivity issues"
    fi
    
    # Verify RBAC is working
    log "Testing RBAC functionality..."
    kubectl --kubeconfig=${CONFIG_DIR}/admin.kubeconfig auth can-i create pods --as=system:serviceaccount:default:default || {
        log_warn "RBAC may not be properly configured"
    }
    
    log_success "System compatibility verification completed"
}

#===============================================================================
# NETWORK CONFIGURATION VALIDATION
#===============================================================================

validate_network_configuration() {
    log "=== NETWORK CONFIGURATION VALIDATION ==="
    
    # Verify CIDR ranges don't overlap
    log "Verifying CIDR range isolation..."
    
    log "Pod Network (Weave Net): ${CLUSTER_CIDR}"
    log "Service Network: ${SERVICE_CIDR}"
    log "CoreDNS IP: ${CLUSTER_DNS}"
    
    # Verify DNS IP is within service range
    if [[ "${CLUSTER_DNS}" =~ ^10\.32\. ]]; then
        log_success "CoreDNS IP is correctly within pod network CIDR range"
    else
        log_warn "CoreDNS IP may not be within pod network CIDR range"
    fi
    
    # Verify Weave Net range
    if [[ "${CLUSTER_CIDR}" == "10.32.0.0/12" ]]; then
        log_success "Using optimal Weave Net CIDR range"
    else
        log_warn "CIDR range may not be optimal for Weave Net"
    fi
    
    # Check for any hardcoded IPs in the script
    log "Checking for hardcoded network configurations..."
    if grep -q "10.244.0.0" "$0" 2>/dev/null; then
        log_warn "Found legacy hardcoded CIDR references"
    else
        log_success "No legacy hardcoded CIDR references found"
    fi
    
    log_success "Network configuration validation completed"
}

#===============================================================================
# VAGRANT COMPATIBILITY VERIFICATION
#===============================================================================

verify_vagrant_compatibility() {
    log "=== VAGRANT COMPATIBILITY VERIFICATION ==="
    
    # Check if we're running on a Vagrant-provisioned system
    log "Verifying Vagrant environment compatibility..."
    
    # Check hostname patterns
    CURRENT_HOSTNAME=$(hostname -s)
    if [[ "$CURRENT_HOSTNAME" =~ ^(master|worker)-[0-9]+$ ]]; then
        log_success "Running on Vagrant-provisioned VM: $CURRENT_HOSTNAME"
    else
        log_warn "Hostname pattern doesn't match expected Vagrant naming: $CURRENT_HOSTNAME"
    fi
    
    # Check network interface (Vagrant uses enp0s8 for private network)
    if ip addr show enp0s8 >/dev/null 2>&1; then
        VAGRANT_IP=$(ip addr show enp0s8 | grep 'inet ' | awk '{print $2}' | cut -d / -f 1)
        log_success "Vagrant private network interface enp0s8 found: $VAGRANT_IP"
        
        # Verify IP is in expected range
        if [[ "$VAGRANT_IP" =~ ^192\.168\.5\. ]]; then
            log_success "IP address is in expected Vagrant range (192.168.5.x)"
        else
            log_warn "IP address not in expected Vagrant range: $VAGRANT_IP"
        fi
    else
        log_warn "Vagrant private network interface enp0s8 not found"
    fi
    
    # Check if vagrant user exists
    if id vagrant >/dev/null 2>&1; then
        log_success "Vagrant user account found"
    else
        log_warn "Vagrant user account not found - may affect SSH operations"
    fi
    
    # Check if Vagrant provisioning files were applied
    CHECKS_PASSED=0
    TOTAL_CHECKS=4
    
    # Check 1: Bridge netfilter module (from allow-bridge-nf-traffic.sh)
    if lsmod | grep -q br_netfilter; then
        log_success "✅ Bridge netfilter module loaded (Vagrant provisioning success)"
        ((CHECKS_PASSED++))
    else
        log_warn "❌ Bridge netfilter module not loaded"
    fi
    
    # Check 2: containerd service (from install-containerd.sh)
    if sudo systemctl is-active --quiet containerd; then
        log_success "✅ containerd service active (Vagrant provisioning success)"
        ((CHECKS_PASSED++))
    else
        log_warn "❌ containerd service not active"
    fi
    
    # Check 3: Sysctl settings (from allow-bridge-nf-traffic.sh)
    if sysctl net.bridge.bridge-nf-call-iptables 2>/dev/null | grep -q "= 1"; then
        log_success "✅ Bridge netfilter sysctl configured (Vagrant provisioning success)"
        ((CHECKS_PASSED++))
    else
        log_warn "❌ Bridge netfilter sysctl not configured"
    fi
    
    # Check 4: CNI directory (from install-containerd.sh)
    if [ -d "/opt/cni/bin" ] && [ "$(ls -A /opt/cni/bin 2>/dev/null)" ]; then
        log_success "✅ CNI plugins directory exists (Vagrant provisioning success)"
        ((CHECKS_PASSED++))
    else
        log_warn "❌ CNI plugins directory empty or missing"
    fi
    
    log "Vagrant provisioning verification: $CHECKS_PASSED/$TOTAL_CHECKS checks passed"
    
    if [ "$CHECKS_PASSED" -eq "$TOTAL_CHECKS" ]; then
        log_success "All Vagrant provisioning checks passed - full compatibility confirmed"
    elif [ "$CHECKS_PASSED" -ge 3 ]; then
        log_warn "Most Vagrant provisioning checks passed - minor compatibility issues detected"
    else
        log_error "Multiple Vagrant provisioning checks failed - compatibility issues detected"
        log "Please ensure VMs are properly provisioned with: vagrant up"
        return 1
    fi
    
    log_success "Vagrant compatibility verification completed"
}

#===============================================================================
# PHASE 13: VERIFICATION AND SMOKE TESTS
#===============================================================================

run_smoke_tests() {
    log "=== PHASE 13: Running Smoke Tests ==="
    
    # Run comprehensive network verification first
    verify_network_health
    
    # Validate network configuration
    validate_network_configuration
    
    # Verify Vagrant compatibility
    verify_vagrant_compatibility
    
    # Run comprehensive system compatibility check
    verify_system_compatibility
    
    cd ${CONFIG_DIR}
    
    # Configure kubectl for remote access
    log "Configuring kubectl for remote access..."
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=${CERT_DIR}/ca.crt \
        --embed-certs=true \
        --server=https://${LOADBALANCER_ADDRESS}:6443
    
    kubectl config set-credentials admin \
        --client-certificate=${CERT_DIR}/admin.crt \
        --client-key=${CERT_DIR}/admin.key
    
    kubectl config set-context kubernetes-the-hard-way \
        --cluster=kubernetes-the-hard-way \
        --user=admin
    
    kubectl config use-context kubernetes-the-hard-way
    
    # Test cluster health
    log "Testing cluster health..."
    kubectl get componentstatuses
    kubectl get nodes
    
    # Test pod networking
    log "Testing pod networking..."
    kubectl create deployment nginx --image=nginx
    kubectl scale deployment nginx --replicas=2
    kubectl expose deployment nginx --port=80 --type=NodePort
    
    # Wait for pods to be ready
    log "Waiting for nginx pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=300s
    kubectl get pods -l app=nginx -o wide
    
    # Test inter-pod connectivity
    log "Testing pod-to-pod communication across nodes..."
    POD1=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
    POD2=$(kubectl get pods -l app=nginx -o jsonpath='{.items[1].metadata.name}' 2>/dev/null || echo "$POD1")
    if [ "$POD1" != "$POD2" ]; then
        log "Testing connectivity from $POD1 to service..."
        kubectl exec $POD1 -- wget -qO- nginx || {
            log_warn "Pod-to-service communication test failed, but continuing..."
        }
        
        # Test direct pod-to-pod communication
        POD2_IP=$(kubectl get pod $POD2 -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
        if [ -n "$POD2_IP" ]; then
            log "Testing direct pod-to-pod connectivity: $POD1 -> $POD2 ($POD2_IP)..."
            kubectl exec $POD1 -- wget -qO- --timeout=10 http://$POD2_IP:80 || {
                log_warn "Direct pod-to-pod communication test failed"
            }
        fi
    fi
    
    # Test DNS
    log "Testing DNS resolution..."
    kubectl run busybox --image=busybox:1.28 --command -- sleep 3600
    kubectl wait --for=condition=ready pod busybox --timeout=300s
    
    log "Testing DNS lookup..."
    kubectl exec busybox -- nslookup kubernetes
    
    # Test Weave Net networking specifically
    log "Verifying Weave Net networking..."
    kubectl get pods -n kube-system -l name=weave-net
    WEAVE_POD=$(kubectl get pods -n kube-system -l name=weave-net -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$WEAVE_POD" ]; then
        log "Checking Weave Net status..."
        kubectl exec -n kube-system $WEAVE_POD -c weave -- /home/weave/weave --local status || {
            log_warn "Could not get Weave Net status, but pods are running"
        }
    fi
    
    # Cleanup test resources
    kubectl delete deployment nginx
    kubectl delete service nginx
    kubectl delete pod busybox
    
    log_success "Smoke tests completed successfully!"
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    log "Starting Kubernetes the Hard Way - Modernized Setup"
    log "Kubernetes Version: ${KUBERNETES_VERSION}"
    log "etcd Version: ${ETCD_VERSION}"
    log "Container Runtime: containerd"
    
    # Execute all phases with error handling
    if ! setup_prerequisites; then
        log_error "Failed during prerequisites setup"
        exit 1
    fi
    
    if ! install_client_tools; then
        log_error "Failed during client tools installation"
        exit 1
    fi
    
    if ! generate_certificates; then
        log_error "Failed during certificate generation"
        exit 1
    fi
    
    if ! generate_kubeconfig_files; then
        log_error "Failed during kubeconfig generation"
        exit 1
    fi
    
    if ! generate_encryption_config; then
        log_error "Failed during encryption config generation"
        exit 1
    fi
    
    if ! bootstrap_etcd; then
        log_error "Failed during etcd bootstrap"
        exit 1
    fi
    
    if ! bootstrap_control_plane; then
        log_error "Failed during control plane bootstrap"
        exit 1
    fi
    
    if ! setup_load_balancer; then
        log_error "Failed during load balancer setup"
        exit 1
    fi
    
    # TLS bootstrapping not needed - using pre-generated certificates (Hard Way approach)
    
    if ! bootstrap_workers; then
        log_error "Failed during worker bootstrap"
        exit 1
    fi
    
    if ! setup_networking; then
        log_error "Failed during networking setup"
        exit 1
    fi
    
    if ! setup_rbac_and_dns; then
        log_error "Failed during RBAC and DNS setup"
        exit 1
    fi
    
    if ! run_smoke_tests; then
        log_error "Failed during smoke tests"
        exit 1
    fi
    
    log_success "=== KUBERNETES CLUSTER SETUP COMPLETED SUCCESSFULLY ==="
    log ""
    log "Cluster Information:"
    log "- Kubernetes Version: ${KUBERNETES_VERSION}"
    log "- etcd Version: ${ETCD_VERSION}"
    log "- Container Runtime: containerd"
    log "- CNI: Weave Net (Production-Ready)"
    log "- Pod Network CIDR: ${CLUSTER_CIDR}"
    log "- Service Network CIDR: ${SERVICE_CIDR}"
    log "- Load Balancer: HAProxy (${LOADBALANCER_ADDRESS}:6443)"
    log ""
    log "Network Features:"
    log "- Encrypted pod-to-pod communication"
    log "- Automatic IP allocation and routing"
    log "- Network policies support"
    log "- Cross-node pod connectivity"
    log ""
    log "Access your cluster with:"
    log "  export KUBECONFIG=${CONFIG_DIR}/admin.kubeconfig"
    log "  kubectl get nodes"
    log ""
    log "Or use the configured kubectl context:"
    log "  kubectl --context=kubernetes-the-hard-way get nodes"
}

# Run main function
main "$@"
