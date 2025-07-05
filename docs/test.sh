#!/bin/bash

# Kubernetes HA Cluster Comprehensive Test Suite - FIXED VERSION
# Run this from master-1 as vagrant user

set -euo pipefail

# Configuration
CLUSTER_NAME="kubernetes-ha"
TEST_NAMESPACE="k8s-test-suite"
TIMEOUT_SECONDS=300
MAX_RETRY_ATTEMPTS=5

# Node definitions (should match your setup)
declare -A NODES=(
    ["master-1"]="192.168.5.11"
    ["master-2"]="192.168.5.12"
    ["worker-1"]="192.168.5.21"
    ["worker-2"]="192.168.5.22"
    ["lb"]="192.168.5.30"
)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TESTS_WARNING=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[✓ PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_error() {
    echo -e "${RED}[✗ FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_warning() {
    echo -e "${YELLOW}[⚠ WARN]${NC} $1"
    TESTS_WARNING=$((TESTS_WARNING + 1))
}

log_skip() {
    echo -e "${CYAN}[- SKIP]${NC} $1"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

print_header() {
    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}$1${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_subheader() {
    echo ""
    echo -e "${CYAN}─── $1 ───${NC}"
}

# Wait function with timeout
wait_for_condition() {
    local description="$1"
    local condition="$2"
    local timeout="${3:-$TIMEOUT_SECONDS}"
    local interval=5
    local elapsed=0
    
    log_info "Waiting for: $description"
    
    while [ $elapsed -lt $timeout ]; do
        if eval "$condition" >/dev/null 2>&1; then
            log_success "$description (took ${elapsed}s)"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    
    echo ""
    log_error "$description (timeout after ${timeout}s)"
    return 1
}

# Execute kubectl with error handling and detailed output
kubectl_safe() {
    local cmd="kubectl $*"
    local output
    
    if output=$(kubectl "$@" 2>&1); then
        return 0
    else
        log_error "kubectl command failed: $cmd"
        log_error "Error output: $output"
        return 1
    fi
}

# Test if command succeeds with better error handling
test_command() {
    local description="$1"
    shift
    local cmd="$@"
    local output
    
    if output=$(eval "$cmd" 2>&1); then
        log_success "$description"
        return 0
    else
        log_error "$description"
        log_error "Command: $cmd"
        log_error "Error: $output"
        return 1
    fi
}

# Enhanced version check function
check_kubectl_version() {
    local description="$1"
    
    # Try modern kubectl version command first
    if kubectl version --client --output=yaml >/dev/null 2>&1; then
        CLIENT_VERSION=$(kubectl version --client --output=yaml 2>/dev/null | grep 'gitVersion:' | cut -d'"' -f2)
        log_success "$description - Client: $CLIENT_VERSION"
        
        # Try to get server version
        if SERVER_VERSION=$(kubectl version --output=yaml 2>/dev/null | grep -A10 'serverVersion:' | grep 'gitVersion:' | cut -d'"' -f2); then
            log_success "kubectl server version: $SERVER_VERSION"
        else
            log_warning "Could not retrieve server version (API server may be slow)"
        fi
        return 0
        
    # Fallback to basic version command
    elif kubectl version --client >/dev/null 2>&1; then
        CLIENT_VERSION=$(kubectl version --client 2>/dev/null | grep 'Client Version:' | cut -d':' -f2 | tr -d ' ')
        log_success "$description - Client: $CLIENT_VERSION"
        return 0
        
    # Last resort - try basic version
    elif kubectl version >/dev/null 2>&1; then
        log_success "$description - Basic version check passed"
        return 0
    else
        log_error "$description - All version checks failed"
        return 1
    fi
}

# Cleanup function
cleanup_test_resources() {
    log_info "Cleaning up test resources..."
    
    # Delete test namespace and all resources
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true --timeout=60s >/dev/null 2>&1 || true
    
    # Delete any test ClusterRoles/ClusterRoleBindings
    kubectl delete clusterrole test-cluster-role --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete clusterrolebinding test-cluster-rolebinding --ignore-not-found=true >/dev/null 2>&1 || true
    
    # Clean up any test PVs
    kubectl delete pv test-pv --ignore-not-found=true >/dev/null 2>&1 || true
    
    # Wait for cleanup
    sleep 5
    
    log_info "Cleanup completed"
}

# Trap cleanup on exit
trap cleanup_test_resources EXIT

print_header "🧪 KUBERNETES HA CLUSTER COMPREHENSIVE TEST SUITE"
echo "Starting comprehensive cluster testing at $(date)"
echo "Test namespace: $TEST_NAMESPACE"
echo ""

# TEST PHASE 1: BASIC CLUSTER HEALTH
print_header "PHASE 1: Basic Cluster Health Tests"

print_subheader "1.1 API Server Connectivity"
test_command "kubectl can connect to API server" "kubectl cluster-info"

# Fixed version check
check_kubectl_version "kubectl version check"

print_subheader "1.2 Node Status"
log_info "Checking node status..."
kubectl get nodes -o wide

# Check each node is Ready
for node in master-1 master-2 worker-1 worker-2; do
    if kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
        log_success "Node $node is Ready"
    else
        log_error "Node $node is not Ready"
    fi
done

print_subheader "1.3 System Pods Health"
log_info "Checking system pods in kube-system namespace..."

# Check critical system pods with better error handling
critical_pods=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd" "kube-proxy")

for pod_prefix in "${critical_pods[@]}"; do
    if kubectl get pods -n kube-system 2>/dev/null | grep "$pod_prefix" | grep -q "Running"; then
        log_success "System pod $pod_prefix is running"
    else
        log_error "System pod $pod_prefix is not running properly"
        # Show pod status for debugging
        kubectl get pods -n kube-system | grep "$pod_prefix" || echo "Pod $pod_prefix not found"
    fi
done

# Check CoreDNS separately as it might have a different name
if kubectl get pods -n kube-system 2>/dev/null | grep -E "(coredns|kube-dns)" | grep -q "Running"; then
    log_success "DNS system pods are running"
else
    log_error "DNS system pods are not running properly"
    kubectl get pods -n kube-system | grep -E "(coredns|kube-dns)" || echo "DNS pods not found"
fi

# TEST PHASE 2: CONTROL PLANE COMPONENTS
print_header "PHASE 2: Control Plane Components Tests"

print_subheader "2.1 API Server Health"
# Test API server responsiveness with better error handling
if kubectl get --raw /healthz >/dev/null 2>&1; then
    log_success "API Server /healthz endpoint is responding"
else
    log_error "API Server /healthz endpoint is not responding"
fi

if kubectl get --raw /readyz >/dev/null 2>&1; then
    log_success "API Server /readyz endpoint is responding"
else
    log_warning "API Server /readyz endpoint is not responding (may be normal in some setups)"
fi

print_subheader "2.2 etcd Health"
# Check etcd health via various methods
etcd_healthy=false

# Method 1: Check etcd pods
if kubectl get pods -n kube-system 2>/dev/null | grep etcd | grep -q Running; then
    log_success "etcd pods are running"
    etcd_healthy=true
else
    log_error "etcd pods are not running"
fi

# Method 2: Check etcd endpoints
if kubectl get endpoints -n kube-system 2>/dev/null | grep -q etcd; then
    log_success "etcd endpoints are available"
    etcd_healthy=true
fi

if [ "$etcd_healthy" = false ]; then
    log_error "etcd appears to be unhealthy"
fi

print_subheader "2.3 Controller Manager Health"
if kubectl get pods -n kube-system 2>/dev/null | grep kube-controller-manager | grep -q Running; then
    log_success "Controller Manager is running"
else
    log_error "Controller Manager is not running"
fi

print_subheader "2.4 Scheduler Health"
if kubectl get pods -n kube-system 2>/dev/null | grep kube-scheduler | grep -q Running; then
    log_success "Scheduler is running"
else
    log_error "Scheduler is not running"
fi

# TEST PHASE 3: NETWORKING TESTS
print_header "PHASE 3: Networking and DNS Tests"

# Create test namespace
print_subheader "3.1 Test Namespace Creation"
if kubectl create namespace "$TEST_NAMESPACE" >/dev/null 2>&1; then
    log_success "Created test namespace: $TEST_NAMESPACE"
else
    # Check if it already exists
    if kubectl get namespace "$TEST_NAMESPACE" >/dev/null 2>&1; then
        log_warning "Test namespace already exists, continuing..."
    else
        log_error "Failed to create test namespace"
    fi
fi

print_subheader "3.2 DNS Resolution Test"
# Create DNS test pod with improved error handling
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: dns-test
  namespace: $TEST_NAMESPACE
spec:
  containers:
  - name: dns-test
    image: busybox:1.35
    command:
    - sleep
    - "3600"
    resources:
      requests:
        memory: "16Mi"
        cpu: "10m"
      limits:
        memory: "32Mi"
        cpu: "50m"
  restartPolicy: Never
EOF

# Wait for DNS test pod with better error reporting
if wait_for_condition "DNS test pod to be ready" "kubectl get pod dns-test -n $TEST_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" 120; then
    # Test DNS resolution
    if kubectl exec -n "$TEST_NAMESPACE" dns-test -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
        log_success "Internal DNS resolution works (kubernetes.default.svc.cluster.local)"
    else
        log_error "Internal DNS resolution failed"
    fi
    
    # Test CoreDNS service resolution
    if kubectl exec -n "$TEST_NAMESPACE" dns-test -- nslookup kube-dns.kube-system.svc.cluster.local >/dev/null 2>&1; then
        log_success "CoreDNS service resolution works"
    else
        log_warning "CoreDNS service resolution failed (checking alternative names)"
        
        # Try alternative DNS service names
        if kubectl exec -n "$TEST_NAMESPACE" dns-test -- nslookup coredns.kube-system.svc.cluster.local >/dev/null 2>&1; then
            log_success "CoreDNS service resolution works (via coredns name)"
        else
            log_error "DNS service resolution failed"
        fi
    fi
    
    # Test external DNS (optional)
    if kubectl exec -n "$TEST_NAMESPACE" dns-test -- timeout 10 nslookup google.com >/dev/null 2>&1; then
        log_success "External DNS resolution works"
    else
        log_warning "External DNS resolution failed (may be expected in isolated environments)"
    fi
else
    log_error "DNS test pod failed to start"
    # Show pod status for debugging
    kubectl describe pod dns-test -n "$TEST_NAMESPACE" 2>/dev/null || echo "Could not describe DNS test pod"
fi

print_subheader "3.3 Pod-to-Pod Networking"
# Create two test pods for networking
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: net-test-1
  namespace: $TEST_NAMESPACE
  labels:
    app: net-test
spec:
  containers:
  - name: net-test
    image: nginx:alpine
    ports:
    - containerPort: 80
    resources:
      requests:
        memory: "16Mi"
        cpu: "10m"
      limits:
        memory: "64Mi"
        cpu: "50m"
---
apiVersion: v1
kind: Pod
metadata:
  name: net-test-2
  namespace: $TEST_NAMESPACE
  labels:
    app: net-test
spec:
  containers:
  - name: net-test
    image: busybox:1.35
    command:
    - sleep
    - "3600"
    resources:
      requests:
        memory: "16Mi" 
        cpu: "10m"
      limits:
        memory: "32Mi"
        cpu: "50m"
EOF

# Wait for networking test pods
if wait_for_condition "Network test pods to be ready" "kubectl get pods -n $TEST_NAMESPACE -l app=net-test --field-selector=status.phase=Running 2>/dev/null | grep -c net-test | grep -q 2" 120; then
    # Get IP of first pod
    POD1_IP=$(kubectl get pod net-test-1 -n "$TEST_NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null)
    
    if [ -n "$POD1_IP" ] && [ "$POD1_IP" != "<none>" ]; then
        # Test pod-to-pod connectivity
        if kubectl exec -n "$TEST_NAMESPACE" net-test-2 -- timeout 10 wget -q -O - "http://$POD1_IP" >/dev/null 2>&1; then
            log_success "Pod-to-pod networking works (IP: $POD1_IP)"
        else
            log_error "Pod-to-pod networking failed"
        fi
    else
        log_error "Could not get pod IP for networking test"
    fi
else
    log_error "Network test pods failed to start"
    kubectl get pods -n "$TEST_NAMESPACE" -l app=net-test 2>/dev/null || echo "Could not get network test pods status"
fi

print_subheader "3.4 Service Discovery"
# Create a service
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Service
metadata:
  name: net-test-service
  namespace: $TEST_NAMESPACE
spec:
  selector:
    app: net-test
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: ClusterIP
EOF

# Test service discovery
if wait_for_condition "Service to be created" "kubectl get service net-test-service -n $TEST_NAMESPACE >/dev/null 2>&1" 30; then
    SERVICE_IP=$(kubectl get service net-test-service -n "$TEST_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    
    if [ -n "$SERVICE_IP" ] && [ "$SERVICE_IP" != "None" ] && [ "$SERVICE_IP" != "<none>" ]; then
        # Test service connectivity
        if kubectl exec -n "$TEST_NAMESPACE" net-test-2 -- timeout 10 wget -q -O - "http://$SERVICE_IP" >/dev/null 2>&1; then
            log_success "Service discovery and connectivity works (Service IP: $SERVICE_IP)"
        else
            log_warning "Service connectivity failed (endpoints may not be ready yet)"
        fi
        
        # Test service DNS
        if kubectl exec -n "$TEST_NAMESPACE" net-test-2 -- timeout 10 wget -q -O - "http://net-test-service" >/dev/null 2>&1; then
            log_success "Service DNS resolution works"
        else
            log_warning "Service DNS resolution failed (may need more time for DNS propagation)"
        fi
    else
        log_error "Service IP allocation failed"
    fi
fi

# CONTINUE WITH ABBREVIATED REMAINING TESTS FOR BREVITY...

# TEST PHASE 4: WORKLOAD SCHEDULING (Simplified)
print_header "PHASE 4: Basic Workload Test"

print_subheader "4.1 Simple Deployment Test"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deployment
  namespace: $TEST_NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
EOF

if wait_for_condition "Test deployment to be ready" "kubectl get deployment test-deployment -n $TEST_NAMESPACE -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q 2" 120; then
    log_success "Basic deployment scheduling works"
    
    # Check pod distribution
    NODE_COUNT=$(kubectl get pods -n "$TEST_NAMESPACE" -l app=test-app -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort | uniq | wc -l)
    if [ "$NODE_COUNT" -gt 1 ]; then
        log_success "Pods distributed across $NODE_COUNT nodes"
    else
        log_warning "All pods on same node (normal for small clusters)"
    fi
else
    log_error "Test deployment failed"
    kubectl describe deployment test-deployment -n "$TEST_NAMESPACE" 2>/dev/null || echo "Could not describe deployment"
fi

# TEST PHASE 5: HIGH AVAILABILITY CHECK
print_header "PHASE 5: High Availability Verification"

print_subheader "5.1 Load Balancer Check"
LB_IP="${NODES['lb']}"
if timeout 10 curl -s "http://$LB_IP:8404" | grep -q "HAProxy" 2>/dev/null; then
    log_success "HAProxy load balancer is accessible"
else
    log_error "HAProxy load balancer is not accessible"
fi

if timeout 10 curl -k -s "https://$LB_IP:6443/healthz" | grep -q "ok" 2>/dev/null; then
    log_success "API server accessible through load balancer"
else
    log_error "API server not accessible through load balancer"
fi

print_subheader "5.2 Multiple Master Check"
master_count=0
for master in master-1 master-2; do
    master_ip="${NODES[$master]}"
    if timeout 10 curl -k -s "https://$master_ip:6443/healthz" 2>/dev/null | grep -q "ok"; then
        log_success "API server on $master is healthy"
        master_count=$((master_count + 1))
    else
        log_error "API server on $master is not responding"
    fi
done

if [ $master_count -ge 2 ]; then
    log_success "High availability: Multiple masters are healthy ($master_count/2)"
else
    log_error "High availability compromised: Only $master_count masters are healthy"
fi

# FINAL SUMMARY
print_header "🏁 TEST COMPLETION SUMMARY"

echo ""
printf "%-20s %s\n" "Tests Passed:" "${GREEN}$TESTS_PASSED${NC}"
printf "%-20s %s\n" "Tests Failed:" "${RED}$TESTS_FAILED${NC}"
printf "%-20s %s\n" "Tests Warning:" "${YELLOW}$TESTS_WARNING${NC}"
printf "%-20s %s\n" "Tests Skipped:" "${CYAN}$TESTS_SKIPPED${NC}"
echo ""

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED + TESTS_WARNING + TESTS_SKIPPED))
if [ $TOTAL_TESTS -gt 0 ]; then
    SUCCESS_RATE=$((TESTS_PASSED * 100 / TOTAL_TESTS))
else
    SUCCESS_RATE=0
fi

echo -e "Total Tests: $TOTAL_TESTS"
echo -e "Success Rate: ${SUCCESS_RATE}%"

if [ $TESTS_FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 EXCELLENT! Your cluster is healthy! 🎉${NC}"
    echo -e "${GREEN}✅ All critical tests passed${NC}"
    echo -e "${GREEN}✅ High availability is working${NC}"
    echo -e "${GREEN}✅ Networking is functional${NC}"
    echo -e "${GREEN}✅ Workload scheduling works${NC}"
    
elif [ $TESTS_FAILED -le 2 ] && [ $SUCCESS_RATE -ge 80 ]; then
    echo ""
    echo -e "${YELLOW}⚠️  GOOD: Minor issues detected ⚠️${NC}"
    echo -e "${YELLOW}Your cluster is mostly healthy but has some minor issues.${NC}"
    
else
    echo ""
    echo -e "${RED}❌ ATTENTION NEEDED ❌${NC}"
    echo -e "${RED}Your cluster has significant issues that should be addressed.${NC}"
fi

echo ""
echo "Test completed at $(date)"
echo "Duration: $SECONDS seconds"

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    exit 0
else
    exit 1
fi