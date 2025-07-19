#!/bin/bash

# test-kubectl.sh
# Purpose: Test kubectl installation on all master nodes
# Run on: master-1

# Don't use set -e as it conflicts with arithmetic operations
set -uo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Expected kubectl version
EXPECTED_VERSION="v1.29.0"

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

# Test function for local node
test_kubectl_locally() {
    local node="master-1"
    local test_name="kubectl on ${node}"
    
    log "Testing ${test_name}..."
    
    # Test 1: Check if kubectl exists
    if command -v kubectl &> /dev/null; then
        success "${test_name}: kubectl binary exists"
    else
        error "${test_name}: kubectl binary not found"
        return 1
    fi
    
    # Test 2: Check kubectl location
    local kubectl_path=$(which kubectl 2>/dev/null || echo "not found")
    if [ "$kubectl_path" == "/usr/local/bin/kubectl" ]; then
        success "${test_name}: kubectl in correct location (/usr/local/bin/)"
    else
        warning "${test_name}: kubectl found at $kubectl_path (expected /usr/local/bin/kubectl)"
    fi
    
    # Test 3: Check if kubectl is executable
    if [ -x "/usr/local/bin/kubectl" ]; then
        success "${test_name}: kubectl is executable"
    else
        error "${test_name}: kubectl is not executable"
    fi
    
    # Test 4: Check kubectl version - FIXED
    local version_output=$(kubectl version --client 2>/dev/null || echo "error")
    if [[ $version_output == *"${EXPECTED_VERSION}"* ]]; then
        success "${test_name}: correct version (${EXPECTED_VERSION})"
    else
        error "${test_name}: incorrect version (got: $version_output, expected: ${EXPECTED_VERSION})"
    fi
    
    # Test 5: Test kubectl help command
    if kubectl help &> /dev/null; then
        success "${test_name}: kubectl help command works"
    else
        error "${test_name}: kubectl help command failed"
    fi
}

# Test function for remote node
test_kubectl_remotely() {
    local node=$1
    local test_name="kubectl on ${node}"
    
    log "Testing ${test_name}..."
    
    # Create a temporary script to run on remote node
    local remote_script=$(cat <<'EOF'
#!/bin/bash
# Remote test script

# Test 1: Check if kubectl exists
if command -v kubectl &> /dev/null; then
    echo "PASS: kubectl binary exists"
else
    echo "FAIL: kubectl binary not found"
fi

# Test 2: Check kubectl location
kubectl_path=$(which kubectl 2>/dev/null || echo "not found")
if [ "$kubectl_path" == "/usr/local/bin/kubectl" ]; then
    echo "PASS: kubectl in correct location"
else
    echo "FAIL: kubectl location incorrect: $kubectl_path"
fi

# Test 3: Check if kubectl is executable
if [ -x "/usr/local/bin/kubectl" ]; then
    echo "PASS: kubectl is executable"
else
    echo "FAIL: kubectl is not executable"
fi

# Test 4: Check kubectl version - FIXED
version_output=$(kubectl version --client 2>/dev/null || echo "error")
if [[ $version_output == *"v1.29.0"* ]]; then
    echo "PASS: correct version"
else
    echo "FAIL: incorrect version: $version_output"
fi

# Test 5: Test kubectl help command
if kubectl help &> /dev/null; then
    echo "PASS: kubectl help works"
else
    echo "FAIL: kubectl help failed"
fi
EOF
)
    
    # Execute remote script
    local remote_tests=$(echo "$remote_script" | ssh -o StrictHostKeyChecking=no vagrant@${node} bash 2>/dev/null || echo "SSH_FAILED")
    
    if [[ "$remote_tests" == "SSH_FAILED" ]]; then
        error "${test_name}: SSH connection failed"
        return 1
    fi
    
    # Parse remote test results
    while IFS= read -r line; do
        if [[ $line == PASS:* ]]; then
            success "${test_name}: ${line#PASS: }"
        elif [[ $line == FAIL:* ]]; then
            error "${test_name}: ${line#FAIL: }"
        fi
    done <<< "$remote_tests"
}

# Additional system tests
test_system_requirements() {
    log "Testing system requirements..."
    
    # Test wget availability (needed for installation)
    if command -v wget &> /dev/null; then
        success "wget is available"
    else
        error "wget is not available (required for kubectl download)"
    fi
    
    # Test sha256sum availability
    if command -v sha256sum &> /dev/null; then
        success "sha256sum is available"
    else
        error "sha256sum is not available (required for verification)"
    fi
    
    # Test SSH connectivity to all nodes
    log "Testing SSH connectivity to other nodes..."
    for node in master-2 worker-1 worker-2 lb; do
        if timeout 5 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 vagrant@${node} echo "SSH OK" &> /dev/null; then
            success "SSH connectivity to ${node}"
        else
            error "Cannot SSH to ${node}"
        fi
    done
}

# Main test execution
main() {
    echo "=================================================="
    echo "kubectl Installation Test Suite"
    echo "Expected Version: ${EXPECTED_VERSION}"
    echo "=================================================="
    
    # Check if running on master-1 (flexible hostname check)
    local current_hostname=$(hostname)
    if [[ "$current_hostname" != "master-1" ]] && [[ "$current_hostname" != "kubernetes-ha-master-1" ]]; then
        error "This script must be run on master-1"
        error "Current hostname: $current_hostname"
        exit 1
    fi
    
    # Test system requirements
    test_system_requirements
    
    echo ""
    echo "Testing kubectl installation on nodes..."
    echo "------------------------------------------"
    
    # Test kubectl on master-1 (local)
    test_kubectl_locally
    echo ""
    
    # Test kubectl on master-2 (remote)
    test_kubectl_remotely "master-2"
    echo ""
    
    # Summary
    echo "=================================================="
    echo "TEST SUMMARY"
    echo "=================================================="
    echo -e "${GREEN}Passed:${NC} ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC} ${TESTS_FAILED}"
    echo ""
    
    if [ ${TESTS_FAILED} -eq 0 ]; then
        echo -e "${GREEN}All tests passed! kubectl is properly installed.${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed. Please check the errors above.${NC}"
        exit 1
    fi
}

# Run main function
main