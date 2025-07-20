#!/bin/bash
# Script: generate-encryption-config.sh
# Purpose: Generate encryption configuration for Kubernetes secrets
# Run from: master-1

set -e

echo "=== Generating Data Encryption Config ==="

# Generate encryption key
echo "Generating encryption key..."
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
echo "Encryption key generated (hidden for security)"

# Create encryption config file
echo "Creating encryption-config.yaml..."
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

echo "encryption-config.yaml created"

# Copy to master-2
echo "Distributing encryption config to master-2..."
scp encryption-config.yaml vagrant@master-2:~/

echo "=== Encryption config generation completed ==="