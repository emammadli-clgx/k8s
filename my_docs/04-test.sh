#!/bin/bash

# test-encryption-config.sh
# Purpose: Test and validate data encryption configuration
# Run on: master-1

set -uo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Configuration
ENCRYPTION_DIR="./encryption"
ENCRYPTION_CONFIG_FILE="${ENCRYPTION_DIR}/encryption-config.yaml"
MASTER_NODES=("master-1" "master-2")

# Logging functions
log() {
    echo -e "${GREEN}[TEST]${NC} $1"
}

error() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Test encryption config file existence
test_config_existence() {
    log "Testing encryption config file existence..."
    
    if [[ -f "${ENCRYPTION_CONFIG_FILE}" ]]; then
        success "Local encryption config file exists"
    else
        error "Local encryption config file missing: ${ENCRYPTION_CONFIG_FILE}"
    fi
}

# Test file permissions
test_file_permissions() {
    log "Testing file permissions..."
    
    if [[ -f "${ENCRYPTION_CONFIG_FILE}" ]]; then
        local perm=$(stat -c "%a" "${ENCRYPTION_CONFIG_FILE}")
        if [[ "$perm" == "600" ]]; then
            success "Local encryption config has correct permissions (600)"
        else
            error "Local encryption config has incorrect permissions ($perm, expected 600)"
        fi
    fi
}

# Test YAML syntax
test_yaml_syntax() {
    log "Testing YAML syntax..."
    
    if [[ -f "${ENCRYPTION_CONFIG_FILE}" ]]; then
        # Simple YAML syntax check - just verify it's readable and has basic structure
        if cat "${ENCRYPTION_CONFIG_FILE}" > /dev/null 2>&1; then
            # Check for common YAML syntax issues
            local yaml_errors=0
            
            # Check for tabs (YAML should use spaces)
            if grep -q $'\t' "${ENCRYPTION_CONFIG_FILE}"; then
                error "YAML contains tabs (should use spaces for indentation)"
                yaml_errors=$((yaml_errors + 1))
            fi
            
            # Try basic structure validation
            if grep -q '^kind:' "${ENCRYPTION_CONFIG_FILE}" && \
               grep -q '^apiVersion:' "${ENCRYPTION_CONFIG_FILE}" && \
               grep -q '^resources:' "${ENCRYPTION_CONFIG_FILE}"; then
                if [[ $yaml_errors -eq 0 ]]; then
                    success "Encryption config has valid YAML syntax"
                fi
            else
                error "YAML missing required top-level fields"
            fi
        else
            error "Encryption config file is not readable"
        fi
    fi
}

# Test config structure
test_config_structure() {
    log "Testing encryption configuration structure..."
    
    if [[ -f "${ENCRYPTION_CONFIG_FILE}" ]]; then
        # Test required fields
        if grep -q "kind: EncryptionConfig" "${ENCRYPTION_CONFIG_FILE}"; then
            success "Config has correct kind: EncryptionConfig"
        else
            error "Config missing 'kind: EncryptionConfig'"
        fi
        
        if grep -q "apiVersion: v1" "${ENCRYPTION_CONFIG_FILE}"; then
            success "Config has correct apiVersion: v1"
        else
            error "Config missing 'apiVersion: v1'"
        fi
        
        if grep -q "resources:" "${ENCRYPTION_CONFIG_FILE}"; then
            success "Config has resources section"
        else
            error "Config missing resources section"
        fi
        
        if grep -q "secrets" "${ENCRYPTION_CONFIG_FILE}"; then
            success "Config includes secrets resource"
        else
            error "Config missing secrets resource"
        fi
        
        if grep -q "providers:" "${ENCRYPTION_CONFIG_FILE}"; then
            success "Config has providers section"
        else
            error "Config missing providers section"
        fi
        
        if grep -q "aescbc:" "${ENCRYPTION_CONFIG_FILE}"; then
            success "Config includes AES-CBC provider"
        else
            error "Config missing AES-CBC provider"
        fi
        
        if grep -q "identity:" "${ENCRYPTION_CONFIG_FILE}"; then
            success "Config includes identity provider (fallback)"
        else
            error "Config missing identity provider"
        fi
    fi
}

