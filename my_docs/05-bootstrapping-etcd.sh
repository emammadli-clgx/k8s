#!/bin/bash

# bootstrap-etcd.sh
# Purpose: Bootstrap etcd cluster member
# Run on: master-1 and master-2

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ETCD_VERSION="3.5.12"
ETCD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
ETCD_CONFIG_DIR="/etc/etcd"
ETCD_DATA_DIR="/var/lib/etcd"

# Network configuration
NETWORK_INTERFACE="enp0s8"
MASTER1_IP="192.168.5.11"
MASTER2_IP="192.168.5.12"

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" >&2
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" >&2
}

# Get current node information
get_node_info() {
    local hostname=$(hostname -s)
    local internal_ip
    
    # Get internal IP from the correct interface
    if ! internal_ip=$(ip addr show ${NETWORK_INTERFACE} 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d / -f 1); then
        error "Failed to get IP address from interface ${NETWORK_INTERFACE}"
        exit 1
    fi
    
    if [[ -z "$internal_ip" ]]; then
        error "No IP address found on interface ${NETWORK_INTERFACE}"
        exit 1
    fi
    
    echo "${hostname}:${internal_ip}"
}

# Find and prepare certificates
find_and_prepare_certificates() {
    log "Finding and preparing certificates..."
    
    # Check multiple possible locations for certificates
    local cert_locations=(
        # Home directory (distributed copies)
        "$HOME/ca.crt:$HOME/etcd-server.crt:$HOME/etcd-server.key"
        # Organized structure (original location on master-1)
        "./certs/ca/ca.crt:./certs/server/etcd-server.crt:./certs/server/etcd-server.key"
        # Alternative organized structure
        "./certs/ca.crt:./certs/etcd-server.crt:./certs/etcd-server.key"
    )
    
    local found_certs=false
    local ca_cert="" server_cert="" server_key=""
    
    for location in "${cert_locations[@]}"; do
        IFS=':' read -r ca_path server_cert_path server_key_path <<< "$location"
        
        if [[ -f "$ca_path" ]] && [[ -f "$server_cert_path" ]] && [[ -f "$server_key_path" ]]; then
            ca_cert="$ca_path"
            server_cert="$server_cert_path"
            server_key="$server_key_path"
            found_certs=true
            info "Found certificates at: $(dirname "$ca_path")"
            break
        fi
    done
    
    if [[ "$found_certs" != true ]]; then
        error "Could not find required certificates in any expected location"
        exit 1
    fi
    
    # Copy certificates to home directory if they're not already there
    if [[ ! -f "$HOME/ca.crt" ]]; then
        cp "$ca_cert" "$HOME/ca.crt"
        log "Copied CA certificate to home directory"
    fi
    
    if [[ ! -f "$HOME/etcd-server.crt" ]]; then
        cp "$server_cert" "$HOME/etcd-server.crt"
        log "Copied server certificate to home directory"
    fi
    
    if [[ ! -f "$HOME/etcd-server.key" ]]; then
        cp "$server_key" "$HOME/etcd-server.key"
        chmod 600 "$HOME/etcd-server.key"
        log "Copied server key to home directory"
    fi
    
    log "Certificates prepared successfully"
}

# Verify prerequisites
verify_prerequisites() {
    log "Verifying prerequisites..."
    
    # Check if running as non-root user (for sudo commands)
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root (needs sudo for specific commands)"
        exit 1
    fi
    
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        error "This script requires sudo access"
        exit 1
    fi
    
    # Check network interface
    if ! ip addr show ${NETWORK_INTERFACE} > /dev/null 2>&1; then
        error "Network interface ${NETWORK_INTERFACE} not found"
        exit 1
    fi
    
    # Find and prepare certificates
    find_and_prepare_certificates
    
    log "Prerequisites verified"
}

