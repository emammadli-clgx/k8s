#!/bin/bash
# Script: fix-api-server-v2.sh
# Purpose: Fix API server service account configuration
# Run on: master-1

set -e

echo "=== Fixing Kubernetes API Server Configuration ==="

# Get internal IP
INTERNAL_IP=$(ip addr show enp0s8 | grep "inet " | awk '{print $2}' | cut -d / -f 1)

# Create updated kube-apiserver.service with required service account settings
echo "Creating updated kube-apiserver.service..."
cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\
  --enable-admission-plugins=NodeRestriction,ServiceAccount \\
  --enable-bootstrap-token-auth=true \\
  --etcd-cafile=/var/lib/kubernetes/ca.crt \\
  --etcd-certfile=/var/lib/kubernetes/etcd-server.crt \\
  --etcd-keyfile=/var/lib/kubernetes/etcd-server.key \\
  --etcd-servers=https://192.168.5.11:2379,https://192.168.5.12:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.crt \\
  --kubelet-client-certificate=/var/lib/kubernetes/kube-apiserver.crt \\
  --kubelet-client-key=/var/lib/kubernetes/kube-apiserver.key \\
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \\
  --service-account-key-file=/var/lib/kubernetes/service-account.crt \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account.key \\
  --service-cluster-ip-range=10.96.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kube-apiserver.crt \\
  --tls-private-key-file=/var/lib/kubernetes/kube-apiserver.key \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Restart services
echo "Restarting kube-apiserver service..."
sudo systemctl daemon-reload
sudo systemctl restart kube-apiserver

# Wait for API server to start
echo "Waiting for API server to start..."
for i in {1..30}; do
  if sudo systemctl is-active --quiet kube-apiserver; then
    echo "API server is now running!"
    break
  fi
  echo -n "."
  sleep 1
done

# Check API server status
if sudo systemctl is-active --quiet kube-apiserver; then
  echo -e "\nAPI server is active!"
  sudo systemctl status kube-apiserver --no-pager | head -10
else
  echo -e "\nAPI server failed to start. Checking logs..."
  sudo journalctl -u kube-apiserver -n 15 --no-pager
fi

echo "=== API Server fix completed ==="

#!/bin/bash
# Script: fix-master-2.sh
# Purpose: Fix API server on master-2
# Run on: master-1

set -e

echo "=== Fixing Kubernetes API Server on master-2 ==="

# First fix the local API server if it isn't running yet
echo "Checking API server on master-1 first..."
if ! sudo systemctl is-active --quiet kube-apiserver; then
  echo "Fixing local API server first..."
  
  INTERNAL_IP=$(ip addr show enp0s8 | grep "inet " | awk '{print $2}' | cut -d / -f 1)
  
  # Create updated kube-apiserver.service with required service account settings
  cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\
  --enable-admission-plugins=NodeRestriction,ServiceAccount \\
  --enable-bootstrap-token-auth=true \\
  --etcd-cafile=/var/lib/kubernetes/ca.crt \\
  --etcd-certfile=/var/lib/kubernetes/etcd-server.crt \\
  --etcd-keyfile=/var/lib/kubernetes/etcd-server.key \\
  --etcd-servers=https://192.168.5.11:2379,https://192.168.5.12:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.crt \\
  --kubelet-client-certificate=/var/lib/kubernetes/kube-apiserver.crt \\
  --kubelet-client-key=/var/lib/kubernetes/kube-apiserver.key \\
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \\
  --service-account-key-file=/var/lib/kubernetes/service-account.crt \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account.key \\
  --service-cluster-ip-range=10.96.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kube-apiserver.crt \\
  --tls-private-key-file=/var/lib/kubernetes/kube-apiserver.key \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl restart kube-apiserver
  
  echo "Waiting for local API server to start..."
  sleep 10
fi

# Create fixed service file for master-2
echo "Creating fixed kube-apiserver.service file for master-2..."
cat > kube-apiserver.service.master2 <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=192.168.5.12 \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\
  --enable-admission-plugins=NodeRestriction,ServiceAccount \\
  --enable-bootstrap-token-auth=true \\
  --etcd-cafile=/var/lib/kubernetes/ca.crt \\
  --etcd-certfile=/var/lib/kubernetes/etcd-server.crt \\
  --etcd-keyfile=/var/lib/kubernetes/etcd-server.key \\
  --etcd-servers=https://192.168.5.11:2379,https://192.168.5.12:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.crt \\
  --kubelet-client-certificate=/var/lib/kubernetes/kube-apiserver.crt \\
  --kubelet-client-key=/var/lib/kubernetes/kube-apiserver.key \\
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \\
  --service-account-key-file=/var/lib/kubernetes/service-account.crt \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account.key \\
  --service-cluster-ip-range=10.96.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kube-apiserver.crt \\
  --tls-private-key-file=/var/lib/kubernetes/kube-apiserver.key \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Copy and apply the fix to master-2
echo "Copying fix to master-2..."
scp kube-apiserver.service.master2 vagrant@master-2:~/kube-apiserver.service

echo "Applying fix on master-2..."
ssh vagrant@master-2 "sudo mv ~/kube-apiserver.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl restart kube-apiserver"

# Wait for API server to start on master-2
echo "Waiting for API server to start on master-2..."
for i in {1..15}; do
  if ssh vagrant@master-2 "sudo systemctl is-active --quiet kube-apiserver" 2>/dev/null; then
    echo "API server on master-2 is now running!"
    break
  fi
  echo -n "."
  sleep 2
done

# Check status on master-2
echo -e "\nFinal status on master-2:"
ssh vagrant@master-2 "sudo systemctl status kube-apiserver --no-pager | head -10"

echo "=== Master-2 fix completed ==="