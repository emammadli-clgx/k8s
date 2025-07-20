#!/bin/bash
# Script: test-encryption-config.sh
# Purpose: Test that encryption configuration is properly generated and distributed
# Run from: master-1

set -e

echo "=== Testing Encryption Configuration ==="

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

FAILED=0

# Check encryption config on master-1
echo "Checking encryption-config.yaml on master-1..."
if [ -f ~/encryption-config.yaml ]; then
    echo -e "  File exists: ${GREEN}YES${NC}"
    
    # Check file size (should be > 200 bytes)
    SIZE=$(stat -c%s ~/encryption-config.yaml)
    if [ $SIZE -gt 200 ]; then
        echo -e "  File size: ${GREEN}OK${NC} ($SIZE bytes)"
    else
        echo -e "  File size: ${RED}TOO SMALL${NC} ($SIZE bytes)"
        ((FAILED++))
    fi
    
    # Verify structure
    if grep -q "kind: EncryptionConfig" ~/encryption-config.yaml && \
       grep -q "apiVersion: v1" ~/encryption-config.yaml && \
       grep -q "- aescbc:" ~/encryption-config.yaml && \
       grep -q "name: key1" ~/encryption-config.yaml && \
       grep -q "secret:" ~/encryption-config.yaml; then
        echo -e "  File structure: ${GREEN}VALID${NC}"
    else
        echo -e "  File structure: ${RED}INVALID${NC}"
        ((FAILED++))
    fi
    
    # Check that encryption key is present and base64 encoded
    KEY_LINE=$(grep "secret:" ~/encryption-config.yaml | awk '{print $2}')
    if [ ! -z "$KEY_LINE" ] && [ ${#KEY_LINE} -eq 44 ]; then
        echo -e "  Encryption key: ${GREEN}PRESENT${NC} (44 chars base64)"
    else
        echo -e "  Encryption key: ${RED}INVALID${NC}"
        ((FAILED++))
    fi
else
    echo -e "  File exists: ${RED}NO${NC}"
    ((FAILED++))
fi

# Check encryption config on master-2
echo -e "\nChecking encryption-config.yaml on master-2..."
if ssh vagrant@master-2 "test -f ~/encryption-config.yaml" 2>/dev/null; then
    echo -e "  File exists: ${GREEN}YES${NC}"
    
    # Check file size
    SIZE=$(ssh vagrant@master-2 "stat -c%s ~/encryption-config.yaml" 2>/dev/null)
    if [ $SIZE -gt 200 ]; then
        echo -e "  File size: ${GREEN}OK${NC} ($SIZE bytes)"
    else
        echo -e "  File size: ${RED}TOO SMALL${NC} ($SIZE bytes)"
        ((FAILED++))
    fi
    
    # Verify files are identical
    LOCAL_HASH=$(sha256sum ~/encryption-config.yaml | awk '{print $1}')
    REMOTE_HASH=$(ssh vagrant@master-2 "sha256sum ~/encryption-config.yaml" 2>/dev/null | awk '{print $1}')
    
    if [ "$LOCAL_HASH" == "$REMOTE_HASH" ]; then
        echo -e "  File identical to master-1: ${GREEN}YES${NC}"
    else
        echo -e "  File identical to master-1: ${RED}NO${NC}"
        ((FAILED++))
    fi
else
    echo -e "  File exists: ${RED}NO${NC}"
    ((FAILED++))
fi

# Display sample content (without showing the actual key)
echo -e "\nSample content (key hidden):"
grep -E "kind:|apiVersion:|resources:|providers:" ~/encryption-config.yaml | head -5

# Summary
echo -e "\n=== Test Summary ==="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    echo "Encryption configuration has been generated and distributed successfully."
    echo -e "\n${GREEN}Important:${NC} Keep the encryption-config.yaml file secure!"
    echo "It contains the encryption key for Kubernetes secrets."
else
    echo -e "${RED}$FAILED test(s) failed!${NC}"
    exit 1
fi