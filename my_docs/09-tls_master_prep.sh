#!/bin/bash
# prep-master.sh - Prepare master for TLS bootstrapping
# Run on master-1

set -e

# Use admin kubeconfig
export KUBECONFIG=admin.kubeconfig

echo "=== Preparing master-1 for TLS bootstrapping ==="

# Step 1: Verify API server is accessible
echo "Verifying connection to the API server..."
if ! kubectl cluster-info; then
  echo "Error: Cannot connect to the Kubernetes API server!"
  echo "Make sure KUBECONFIG is set correctly (admin.kubeconfig)"
  exit 1
fi

# Step 2: Create bootstrap token
echo "Creating bootstrap token..."
cat > bootstrap-token-07401b.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-07401b
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  description: "The default bootstrap token for worker node TLS bootstrapping"
  token-id: 07401b
  token-secret: f395accd246ae52d
  expiration: 2026-03-10T03:22:11Z
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: system:bootstrappers:worker
EOF

kubectl create -f bootstrap-token-07401b.yaml || echo "Bootstrap token already exists"

# Step 3: Create RBAC permissions for TLS bootstrapping
echo "Creating RBAC permissions for bootstrapping..."

# Allow bootstrapping nodes to create CSR
kubectl create clusterrolebinding create-csrs-for-bootstrapping \
  --clusterrole=system:node-bootstrapper \
  --group=system:bootstrappers || echo "ClusterRoleBinding create-csrs-for-bootstrapping already exists"

# Auto-approve CSRs for the group "system:bootstrappers"
kubectl create clusterrolebinding auto-approve-csrs-for-group \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:nodeclient \
  --group=system:bootstrappers || echo "ClusterRoleBinding auto-approve-csrs-for-group already exists"

# Approve renewal CSRs for the group "system:nodes"
kubectl create clusterrolebinding auto-approve-renewals-for-nodes \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:selfnodeclient \
  --group=system:nodes || echo "ClusterRoleBinding auto-approve-renewals-for-nodes already exists"

# Step 4: Verify CA certificate exists
echo "Checking for CA certificate..."
if [ ! -f "ca.crt" ]; then
  echo "CA certificate (ca.crt) not found in current directory!"
  echo "Make sure the CA certificate is available for copying to worker-2"
  exit 1
fi

# Step 5: Copy CA certificate to worker-2
echo "Copying CA certificate to worker-2..."
scp ca.crt vagrant@worker-2:~/

echo "=== Master preparation completed successfully ==="
echo "Next, run run.sh on worker-2"     