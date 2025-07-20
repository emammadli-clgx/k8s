#!/bin/bash

# generate-encryption-config.sh
# Purpose: Generate Kubernetes data encryption configuration
# Run on: master-1

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ENCRYPTION_DIR="./encryption"
ENCRYPTION_CONFIG_FILE="${ENCRYPTION_DIR}/encryption-config.yaml"
KEY_NAME="key1"

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

# Setup directory structure
setup_directories() {
    log "Setting up encryption directory structure..."
    
    mkdir -p "${ENCRYPTION_DIR}"
    chmod 700 "${ENCRYPTION_DIR}"
}

# Verify prerequisites
verify_prerequisites() {
    log "Verifying prerequisites..."
    
    # Check if required tools are available
    local required_tools=("head" "base64")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "Required tool not found: $tool"
            exit 1
        fi
    done
    
    # Check if /dev/urandom is available
    if [[ ! -c /dev/urandom ]]; then
        error "/dev/urandom not available for secure random key generation"
        exit 1
    fi
    
    log "All prerequisites verified"
}

# Generate encryption key - FIXED TO OUTPUT ONLY THE KEY
generate_encryption_key() {
    log "Generating encryption key..."
    
    # Generate 32-byte (256-bit) random key and base64 encode it
    local encryption_key
    encryption_key=$(head -c 32 /dev/urandom | base64)
    
    # Validate key generation
    if [[ -z "$encryption_key" ]]; then
        error "Failed to generate encryption key"
        return 1
    fi
    
    # Validate key length (base64 encoded 32 bytes should be 44 characters + optional padding)
    local key_length=${#encryption_key}
    if [[ $key_length -lt 40 ]] || [[ $key_length -gt 48 ]]; then
        error "Generated key has unexpected length: $key_length characters"
        return 1
    fi
    
    info "Generated 256-bit encryption key (${key_length} characters base64)"
    
    # Only output the key to stdout (everything else goes to stderr)
    echo "$encryption_key"
}

# Create encryption config file
create_encryption_config() {
    local encryption_key=$1
    
    log "Creating encryption configuration file..."
    
    # Create the encryption config YAML
    cat > "${ENCRYPTION_CONFIG_FILE}" <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: ${KEY_NAME}
              secret: ${encryption_key}
      - identity: {}
EOF
    
    # Set proper permissions (contains sensitive encryption key)
    chmod 600 "${ENCRYPTION_CONFIG_FILE}"
    
    log "Encryption configuration file created: ${ENCRYPTION_CONFIG_FILE}"
}

# Validate encryption config
validate_encryption_config() {
    log "Validating encryption configuration..."
    
    # Check if file exists
    if [[ ! -f "${ENCRYPTION_CONFIG_FILE}" ]]; then
        error "Encryption config file not found: ${ENCRYPTION_CONFIG_FILE}"
        return 1
    fi
    
    # Check file permissions
    local perm=$(stat -c "%a" "${ENCRYPTION_CONFIG_FILE}")
    if [[ "$perm" != "600" ]]; then
        error "Encryption config file has incorrect permissions: $perm (expected 600)"
        return 1
    fi
    
    # Basic structure validation (check for required fields)
    local required_fields=(
        "kind: EncryptionConfig"
        "apiVersion: v1"
        "resources:"
        "secrets"
        "providers:"
        "aescbc:"
        "keys:"
        "name: ${KEY_NAME}"
        "secret:"
        "identity:"
    )
    
    for field in "${required_fields[@]}"; do
        if ! grep -q "$field" "${ENCRYPTION_CONFIG_FILE}"; then
            error "Encryption config missing required field: $field"
            return 1
        fi
    done
    
    # Check if the file is readable
    if ! cat "${ENCRYPTION_CONFIG_FILE}" > /dev/null 2>&1; then
        error "Encryption config file is not readable"
        return 1
    fi
    
    # Validate that the secret key looks like base64
    local secret_key=$(awk '/secret:/ {gsub(/^[[:space:]]*secret:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print}' "${ENCRYPTION_CONFIG_FILE}")
    if [[ -n "$secret_key" ]] && echo "$secret_key" | base64 -d > /dev/null 2>&1; then
        log "Encryption key validation passed"
    else
        error "Encryption key validation failed - invalid base64"
        return 1
    fi
    
    log "Encryption configuration validation passed"
}

# Distribute encryption config to master nodes
distribute_encryption_config() {
    log "Distributing encryption configuration to master nodes..."
    
    local master_nodes=("master-1" "master-2")
    
    for master in "${master_nodes[@]}"; do
        if [[ "$master" == "master-1" ]]; then
            # Copy locally on master-1
            cp "${ENCRYPTION_CONFIG_FILE}" ~/encryption-config.yaml
            chmod 600 ~/encryption-config.yaml
            log "✓ encryption-config.yaml copied locally on master-1"
        else
            # Copy to remote master
            if scp -o StrictHostKeyChecking=no "${ENCRYPTION_CONFIG_FILE}" "vagrant@${master}:~/encryption-config.yaml"; then
                log "✓ encryption-config.yaml copied to ${master}"
                
                # Set proper permissions on remote node
                ssh -o StrictHostKeyChecking=no "vagrant@${master}" 'chmod 600 ~/encryption-config.yaml'
            else
                error "✗ Failed to copy encryption-config.yaml to ${master}"
                return 1
            fi
        fi
    done
    
    log "Encryption configuration distributed to all master nodes"
}

# Display encryption config information
display_encryption_info() {
    log "Displaying encryption configuration information..."
    
    echo ""
    echo "Encryption Configuration Details:"
    echo "================================"
    echo "Config file: ${ENCRYPTION_CONFIG_FILE}"
    echo "Resources encrypted: secrets"
    echo "Encryption method: AES-CBC"
    echo "Key name: ${KEY_NAME}"
    echo "Fallback provider: identity (unencrypted)"
    echo ""
    
    if [[ -f "${ENCRYPTION_CONFIG_FILE}" ]]; then
        echo "Configuration preview:"
        echo "---------------------"
        # Show config but mask the secret key for security
        sed 's/secret: .*/secret: [REDACTED]/' "${ENCRYPTION_CONFIG_FILE}"
    fi
}

# Main execution
main() {
    echo "=================================================="
    echo "Kubernetes Data Encryption Configuration"
    echo "Encryption Method: AES-CBC (256-bit)"
    echo "Resources: Kubernetes Secrets"
    echo "=================================================="
    
    # Check if running on master-1
    local current_hostname=$(hostname)
    if [[ "$current_hostname" != "master-1" ]] && [[ "$current_hostname" != "kubernetes-ha-master-1" ]]; then
        error "This script must be run on master-1"
        exit 1
    fi
    
    # Setup and verify
    setup_directories
    verify_prerequisites
    
    # Generate encryption key
    local encryption_key
    encryption_key=$(generate_encryption_key)
    
    if [[ -z "$encryption_key" ]]; then
        error "Failed to generate encryption key"
        exit 1
    fi
    
    # Create and validate config
    create_encryption_config "$encryption_key"
    validate_encryption_config
    
    # Distribute to master nodes
    distribute_encryption_config
    
    # Display information
    display_encryption_info
    
    log "Data encryption configuration completed successfully!"
    
    echo ""
    echo "=================================================="
    echo "ENCRYPTION SUMMARY"
    echo "=================================================="
    echo "Local config: ${ENCRYPTION_CONFIG_FILE}"
    echo "Distributed to: master-1, master-2"
    echo "File permissions: 600 (secure)"
    echo "Encryption strength: 256-bit AES-CBC"
    echo "=================================================="
    
    # Security reminder
    echo ""
    warning "SECURITY REMINDER:"
    echo "- The encryption key is embedded in the config file"
    echo "- Keep the config file secure with 600 permissions"
    echo "- Back up the encryption key securely"
    echo "- Loss of the key means loss of encrypted data"
}

# Run main function
main