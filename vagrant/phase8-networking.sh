#!/bin/bash

#===============================================================================
# PHASE 8: CONFIGURE POD NETWORKING (CNI - Weave Net)
# Deploy and configure Weave Net CNI for pod-to-pod communication
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
if [[ ! -f "${SCRIPT_DIR}/.phase7_status" ]]; then
    log_error "Phase 7 not completed. Please run phase7-workers.sh first."
    exit 1
fi

log "=== PHASE 8: Configure Pod Networking with Weave Net ==="

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

# Verify cluster is accessible
log "Verifying cluster connectivity..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" cluster-info; then
    log_success "Cluster is accessible"
else
    log_error "Cannot access cluster"
    exit 1
fi

# Verify all nodes are ready
log "Verifying all nodes are Ready..."
not_ready_nodes=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes --no-headers | grep -v " Ready " | wc -l)
if [[ $not_ready_nodes -gt 0 ]]; then
    log_error "Some nodes are not Ready. Please check node status:"
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes
    exit 1
else
    log_success "All nodes are Ready"
fi

# Apply RBAC for Weave Net
log "Creating RBAC configuration for Weave Net..."
cat > weave-net-rbac.yaml <<EOF
apiVersion: v1
kind: List
items:
  - apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: weave-net
      labels:
        name: weave-net
      namespace: kube-system
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: weave-net
      labels:
        name: weave-net
    rules:
      - apiGroups:
          - ''
        resources:
          - pods
          - namespaces
          - nodes
        verbs:
          - get
          - list
          - watch
      - apiGroups:
          - networking.k8s.io
        resources:
          - networkpolicies
        verbs:
          - get
          - list
          - watch
      - apiGroups:
          - ''
        resources:
          - nodes/status
        verbs:
          - patch
          - update
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: weave-net
      labels:
        name: weave-net
    roleRef:
      kind: ClusterRole
      name: weave-net
      apiGroup: rbac.authorization.k8s.io
    subjects:
      - kind: ServiceAccount
        name: weave-net
        namespace: kube-system
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: weave-net
      labels:
        name: weave-net
      namespace: kube-system
    rules:
      - apiGroups:
          - ''
        resources:
          - configmaps
        resourceNames:
          - weave-net
        verbs:
          - get
          - update
      - apiGroups:
          - ''
        resources:
          - configmaps
        verbs:
          - create
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: weave-net
      labels:
        name: weave-net
      namespace: kube-system
    roleRef:
      kind: Role
      name: weave-net
      apiGroup: rbac.authorization.k8s.io
    subjects:
      - kind: ServiceAccount
        name: weave-net
        namespace: kube-system
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f weave-net-rbac.yaml; then
    log_success "Weave Net RBAC applied"
else
    log_error "Failed to apply Weave Net RBAC"
    exit 1
fi

# Deploy Weave Net DaemonSet
log "Deploying Weave Net DaemonSet..."
cat > weave-net-daemonset.yaml <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: weave-net
  labels:
    name: weave-net
  namespace: kube-system
spec:
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      name: weave-net
  template:
    metadata:
      labels:
        name: weave-net
    spec:
      containers:
        - name: weave
          command:
            - /home/weave/launch.sh
          env:
            - name: IPALLOC_RANGE
              value: ${CLUSTER_CIDR}
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  apiVersion: v1
                  fieldPath: spec.nodeName
          image: 'weaveworks/weave-kube:2.8.1'
          readinessProbe:
            httpGet:
              host: 127.0.0.1
              path: /status
              port: 6784
          resources:
            requests:
              cpu: 50m
          securityContext:
            privileged: true
          volumeMounts:
            - name: weavedb
              mountPath: /weavedb
            - name: dbus
              mountPath: /host/var/lib/dbus
            - name: machine-id
              mountPath: /host/etc/machine-id
              readOnly: true
        - name: weave-npc
          args:
            - '--config-file=/etc/iptables-config/config'
          env:
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  apiVersion: v1
                  fieldPath: spec.nodeName
          image: 'weaveworks/weave-npc:2.8.1'
          resources:
            requests:
              cpu: 50m
          securityContext:
            privileged: true
          volumeMounts:
            - name: iptables-config
              mountPath: /etc/iptables-config
              readOnly: true
      hostNetwork: true
      hostPID: false
      restartPolicy: Always
      serviceAccountName: weave-net
      tolerations:
        - effect: NoSchedule
          operator: Exists
        - effect: NoExecute
          operator: Exists
      volumes:
        - name: weavedb
          hostPath:
            path: /var/lib/weave
        - name: dbus
          hostPath:
            path: /var/lib/dbus
        - name: machine-id
          hostPath:
            path: /etc/machine-id
        - name: iptables-config
          configMap:
            name: weave-net
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f weave-net-daemonset.yaml; then
    log_success "Weave Net DaemonSet deployed"
else
    log_error "Failed to deploy Weave Net DaemonSet"
    exit 1
fi

# Create Weave Net ConfigMap
log "Creating Weave Net ConfigMap..."
cat > weave-net-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: weave-net
  namespace: kube-system
