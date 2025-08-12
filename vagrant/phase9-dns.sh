#!/bin/bash

#===============================================================================
# PHASE 9: DNS ADDON (CoreDNS)
# Deploy and configure CoreDNS for service discovery within the cluste
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
if [[ ! -f "${SCRIPT_DIR}/.phase8_status" ]]; then
    log_error "Phase 8 not completed. Please run phase8-networking.sh first."
    exit 1
fi

log "=== PHASE 9: Deploy DNS Addon (CoreDNS) ==="

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

# Verify cluster is accessible and networking is working
log "Verifying cluster and networking status..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes -o wide; then
    log_success "Cluster is accessible"
else
    log_error "Cannot access cluster"
    exit 1
fi

# Verify Weave Net is running
weave_pods=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l name=weave-net --no-headers | grep "Running" | wc -l)
total_nodes=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes --no-headers | wc -l)
if [[ $weave_pods -eq $total_nodes ]]; then
    log_success "Weave Net is running on all nodes ($weave_pods/$total_nodes)"
else
    log_error "Weave Net is not running on all nodes ($weave_pods/$total_nodes)"
    exit 1
fi

# Create CoreDNS ServiceAccount and RBAC
log "Creating CoreDNS ServiceAccount and RBAC..."
cat > coredns-rbac.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
  labels:
    kubernetes.io/name: "CoreDNS"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
    kubernetes.io/name: "CoreDNS"
  name: system:coredns
rules:
- apiGroups:
  - ""
  resources:
  - endpoints
  - services
  - pods
  - namespaces
  verbs:
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
    kubernetes.io/name: "CoreDNS"
  name: system:coredns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
- kind: ServiceAccount
  name: coredns
  namespace: kube-system
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f coredns-rbac.yaml; then
    log_success "CoreDNS RBAC created"
else
    log_error "Failed to create CoreDNS RBAC"
    exit 1
fi

# Create CoreDNS ConfigMap
log "Creating CoreDNS ConfigMap..."
cat > coredns-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
  labels:
    kubernetes.io/name: "CoreDNS"
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f coredns-configmap.yaml; then
    log_success "CoreDNS ConfigMap created"
else
    log_error "Failed to create CoreDNS ConfigMap"
    exit 1
fi

# Create CoreDNS Deployment
log "Creating CoreDNS Deployment..."
cat > coredns-deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/name: "CoreDNS"
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: coredns
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/maste
          operator: Exists
          effect: NoSchedule
        - key: "CriticalAddonsOnly"
          operator: "Exists"
      nodeSelector:
        kubernetes.io/os: linux
      affinity:
         podAntiAffinity:
           preferredDuringSchedulingIgnoredDuringExecution:
           - weight: 100
             podAffinityTerm:
               labelSelector:
                 matchExpressions:
                   - key: k8s-app
                     operator: In
                     values: ["kube-dns"]
               topologyKey: kubernetes.io/hostname
      containers:
      - name: coredns
        image: coredns/coredns:1.10.1
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        args: [ "-conf", "/etc/coredns/Corefile" ]
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
          readOnly: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9153
          name: metrics
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8181
            scheme: HTTP
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - all
          readOnlyRootFilesystem: true
      dnsPolicy: Default
      volumes:
        - name: config-volume
          configMap:
            name: coredns
            items:
            - key: Corefile
              path: Corefile
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f coredns-deployment.yaml; then
    log_success "CoreDNS Deployment created"
else
    log_error "Failed to create CoreDNS Deployment"
    exit 1
fi

# Create CoreDNS Service
log "Creating CoreDNS Service..."
cat > coredns-service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  annotations:
    prometheus.io/port: "9153"
    prometheus.io/scrape: "true"
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "CoreDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: ${CLUSTER_DNS}
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
  - name: metrics
    port: 9153
    protocol: TCP
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f coredns-service.yaml; then
    log_success "CoreDNS Service created"
else
    log_error "Failed to create CoreDNS Service"
    exit 1
fi

