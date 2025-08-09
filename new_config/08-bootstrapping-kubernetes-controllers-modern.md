# Bootstrapping the Kubernetes Control Plane (Modernized 2025)

## Why Update?
- Target a modern Kubernetes release (example v1.30.x) instead of 1.13
- Use systemd hardening
- Add feature gate & security recommendations (disable insecure flags)
- Remove deprecated flags (swagger-ui, runtime-config=api/all) keeping minimal surface

Set variables (run on each master):
```bash
K8S_VERSION=v1.30.4
ARCH=amd64
CONTROL_PLANE_IP=$(ip -4 addr show enp0s8 | awk '/inet /{print $2}' | cut -d/ -f1)
ETCD_ENDPOINTS=https://192.168.5.11:2379,https://192.168.5.12:2379
SERVICE_CIDR=10.96.0.0/24
CLUSTER_NAME=kubernetes-the-hard-way
```

## Binaries
```bash
curl -L --remote-name-all https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/{kube-apiserver,kube-controller-manager,kube-scheduler,kubectl}
chmod +x kube-*
sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
```

## Directories & Assets
```bash
sudo mkdir -p /var/lib/kubernetes /etc/kubernetes/config
sudo cp ~/ca.crt ~/kube-apiserver.crt ~/kube-apiserver.key \
  ~/service-account.crt ~/service-account.key \
  ~/etcd-server.crt ~/etcd-server.key \
  ~/encryption-config.yaml /var/lib/kubernetes/

sudo cp ~/kube-controller-manager.kubeconfig /var/lib/kubernetes/
sudo cp ~/kube-scheduler.kubeconfig /var/lib/kubernetes/
```

## kube-apiserver Unit
```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${CONTROL_PLANE_IP} \\
  --secure-port=6443 \\
  --allow-privileged=true \\
  --authorization-mode=Node,RBAC \\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\
  --enable-admission-plugins=NodeRestriction,ServiceAccount,PodSecurity,Priority \\
  --service-account-key-file=/var/lib/kubernetes/service-account.crt \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account.key \\
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \\
  --etcd-cafile=/var/lib/kubernetes/ca.crt \\
  --etcd-certfile=/var/lib/kubernetes/etcd-server.crt \\
  --etcd-keyfile=/var/lib/kubernetes/etcd-server.key \\
  --etcd-servers=${ETCD_ENDPOINTS} \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.crt \\
  --kubelet-client-certificate=/var/lib/kubernetes/kube-apiserver.crt \\
  --kubelet-client-key=/var/lib/kubernetes/kube-apiserver.key \\
  --runtime-config=api/all=true \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --enable-bootstrap-token-auth=true \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --audit-log-path=/var/log/kubernetes/audit.log \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --v=2
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/kubernetes /var/log/kubernetes

[Install]
WantedBy=multi-user.target
EOF
```

## kube-controller-manager Unit
```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --cluster-name=${CLUSTER_NAME} \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.crt \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca.key \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account.key \\
  --root-ca-file=/var/lib/kubernetes/ca.crt \\
  --leader-elect=true \\
  --use-service-account-credentials=true \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --controllers=*,bootstrapsigner,tokencleaner \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

## kube-scheduler config & Unit
```bash
cat <<EOF | sudo tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: /var/lib/kubernetes/kube-scheduler.kubeconfig
leaderElection:
  leaderElect: true
profiles:
- schedulerName: default-scheduler
EOF

cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

## Start
```bash
sudo mkdir -p /var/log/kubernetes
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
```

## Verification
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get --raw='/readyz?verbose'
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get componentstatuses  # (Some components deprecated; ignore warnings)
```

## Load Balancer (HAProxy)
On `loadbalancer` node:
```bash
sudo apt-get update && sudo apt-get install -y haproxy
sudo tee /etc/haproxy/haproxy.cfg <<'EOF'
frontend kubernetes
    bind 192.168.5.30:6443
    mode tcp
    option tcplog
    default_backend k8s_cp
backend k8s_cp
    mode tcp
    balance roundrobin
    option tcp-check
    server master-1 192.168.5.11:6443 check fall 3 rise 2
    server master-2 192.168.5.12:6443 check fall 3 rise 2
EOF
sudo systemctl restart haproxy
```

Verify externally:
```bash
curl -k https://192.168.5.30:6443/version
```

## Next
Worker bootstrap: `09-bootstrapping-kubernetes-workers-modern.md`.
