#!/bin/bash
# Phase 4: Data Encryption Configuration
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

# Check if Phase 3 completed
if [[ ! -f "/home/vagrant/phase3_completed.txt" ]]; then
    log_error "Phase 3 not completed. Please run phase3-kubeconfig.sh first."
    exit 1
fi

log "=== Phase 4: Data Encryption Configuration ==="

cd /home/vagrant

# Step 1: Generate encryption key
log ""
log "${YELLOW}Step 1: Generating data encryption key...${NC}"

# Generate a 32-byte random key and base64 encode it
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
log_success "Encryption key generated"

# Step 2: Create encryption config file
log ""
log "${YELLOW}Step 2: Creating encryption configuration file...${NC}"

mkdir -p /home/vagrant/encryption

cat > /home/vagrant/encryption/encryption-config.yaml <<EOF
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

log_success "Encryption config file created"

# Step 3: Distribute encryption config to master nodes
log ""
log "${YELLOW}Step 3: Distributing encryption config to master nodes...${NC}"

# Copy to master-2
log "Copying encryption config to master-2..."
ssh -o StrictHostKeyChecking=no vagrant@master-2 "mkdir -p /home/vagrant/encryption"
scp -o StrictHostKeyChecking=no /home/vagrant/encryption/encryption-config.yaml vagrant@master-2:/home/vagrant/encryption/
log_success "Encryption config copied to master-2"

# Step 4: Verify encryption configuration
log ""
log "${YELLOW}Step 4: Verifying encryption configuration...${NC}"

log "Encryption configuration details:"
echo "==============================================="
echo "Encryption config file location: /home/vagrant/encryption/encryption-config.yaml"
echo ""
echo "File contents:"
cat /home/vagrant/encryption/encryption-config.yaml
echo ""
echo "File permissions:"
ls -la /home/vagrant/encryption/encryption-config.yaml
echo ""
echo "Key validation:"
if [[ ${#ENCRYPTION_KEY} -eq 44 ]]; then
    echo "✓ Encryption key length is correct (44 chars base64)"
else
    echo "✗ Encryption key length is incorrect"
fi
echo "==============================================="

# Create completion marker
echo "Phase 4 completed: $(date)" > /home/vagrant/phase4_completed.txt

log ""
log_success "🎉 Phase 4 (Data Encryption Configuration) completed successfully!"
log ""
log "${CYAN}Encryption configuration created:${NC}"
log_success "  ✓ 32-byte AES encryption key generated"
log_success "  ✓ EncryptionConfig YAML file created"
log_success "  ✓ Configuration distributed to master nodes"
log_success "  ✓ Secrets will be encrypted at rest in etcd"
log ""
log "${YELLOW}Next step: ./phase5-etcd.sh${NC}"