data:
  config: |
    {
        "Network": "${CLUSTER_CIDR}",
        "Backend": {
            "Type": "vxlan"
        }
    }
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f weave-net-configmap.yaml; then
    log_success "Weave Net ConfigMap created"
else
    log_error "Failed to create Weave Net ConfigMap"
    exit 1
fi

# Wait for Weave Net pods to be ready
log "Waiting for Weave Net pods to be ready..."
retry_count=0
max_retries=60
while [[ $retry_count -lt $max_retries ]]; do
    ready_pods=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l name=weave-net --no-headers 2>/dev/null | grep "Running" | wc -l)
    total_nodes=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes --no-headers | wc -l)
    
    if [[ $ready_pods -eq $total_nodes ]]; then
        log_success "All Weave Net pods are ready ($ready_pods/$total_nodes)"
        break
    else
        log_warn "Weave Net pods ready: $ready_pods/$total_nodes, waiting... ($((retry_count + 1))/$max_retries)"
        sleep 10
        ((retry_count++))
    fi
done

if [[ $retry_count -eq $max_retries ]]; then
    log_error "Weave Net pods did not become ready in time"
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l name=weave-net
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" describe pods -n kube-system -l name=weave-net
    exit 1
fi

# Verify CNI is working by checking node status
log "Verifying CNI installation..."
sleep 30  # Give nodes time to update their status

# Check if nodes show Ready status with networking
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get nodes -o wide

# Test pod networking by creating a test pod
log "Testing pod networking with a test pod..."
cat > network-test-pod.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: network-test
  namespace: default
spec:
  containers:
  - name: network-test
    image: busybox:1.35
    command: ['sleep', '3600']
  restartPolicy: Neve
EOF

if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" apply -f network-test-pod.yaml; then
    log_success "Network test pod created"
else
    log_error "Failed to create network test pod"
    exit 1
fi

# Wait for test pod to be ready
log "Waiting for network test pod to be ready..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" wait --for=condition=ready --timeout=120s pod/network-test; then
    log_success "Network test pod is ready"
    
    # Get pod IP and verify it's in the expected range
    POD_IP=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pod network-test -o jsonpath='{.status.podIP}')
    if [[ -n "$POD_IP" ]]; then
        log_success "Pod assigned IP: $POD_IP"
        
        # Verify IP is in CLUSTER_CIDR range (basic check)
        CLUSTER_NETWORK=$(echo ${CLUSTER_CIDR} | cut -d'/' -f1 | cut -d'.' -f1-2)
        POD_NETWORK=$(echo ${POD_IP} | cut -d'.' -f1-2)
        
        if [[ "$POD_NETWORK" == "$CLUSTER_NETWORK" ]]; then
            log_success "Pod IP is in expected CIDR range"
        else
            log_warn "Pod IP may not be in expected CIDR range (expected: ${CLUSTER_CIDR})"
        fi
    else
        log_error "Failed to get pod IP"
        exit 1
    fi
else
    log_error "Network test pod did not become ready"
    ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" describe pod network-test
    exit 1
fi

# Test network connectivity within the pod
log "Testing network connectivity from within the pod..."
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec network-test -- ping -c 3 8.8.8.8; then
    log_success "External network connectivity test passed"
else
    log_warn "External network connectivity test failed (may be expected in some environments)"
fi

# Test internal connectivity (ping Kubernetes service)
if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" exec network-test -- nslookup kubernetes.default; then
    log_success "Internal DNS resolution test passed"
else
    log_warn "Internal DNS resolution test failed (DNS addon not yet installed)"
fi

# Clean up test pod
log "Cleaning up network test pod..."
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" delete pod network-test --ignore-not-found=true

# Verify Weave Net status
log "Checking Weave Net status..."
${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l name=weave-net

# Check Weave Net logs for any errors
log "Checking Weave Net logs for errors..."
WEAVE_POD=$(${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" get pods -n kube-system -l name=weave-net --no-headers | head -1 | awk '{print $1}')
if [[ -n "$WEAVE_POD" ]]; then
    if ${KUBECTL_CMD} --kubeconfig="${KUBECONFIG_FILE}" logs -n kube-system "$WEAVE_POD" -c weave --tail=10 | grep -i error; then
        log_warn "Found some errors in Weave Net logs, please review"
    else
        log_success "No errors found in recent Weave Net logs"
    fi
fi

# Clean up temporary files
rm -f weave-net-rbac.yaml weave-net-daemonset.yaml weave-net-configmap.yaml network-test-pod.yaml

# Create status file
echo "PHASE8_COMPLETED=$(date '+%Y-%m-%d %H:%M:%S')" > "${SCRIPT_DIR}/.phase8_status"
echo "CNI_PROVIDER=weave-net" >> "${SCRIPT_DIR}/.phase8_status"
echo "CLUSTER_CIDR=${CLUSTER_CIDR}" >> "${SCRIPT_DIR}/.phase8_status"

log_success "Phase 8: Pod networking configuration completed successfully!"
log "Weave Net CNI is now deployed and configured for pod-to-pod communication."
log "Pod CIDR: ${CLUSTER_CIDR}"

exit 0