# Download and install etcd binaries
install_etcd() {
    log "Downloading and installing etcd v${ETCD_VERSION}..."
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Download etcd
    if ! wget -q --show-progress --https-only --timestamping "$ETCD_URL"; then
        error "Failed to download etcd"
        exit 1
    fi
    
    # Extract etcd
    tar -xzf "etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
    
    # Install binaries
    sudo mv "etcd-v${ETCD_VERSION}-linux-amd64/etcd" /usr/local/bin/
    sudo mv "etcd-v${ETCD_VERSION}-linux-amd64/etcdctl" /usr/local/bin/
    
    # Set permissions
    sudo chmod +x /usr/local/bin/etcd
    sudo chmod +x /usr/local/bin/etcdctl
    
    # Cleanup
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    # Verify installation
    local etcd_version=$(/usr/local/bin/etcd --version | head -1)
    log "Installed: $etcd_version"
}

# Configure etcd server - FIXED VERSION
configure_etcd() {
    log "Configuring etcd server..."
    
    # Create directories
    sudo mkdir -p ${ETCD_CONFIG_DIR}
    sudo mkdir -p ${ETCD_DATA_DIR}
    
    # Copy certificates from home directory to system location
    sudo cp ~/ca.crt ${ETCD_CONFIG_DIR}/
    sudo cp ~/etcd-server.crt ${ETCD_CONFIG_DIR}/
    sudo cp ~/etcd-server.key ${ETCD_CONFIG_DIR}/
    
    # Set proper permissions - FIXED TO WORK WITH ROOT USER
    sudo chmod 644 ${ETCD_CONFIG_DIR}/ca.crt
    sudo chmod 644 ${ETCD_CONFIG_DIR}/etcd-server.crt
    sudo chmod 600 ${ETCD_CONFIG_DIR}/etcd-server.key
    sudo chown root:root ${ETCD_CONFIG_DIR}/*
    
    # Set data directory permissions for root
    sudo chown root:root ${ETCD_DATA_DIR}
    sudo chmod 755 ${ETCD_DATA_DIR}
    
    log "etcd configuration completed"
}

# Create systemd service file - FIXED TO RUN AS ROOT (like original guide)
create_systemd_service() {
    log "Creating etcd systemd service..."
    
    local node_info=$(get_node_info)
    local etcd_name=$(echo "$node_info" | cut -d: -f1)
    local internal_ip=$(echo "$node_info" | cut -d: -f2)
    
    info "Node: $etcd_name, IP: $internal_ip"
    
    # Create systemd service file - REMOVED User/Group directives to run as root
    sudo tee /etc/systemd/system/etcd.service > /dev/null <<EOF
[Unit]
Description=etcd distributed reliable key-value store
Documentation=https://github.com/etcd-io/etcd
After=network.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${etcd_name} \\
  --data-dir=${ETCD_DATA_DIR} \\
  --cert-file=${ETCD_CONFIG_DIR}/etcd-server.crt \\
  --key-file=${ETCD_CONFIG_DIR}/etcd-server.key \\
  --peer-cert-file=${ETCD_CONFIG_DIR}/etcd-server.crt \\
  --peer-key-file=${ETCD_CONFIG_DIR}/etcd-server.key \\
  --trusted-ca-file=${ETCD_CONFIG_DIR}/ca.crt \\
  --peer-trusted-ca-file=${ETCD_CONFIG_DIR}/ca.crt \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${internal_ip}:2380 \\
  --listen-peer-urls https://${internal_ip}:2380 \\
  --listen-client-urls https://${internal_ip}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${internal_ip}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster master-1=https://${MASTER1_IP}:2380,master-2=https://${MASTER2_IP}:2380 \\
  --initial-cluster-state new \\
  --heartbeat-interval 1000 \\
  --election-timeout 5000 \\
  --max-snapshots 5 \\
  --max-wals 5 \\
  --snapshot-count 10000
Restart=always
RestartSec=10s
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
EOF
    
    log "etcd systemd service created"
}

# Stop and clean existing etcd service
clean_existing_etcd() {
    log "Cleaning existing etcd service..."
    
    # Stop service if running
    if sudo systemctl is-active --quiet etcd; then
        sudo systemctl stop etcd
    fi
    
    # Disable service if enabled
    if sudo systemctl is-enabled --quiet etcd; then
        sudo systemctl disable etcd
    fi
    
    # Remove old data directory contents (but keep the directory)
    if [[ -d "${ETCD_DATA_DIR}" ]]; then
        sudo rm -rf ${ETCD_DATA_DIR}/*
        log "Cleaned etcd data directory"
    fi
}

# Start etcd service
start_etcd() {
    log "Starting etcd service..."
    
    # Clean existing service first
    clean_existing_etcd
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    # Enable etcd service
    sudo systemctl enable etcd
    
    # Start etcd service
    sudo systemctl start etcd
    
    # Wait for service to start
    sleep 10
    
    # Check service status
    if sudo systemctl is-active --quiet etcd; then
        log "etcd service started successfully"
    else
        error "etcd service failed to start"
        echo ""
        echo "=== Service Status ==="
        sudo systemctl status etcd --no-pager -l
        echo ""
        echo "=== Recent Logs ==="
        sudo journalctl -u etcd --no-pager -l -n 10
        exit 1
    fi
}

# Verify etcd installation
verify_etcd() {
    log "Verifying etcd installation..."
    
    # Test etcd connectivity
    local max_attempts=15
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if sudo ETCDCTL_API=3 /usr/local/bin/etcdctl \
            --endpoints=https://127.0.0.1:2379 \
            --cacert=${ETCD_CONFIG_DIR}/ca.crt \
            --cert=${ETCD_CONFIG_DIR}/etcd-server.crt \
            --key=${ETCD_CONFIG_DIR}/etcd-server.key \
            endpoint health >/dev/null 2>&1; then
            log "etcd health check passed"
            break
        else
            if [ $attempt -eq $max_attempts ]; then
                error "etcd health check failed after $max_attempts attempts"
                exit 1
            fi
            warning "etcd health check failed, attempt $attempt/$max_attempts, retrying..."
            sleep 5
            ((attempt++))
        fi
    done
    
    # Show etcd version
    local etcd_version=$(sudo ETCDCTL_API=3 /usr/local/bin/etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=${ETCD_CONFIG_DIR}/ca.crt \
        --cert=${ETCD_CONFIG_DIR}/etcd-server.crt \
        --key=${ETCD_CONFIG_DIR}/etcd-server.key \
        version | head -1)
    
    info "etcd version: $etcd_version"
}

# Main execution
main() {
    local node_info=$(get_node_info)
    local etcd_name=$(echo "$node_info" | cut -d: -f1)
    local internal_ip=$(echo "$node_info" | cut -d: -f2)
    
    echo "=================================================="
    echo "etcd Cluster Bootstrap"
    echo "Node: $etcd_name"
    echo "IP: $internal_ip"
    echo "etcd Version: v${ETCD_VERSION}"
    echo "=================================================="
    
    # Verify prerequisites
    verify_prerequisites
    
    # Install etcd
    install_etcd
    
    # Configure etcd
    configure_etcd
    
    # Create systemd service
    create_systemd_service
    
    # Start etcd
    start_etcd
    
    # Verify installation
    verify_etcd
    
    log "etcd bootstrap completed successfully!"
    
    echo ""
    echo "=================================================="
    echo "ETCD BOOTSTRAP SUMMARY"
    echo "=================================================="
    echo "Node name: $etcd_name"
    echo "Internal IP: $internal_ip"
    echo "Client URL: https://$internal_ip:2379"
    echo "Peer URL: https://$internal_ip:2380"
    echo "Data directory: ${ETCD_DATA_DIR}"
    echo "Config directory: ${ETCD_CONFIG_DIR}"
    echo "Service status: $(sudo systemctl is-active etcd)"
    echo "=================================================="
}

# Run main function
main