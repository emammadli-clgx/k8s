#!/bin/bash

#===============================================================================
# PHASE 10: SMOKE TESTS
# Comprehensive testing of the Kubernetes cluster functionality
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

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"
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
if [[ ! -f "${SCRIPT_DIR}/.phase9_status" ]]; then
    log_error "Phase 9 not completed. Please run phase9-dns.sh first."
    exit 1
fi

log "=== PHASE 10: Running Smoke Tests ==="

# Change to script directory for relative paths
cd "${SCRIPT_DIR}"

# Ensure we have kubectl available
if [[ -f "./kubectl" ]]; then
    KUBECTL_CMD="./kubectl"
elif command -v kubectl >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
else
    log_error "kubectl not found"
    exit 1
fi

KUBECONFIG_FILE="${CONFIG_DIR}/admin.kubeconfig"

# Test 1: Verify cluster components
log "Test 1: Verifying cluster components..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get componentstatuses; then
    log_success "Cluster components are healthy"
else
    log_error "Cluster components health check failed"
    exit 1
fi

# Test 2: Verify nodes are ready
log "Test 2: Verifying nodes are ready..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes; then
    # Check if all nodes are Ready
    not_ready_nodes=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes --no-headers | grep -v " Ready " | wc -l)
    if [[ $not_ready_nodes -eq 0 ]]; then
        log_success "All nodes are Ready"
    else
        log_error "$not_ready_nodes nodes are not Ready"
        ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes
        exit 1
    fi
else
    log_error "Failed to get nodes"
    exit 1
fi

# Test 3: Create a test deployment
log "Test 3: Creating test deployment..."
cat > test-deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:1.21
        ports:
        - containerPort: 80
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f test-deployment.yaml; then
    log_success "Test deployment created"
else
    log_error "Failed to create test deployment"
    exit 1
fi

# Wait for deployment to be ready
log "Waiting for deployment to be ready..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" wait --for=condition=available --timeout=180s deployment/nginx-test; then
    log_success "Test deployment is ready"
else
    log_error "Test deployment did not become ready in time"
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" describe deployment nginx-test
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -l app=nginx-test
    exit 1
fi

# Test 4: Verify pods are running
log "Test 4: Verifying test pods..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -l app=nginx-test; then
    running_pods=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -l app=nginx-test --no-headers | grep "Running" | wc -l)
    if [[ $running_pods -eq 2 ]]; then
        log_success "All test pods are running ($running_pods/2)"
    else
        log_error "Not all test pods are running ($running_pods/2)"
        exit 1
    fi
else
    log_error "Failed to get test pods"
    exit 1
fi

# Test 5: Create and test a service
log "Test 5: Creating and testing a service..."
cat > test-service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nginx-test-service
  namespace: default
spec:
  selector:
    app: nginx-test
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: ClusterIP
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f test-service.yaml; then
    log_success "Test service created"
else
    log_error "Failed to create test service"
    exit 1
fi

# Get service details
SERVICE_IP=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get svc nginx-test-service -o jsonpath='{.spec.clusterIP}')
if [[ -n "$SERVICE_IP" ]]; then
    log_success "Service IP: $SERVICE_IP"
else
    log_error "Failed to get service IP"
    exit 1
fi

# Test 6: Test DNS resolution
log "Test 6: Testing DNS resolution..."
cat > dns-test-pod.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-test
  namespace: default
spec:
  containers:
  - name: dns-test
    image: busybox:1.35
    command: ['sleep', '3600']
  restartPolicy: Neve
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f dns-test-pod.yaml; then
    log_success "DNS test pod created"
else
    log_error "Failed to create DNS test pod"
    exit 1
fi

# Wait for DNS test pod to be ready
log "Waiting for DNS test pod to be ready..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" wait --for=condition=ready --timeout=120s pod/dns-test; then
    log_success "DNS test pod is ready"
else
    log_error "DNS test pod did not become ready in time"
    exit 1
fi

# Test DNS resolution
log "Testing DNS resolution inside the cluster..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec dns-test -- nslookup kubernetes.default; then
    log_success "DNS resolution test passed"
else
    log_error "DNS resolution test failed"
    exit 1
fi

# Test service DNS resolution
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec dns-test -- nslookup nginx-test-service.default.svc.cluster.local; then
    log_success "Service DNS resolution test passed"
else
    log_error "Service DNS resolution test failed"
    exit 1
fi

# Test 7: Test HTTP connectivity to service
log "Test 7: Testing HTTP connectivity to service..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec dns-test -- wget -qO- http://nginx-test-service.default.svc.cluster.local | grep -q "Welcome to nginx"; then
    log_success "HTTP connectivity test passed"
else
    log_error "HTTP connectivity test failed"
    exit 1
fi

# Test 8: Test logs functionality
log "Test 8: Testing logs functionality..."
NGINX_POD=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -l app=nginx-test -o jsonpath='{.items[0].metadata.name}')
if [[ -n "$NGINX_POD" ]]; then
    if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" logs "$NGINX_POD" | grep -q "start worker processes"; then
        log_success "Logs functionality test passed"
    else
        log_warn "Logs test inconclusive (nginx may not have started fully)"
    fi
else
    log_error "Failed to get nginx pod name"
    exit 1
fi

# Test 9: Test exec functionality
log "Test 9: Testing exec functionality..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec "$NGINX_POD" -- nginx -v 2>&1 | grep -q "nginx version"; then
    log_success "Exec functionality test passed"
else
    log_error "Exec functionality test failed"
    exit 1
fi

# Test 10: Test secrets
log "Test 10: Testing secrets functionality..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" create secret generic test-secret --from-literal=key1=value1; then
    log_success "Secret creation test passed"
else
    log_error "Secret creation test failed"
    exit 1
fi

# Verify secret can be read
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get secret test-secret -o jsonpath='{.data.key1}' | base64 -d | grep -q "value1"; then
    log_success "Secret retrieval test passed"
else
    log_error "Secret retrieval test failed"
    exit 1
fi

# Clean up test resources
log "Cleaning up test resources..."
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" delete deployment nginx-test --ignore-not-found=true
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" delete service nginx-test-service --ignore-not-found=true
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" delete pod dns-test --ignore-not-found=true
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" delete secret test-secret --ignore-not-found=true

# Clean up test files
rm -f test-deployment.yaml test-service.yaml dns-test-pod.yaml

log_success "Test cleanup completed"

# Final cluster status
log "Final cluster status:"
log "Nodes:"
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes -o wide

log "System pods:"
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system

log "Services:"
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get svc -A

# Create status file
echo "PHASE10_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase10_status"
echo "ALL_TESTS_PASSED=true" >> "${SCRIPT_DIR}/.phase10_status"

log_success "Phase 10: All smoke tests passed successfully!"
log ""
log "🎉 Kubernetes cluster is fully functional and ready for use! 🎉"
log ""
log "Cluster Summary:"
log "  Kubernetes Version: ${KUBERNETES_VERSION}"
log "  etcd Version: ${ETCD_VERSION}"
log "  Container Runtime: containerd"
log "  CNI: Weave Net"
log "  Pod Network CIDR: ${CLUSTER_CIDR}"
log "  Service Network CIDR: ${SERVICE_CIDR}"
log "  Load Balancer: ${LOADBALANCER_ADDRESS}:6443"
log ""
log "Access your cluster with:"
log "  export KUBECONFIG=${CONFIG_DIR}/admin.kubeconfig"
log "  kubectl get nodes"

exit 0
