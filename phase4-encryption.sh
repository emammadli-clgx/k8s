#!/bin/bash

#===============================================================================
# PHASE 4: ENCRYPTION CONFIG
# Generates encryption configuration for etcd data at rest
#===============================================================================

# Exit on any erro
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
if [[ ! -f "${SCRIPT_DIR}/.phase3_status" ]]; then
    log_error "Phase 3 not completed. Please run phase3-kubeconfig.sh first."
    exit 1
fi

log "=== PHASE 4: Generating Encryption Config ==="

# Change to configs directory
cd "${CONFIG_DIR}" || {
    log_error "Failed to change to configs directory"
    exit 1
}

log "Working in: $(pwd)"

# Check if encryption config already exists
if [[ -f "encryption-config.yaml" ]]; then
    log "✓ encryption-config.yaml already exists"
    
    # Verify it's valid
    if grep -q "aescbc" encryption-config.yaml && grep -q "resources:" encryption-config.yaml; then
        log "✓ Existing encryption config appears valid"
        
        # Create status file
        echo "PHASE4_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase4_status"
        echo "ENCRYPTION_CONFIG=${CONFIG_DIR}/encryption-config.yaml" >> "${SCRIPT_DIR}/.phase4_status"
        
        log_success "Phase 4: Encryption config already exists and is valid"
        log ""
        log "Next step: Run phase5-etcd.sh"
        exit 0
    else
        log_error "Existing encryption config is invalid, regenerating..."
        rm -f encryption-config.yaml
    fi
fi

# Generate encryption key
log "Generating encryption key..."
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64) || {
    log_error "Failed to generate encryption key"
    exit 1
}

if [[ -z "$ENCRYPTION_KEY" ]]; then
    log_error "Generated encryption key is empty"
    exit 1
fi

log "✓ Encryption key generated (32 bytes, base64 encoded)"

# Create encryption config file
log "Creating encryption-config.yaml..."
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

# Verify the config file was created correctly
if [[ ! -f "encryption-config.yaml" ]]; then
    log_error "Failed to create encryption-config.yaml"
    exit 1
fi

# Verify the config file contains required content
if ! grep -q "aescbc" encryption-config.yaml; then
    log_error "encryption-config.yaml missing aescbc provider"
    exit 1
fi

if ! grep -q "secrets" encryption-config.yaml; then
    log_error "encryption-config.yaml missing secrets resource"
    exit 1
fi

if ! grep -q "$ENCRYPTION_KEY" encryption-config.yaml; then
    log_error "encryption-config.yaml missing encryption key"
    exit 1
fi

log "✓ encryption-config.yaml created successfully"

# Display the config file (without the actual key for security)
log "Encryption config structure:"
sed "s/${ENCRYPTION_KEY}/***ENCRYPTION_KEY***/g" encryption-config.yaml | while read -r line; do
    log "  $line"
done

# Check file permissions
chmod 600 encryption-config.yaml || {
    log_error "Failed to set encryption config permissions"
    exit 1
}

log "✓ Set restrictive permissions (600) on encryption-config.yaml"

# Verify file size and content
file_size=$(stat -c%s encryption-config.yaml)
if [[ $file_size -lt 100 ]]; then
    log_error "encryption-config.yaml file is too small ($file_size bytes)"
    exit 1
fi

log "✓ Encryption config file size: $file_size bytes"

# Test YAML validity if yq is available
if command -v yq >/dev/null 2>&1; then
    if yq eval . encryption-config.yaml >/dev/null 2>&1; then
        log "✓ YAML syntax validated with yq"
    else
        log_error "YAML syntax validation failed"
        exit 1
    fi
elif command -v python3 >/dev/null 2>&1; then
    # Test with Python YAML
    if python3 -c "import yaml; yaml.safe_load(open('encryption-config.yaml'))" 2>/dev/null; then
        log "✓ YAML syntax validated with Python"
    else
        log_error "YAML syntax validation failed"
        exit 1
    fi
else
    log "⚠ No YAML validator available (yq or python3), skipping syntax validation"
fi

# Create status file
echo "PHASE4_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase4_status"
echo "ENCRYPTION_CONFIG=${CONFIG_DIR}/encryption-config.yaml" >> "${SCRIPT_DIR}/.phase4_status"
echo "ENCRYPTION_KEY_LENGTH=${#ENCRYPTION_KEY}" >> "${SCRIPT_DIR}/.phase4_status"

log_success "Phase 4: Encryption config generation completed successfully"
log ""
log "Security note: The encryption key is now stored in encryption-config.yaml"
log "Ensure this file is protected and backed up securely!"
log ""
log "Next step: Run phase5-etcd.sh"

exit 0