# Test encryption key - PROPERLY FIXED VERSION
test_encryption_key() {
    log "Testing encryption key..."
    
    if [[ -f "${ENCRYPTION_CONFIG_FILE}" ]]; then
        # Extract the secret key value - COMPLETELY REWRITTEN EXTRACTION
        local secret_key=$(awk '/secret:/ {gsub(/^[[:space:]]*secret:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print}' "${ENCRYPTION_CONFIG_FILE}")
        
        if [[ -n "$secret_key" ]]; then
            success "Encryption key is present"
            
            # Test key length (base64 encoded 32 bytes should be exactly 44 chars)
            local key_length=${#secret_key}
            if [[ $key_length -eq 44 ]]; then
                success "Encryption key has correct length ($key_length chars)"
            elif [[ $key_length -ge 40 ]] && [[ $key_length -le 48 ]]; then
                success "Encryption key has acceptable length ($key_length chars)"
            else
                error "Encryption key has unexpected length ($key_length chars, expected ~44)"
            fi
            
            # Test if it's valid base64
            if echo "$secret_key" | base64 -d > /dev/null 2>&1; then
                success "Encryption key is valid base64"
                
                # Test decoded length (should be 32 bytes)
                local decoded_length=$(echo "$secret_key" | base64 -d | wc -c)
                if [[ $decoded_length -eq 32 ]]; then
                    success "Encryption key decodes to correct length (32 bytes)"
                else
                    error "Encryption key decodes to incorrect length ($decoded_length bytes, expected 32)"
                fi
            else
                error "Encryption key is not valid base64"
                # Debug info
                echo "  Debug: First 20 chars of key: '${secret_key:0:20}'"
                echo "  Debug: Last 20 chars of key: '${secret_key: -20}'"
            fi
        else
            error "Encryption key not found in config"
        fi
        
        # Test key name
        if grep -q "name: key1" "${ENCRYPTION_CONFIG_FILE}"; then
            success "Encryption key has correct name (key1)"
        else
            error "Encryption key missing or incorrect name"
        fi
    fi
}

# Test distribution to master nodes
test_distribution() {
    log "Testing distribution to master nodes..."
    
    for master in "${MASTER_NODES[@]}"; do
        if [[ "$master" == "master-1" ]]; then
            # Test local copy
            if [[ -f ~/encryption-config.yaml ]]; then
                success "encryption-config.yaml exists in home directory on master-1"
                
                # Test permissions
                local perm=$(stat -c "%a" ~/encryption-config.yaml)
                if [[ "$perm" == "600" ]]; then
                    success "Home directory encryption-config.yaml has correct permissions on master-1 (600)"
                else
                    error "Home directory encryption-config.yaml has incorrect permissions on master-1 ($perm, expected 600)"
                fi
            else
                error "encryption-config.yaml missing in home directory on master-1"
            fi
        else
            # Test remote copy
            if ssh -o StrictHostKeyChecking=no "vagrant@${master}" "test -f ~/encryption-config.yaml" 2>/dev/null; then
                success "encryption-config.yaml exists on ${master}"
                
                # Test permissions on remote node
                local perm=$(ssh -o StrictHostKeyChecking=no "vagrant@${master}" "stat -c '%a' ~/encryption-config.yaml" 2>/dev/null || echo "000")
                if [[ "$perm" == "600" ]]; then
                    success "encryption-config.yaml has correct permissions on ${master} (600)"
                else
                    error "encryption-config.yaml has incorrect permissions on ${master} ($perm, expected 600)"
                fi
                
                # Test file content consistency
                local local_hash=$(sha256sum "${ENCRYPTION_CONFIG_FILE}" | cut -d' ' -f1)
                local remote_hash=$(ssh -o StrictHostKeyChecking=no "vagrant@${master}" "sha256sum ~/encryption-config.yaml" 2>/dev/null | cut -d' ' -f1 || echo "different")
                
                if [[ "$local_hash" == "$remote_hash" ]]; then
                    success "encryption-config.yaml content matches on ${master}"
                else
                    error "encryption-config.yaml content differs on ${master}"
                fi
            else
                error "encryption-config.yaml missing on ${master}"
            fi
        fi
    done
}

# Test provider order
test_provider_order() {
    log "Testing encryption provider order..."
    
    if [[ -f "${ENCRYPTION_CONFIG_FILE}" ]]; then
        # AES-CBC should come before identity for proper encryption
        local aescbc_line=$(grep -n "aescbc:" "${ENCRYPTION_CONFIG_FILE}" | cut -d':' -f1)
        local identity_line=$(grep -n "identity:" "${ENCRYPTION_CONFIG_FILE}" | cut -d':' -f1)
        
        if [[ -n "$aescbc_line" ]] && [[ -n "$identity_line" ]]; then
            if [[ $aescbc_line -lt $identity_line ]]; then
                success "Encryption providers in correct order (aescbc before identity)"
            else
                error "Encryption providers in wrong order (identity should be after aescbc)"
            fi
        else
            error "Could not determine provider order"
        fi
    fi
}

# Main test execution
main() {
    echo "=================================================="
    echo "Encryption Configuration Test Suite"
    echo "=================================================="
    
    # Check if running on master-1
    local current_hostname=$(hostname)
    if [[ "$current_hostname" != "master-1" ]] && [[ "$current_hostname" != "kubernetes-ha-master-1" ]]; then
        error "This script must be run on master-1"
        exit 1
    fi
    
    # Check if encryption directory exists
    if [[ ! -d "$ENCRYPTION_DIR" ]]; then
        error "Encryption directory not found. Run generate-encryption-config.sh first."
        exit 1
    fi
    
    # Run tests
    test_config_existence
    echo ""
    test_file_permissions
    echo ""
    test_yaml_syntax
    echo ""
    test_config_structure
    echo ""
    test_encryption_key
    echo ""
    test_provider_order
    echo ""
    test_distribution
    
    # Summary
    echo ""
    echo "=================================================="
    echo "TEST SUMMARY"
    echo "=================================================="
    echo -e "${GREEN}Passed:${NC} ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC} ${TESTS_FAILED}"
    echo ""
    
    if [ ${TESTS_FAILED} -eq 0 ]; then
        echo -e "${GREEN}All encryption configuration tests passed!${NC}"
        echo "Your data encryption is ready for Kubernetes deployment."
        exit 0
    else
        echo -e "${RED}Some encryption configuration tests failed.${NC}"
        echo "Please review the errors above before proceeding."
        exit 1
    fi
}

# Run main function
main