# Wait for CoreDNS deployment to be ready
log "Waiting for CoreDNS deployment to be ready..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" wait --for=condition=available --timeout=300s deployment/coredns -n kube-system; then
    log_success "CoreDNS deployment is ready"
else
    log_error "CoreDNS deployment did not become ready in time"
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" describe deployment coredns -n kube-system
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l k8s-app=kube-dns
    exit 1
fi

# Verify CoreDNS pods are running
log "Verifying CoreDNS pods..."
coredns_pods=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep "Running" | wc -l)
if [[ $coredns_pods -eq 2 ]]; then
    log_success "All CoreDNS pods are running (2/2)"
else
    log_error "Not all CoreDNS pods are running ($coredns_pods/2)"
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l k8s-app=kube-dns
    exit 1
fi

# Test DNS functionality
log "Testing DNS functionality..."
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

# Wait for test pod to be ready
log "Waiting for DNS test pod to be ready..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" wait --for=condition=ready --timeout=120s pod/dns-test; then
    log_success "DNS test pod is ready"
else
    log_error "DNS test pod did not become ready"
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" describe pod dns-test
    exit 1
fi

# Test DNS resolution
log "Testing DNS resolution..."
sleep 10  # Give DNS time to propagate

# Test 1: Resolve kubernetes service
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec dns-test -- nslookup kubernetes.default; then
    log_success "Kubernetes service DNS resolution test passed"
else
    log_error "Kubernetes service DNS resolution test failed"
    exit 1
fi

# Test 2: Resolve kube-dns service
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec dns-test -- nslookup kube-dns.kube-system; then
    log_success "CoreDNS service DNS resolution test passed"
else
    log_error "CoreDNS service DNS resolution test failed"
    exit 1
fi

# Test 3: Resolve external domain (if internet access available)
log "Testing external DNS resolution..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec dns-test -- nslookup google.com; then
    log_success "External DNS resolution test passed"
else
    log_warn "External DNS resolution test failed (may be expected in isolated environments)"
fi

# Create a test service and verify its DNS resolution
log "Creating test service for DNS validation..."
cat > test-service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: dns-test-service
  namespace: default
spec:
  selector:
    app: nonexistent
  ports:
  - port: 80
    targetPort: 80
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f test-service.yaml; then
    # Wait a moment for DNS to propagate
    sleep 5
    
    # Test service DNS resolution
    if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec dns-test -- nslookup dns-test-service.default.svc.cluster.local; then
        log_success "Service DNS resolution test passed"
    else
        log_error "Service DNS resolution test failed"
        exit 1
    fi
    
    # Clean up test service
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" delete service dns-test-service
else
    log_warn "Failed to create test service for DNS validation"
fi

# Clean up test pod and files
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" delete pod dns-test --ignore-not-found=true
rm -f dns-test-pod.yaml test-service.yaml

# Verify CoreDNS is working by checking its logs
log "Checking CoreDNS logs..."
COREDNS_POD=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l k8s-app=kube-dns --no-headers | head -1 | awk '{print $1}')
if [[ -n "$COREDNS_POD" ]]; then
    log "Recent CoreDNS activity:"
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" logs -n kube-system "$COREDNS_POD" --tail=5 || true
fi

# Display final status
log "Final DNS addon status:"
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get all -n kube-system -l k8s-app=kube-dns

# Clean up temporary files
rm -f coredns-rbac.yaml coredns-configmap.yaml coredns-deployment.yaml coredns-service.yaml

# Create status file
echo "PHASE9_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase9_status"
echo "DNS_PROVIDER=coredns" >> "${SCRIPT_DIR}/.phase9_status"
echo "DNS_SERVICE_IP=${CLUSTER_DNS}" >> "${SCRIPT_DIR}/.phase9_status"

log_success "Phase 9: DNS addon (CoreDNS) deployment completed successfully!"
log "CoreDNS is now providing DNS services for the cluster."
log "DNS Service IP: ${CLUSTER_DNS}"
log "Cluster domain: cluster.local"

exit 0
