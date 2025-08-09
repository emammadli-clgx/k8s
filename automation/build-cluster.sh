#!/usr/bin/env bash
set -euo pipefail

# Kubernetes The Hard Way (Modernized) Automated Build Script (Build Core Only - stops before smoke tests)
# Run on master-1 only. Assumes passwordless SSH from master-1 to:
#  - master-2 (hostname: master-2)
#  - worker nodes: worker-1, worker-2
#  - load balancer: lb (hostname: lb)
# Assumes OS: Ubuntu 22.04
# Idempotent where practical; safe to re-run partially.

#============================
# Configuration Variables
#============================
CLUSTER_NAME="kubernetes-the-hard-way"
CONTROL_PLANE_LB_IP="192.168.5.30"
POD_CIDR="10.244.0.0/16"   # Adjust if using another CNI
SERVICE_CIDR="10.96.0.0/24"
K8S_VERSION="v1.30.2"
ETCD_VERSION="v3.5.13"
CONTAINERD_VERSION="1.7.17"
CRICTL_VERSION="v1.30.0"
NERDCTL_VERSION="1.7.6"

MASTERS=(master-1 master-2)
WORKERS=(worker-1 worker-2)
REMOTE_KUBECONFIG_DIR=/root/kubeconfigs
PKI_DIR=~/pki
KUBECONFIG_DIR=~/kubeconfigs
ARTIFACT_CACHE=~/kthw-artifacts

#============================
# Helper Functions
#============================
log(){ echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
run_remote(){ local host=$1; shift; ssh -o StrictHostKeyChecking=no "$host" "$@"; }
scp_to(){ local src=$1 host=$2 dest=$3; scp -o StrictHostKeyChecking=no "$src" "$host":"$dest"; }

require_tools(){
  local tools=(curl openssl tar jq ssh scp systemctl)
  for t in "${tools[@]}"; do command -v "$t" >/dev/null || { err "Required tool $t missing"; exit 1; }; done
}

# Download (with cache)
fetch(){
  local url=$1 file=$2
  mkdir -p "$ARTIFACT_CACHE"
  if [[ ! -f "$ARTIFACT_CACHE/$file" ]]; then
    log "Downloading $file"
    curl -L "$url" -o "$ARTIFACT_CACHE/$file"
  else
    log "Using cached $file"
  fi
}

#============================
# 1. Prepare master-1 host (containerd + tools)
#============================
prepare_local_runtime(){
  log "Preparing containerd runtime on master-1"
  if ! command -v containerd >/dev/null; then
    sudo systemctl stop docker 2>/dev/null || true
    sudo apt-get update -y
    sudo apt-get install -y socat conntrack ipset ebtables ethtool apt-transport-https ca-certificates gnupg lsb-release
    # containerd
    fetch https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz containerd.tgz
    sudo tar -C /usr/local -xzf "$ARTIFACT_CACHE/containerd.tgz"
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo tee /etc/systemd/system/containerd.service >/dev/null <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/containerd
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now containerd
  fi
  # crictl
  if ! command -v crictl >/dev/null; then
    fetch https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz crictl.tgz
    sudo tar -C /usr/local/bin -xzf "$ARTIFACT_CACHE/crictl.tgz"
    sudo tee /etc/crictl.yaml >/dev/null <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF
  fi
  # nerdctl
  if ! command -v nerdctl >/dev/null; then
    fetch https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz nerdctl.tgz
    sudo tar -C /usr/local/bin -xzf "$ARTIFACT_CACHE/nerdctl.tgz"
  fi
  # kube binaries
  if ! command -v kubeadm >/dev/null; then
    fetch https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-apiserver kube-apiserver
    fetch https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-controller-manager kube-controller-manager
    fetch https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-scheduler kube-scheduler
    fetch https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl kubectl
    fetch https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubelet kubelet
    fetch https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-proxy kube-proxy
    sudo install -m 0755 "$ARTIFACT_CACHE"/kube-* /usr/local/bin/
  fi
}

#============================
# 2. Generate PKI
#============================
make_pki(){
  log "Generating PKI"
  mkdir -p "$PKI_DIR"/{ca,etcd,apiserver,admin,controller,scheduler,proxy,sa}
  pushd "$PKI_DIR" >/dev/null
  if [[ ! -f ca/ca.crt ]]; then
    # CA
    openssl genrsa -out ca/ca.key 4096
    openssl req -x509 -new -nodes -key ca/ca.key -subj "/CN=Kubernetes" -days 1000 -out ca/ca.crt
  fi
  # Admin
  if [[ ! -f admin/admin.crt ]]; then
    openssl genrsa -out admin/admin.key 2048
    openssl req -new -key admin/admin.key -subj "/O=system:masters/CN=admin" -out admin/admin.csr
    openssl x509 -req -in admin/admin.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial -out admin/admin.crt -days 365
  fi
  # Controller Manager
  if [[ ! -f controller/kube-controller-manager.crt ]]; then
    openssl genrsa -out controller/kube-controller-manager.key 2048
    openssl req -new -key controller/kube-controller-manager.key -subj "/CN=system:kube-controller-manager" -out controller/kube-controller-manager.csr
    openssl x509 -req -in controller/kube-controller-manager.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial -out controller/kube-controller-manager.crt -days 365
  fi
  # Scheduler
  if [[ ! -f scheduler/kube-scheduler.crt ]]; then
    openssl genrsa -out scheduler/kube-scheduler.key 2048
    openssl req -new -key scheduler/kube-scheduler.key -subj "/CN=system:kube-scheduler" -out scheduler/kube-scheduler.csr
    openssl x509 -req -in scheduler/kube-scheduler.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial -out scheduler/kube-scheduler.crt -days 365
  fi
  # Kube Proxy
  if [[ ! -f proxy/kube-proxy.crt ]]; then
    openssl genrsa -out proxy/kube-proxy.key 2048
    openssl req -new -key proxy/kube-proxy.key -subj "/CN=system:kube-proxy" -out proxy/kube-proxy.csr
    openssl x509 -req -in proxy/kube-proxy.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial -out proxy/kube-proxy.crt -days 365
  fi
  # Service Account
  if [[ ! -f sa/sa.pub ]]; then
    openssl genrsa -out sa/sa.key 2048
    openssl rsa -in sa/sa.key -pubout -out sa/sa.pub
  fi
  # API Server cert SANs
  if [[ ! -f apiserver/apiserver.crt ]]; then
    cat > apiserver/openssl.cnf <<EOF
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[ req_distinguished_name ]
CN = kube-apiserver
[ v3_req ]
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
IP.1 = 10.96.0.1
IP.2 = ${CONTROL_PLANE_LB_IP}
IP.3 = 127.0.0.1
EOF
    openssl genrsa -out apiserver/apiserver.key 2048
    openssl req -new -key apiserver/apiserver.key -out apiserver/apiserver.csr -config apiserver/openssl.cnf
    openssl x509 -req -in apiserver/apiserver.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial -out apiserver/apiserver.crt -days 365 -extensions v3_req -extfile apiserver/openssl.cnf
  fi
  # etcd peers reuse apiserver cert here for simplicity (or generate dedicated etcd certs if desired)
  # Kubelet node certs per worker
  for node in "${WORKERS[@]}"; do
    if [[ ! -f kubelet-${node}/kubelet-${node}.crt ]]; then
      mkdir -p kubelet-${node}
      openssl genrsa -out kubelet-${node}/kubelet-${node}.key 2048
      openssl req -new -key kubelet-${node}/kubelet-${node}.key -subj "/O=system:nodes/CN=system:node:${node}" -out kubelet-${node}/kubelet-${node}.csr
      openssl x509 -req -in kubelet-${node}/kubelet-${node}.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial -out kubelet-${node}/kubelet-${node}.crt -days 365
    fi
  done
  popd >/dev/null
}

#============================
# 3. Generate kubeconfigs
#============================
make_kubeconfigs(){
  log "Generating kubeconfigs"
  mkdir -p "$KUBECONFIG_DIR"
  local CA_CRT=$PKI_DIR/ca/ca.crt
  kubectl config set-cluster "$CLUSTER_NAME" \
    --certificate-authority="$CA_CRT" \
    --embed-certs=true \
    --server="https://${CONTROL_PLANE_LB_IP}:6443" \
    --kubeconfig=$KUBECONFIG_DIR/kube-proxy.kubeconfig
  kubectl config set-credentials system:kube-proxy \
    --client-certificate=$PKI_DIR/proxy/kube-proxy.crt \
    --client-key=$PKI_DIR/proxy/kube-proxy.key \
    --embed-certs=true \
    --kubeconfig=$KUBECONFIG_DIR/kube-proxy.kubeconfig
  kubectl config set-context default \
    --cluster="$CLUSTER_NAME" \
    --user=system:kube-proxy \
    --kubeconfig=$KUBECONFIG_DIR/kube-proxy.kubeconfig
  kubectl config use-context default --kubeconfig=$KUBECONFIG_DIR/kube-proxy.kubeconfig

  for comp in controller-manager scheduler admin; do
    local user certdir kube
    case $comp in
      controller-manager) user=system:kube-controller-manager certdir=controller kube=controller-manager;;
      scheduler) user=system:kube-scheduler certdir=scheduler kube=scheduler;;
      admin) user=admin certdir=admin kube=admin;;
    esac
    kubectl config set-cluster "$CLUSTER_NAME" \
      --certificate-authority="$CA_CRT" \
      --embed-certs=true \
      --server=https://127.0.0.1:6443 \
      --kubeconfig=$KUBECONFIG_DIR/${kube}.kubeconfig
    kubectl config set-credentials $user \
      --client-certificate=$PKI_DIR/${certdir}/${kube}.crt \
      --client-key=$PKI_DIR/${certdir}/${kube}.key \
      --embed-certs=true \
      --kubeconfig=$KUBECONFIG_DIR/${kube}.kubeconfig
    kubectl config set-context default \
      --cluster="$CLUSTER_NAME" \
      --user=$user \
      --kubeconfig=$KUBECONFIG_DIR/${kube}.kubeconfig
    kubectl config use-context default --kubeconfig=$KUBECONFIG_DIR/${kube}.kubeconfig
  done
  # kubelet kubeconfigs (per worker)
  for node in "${WORKERS[@]}"; do
    kubectl config set-cluster "$CLUSTER_NAME" \
      --certificate-authority="$CA_CRT" \
      --embed-certs=true \
      --server="https://${CONTROL_PLANE_LB_IP}:6443" \
      --kubeconfig=$KUBECONFIG_DIR/kubelet-${node}.kubeconfig
    kubectl config set-credentials system:node:${node} \
      --client-certificate=$PKI_DIR/kubelet-${node}/kubelet-${node}.crt \
      --client-key=$PKI_DIR/kubelet-${node}/kubelet-${node}.key \
      --embed-certs=true \
      --kubeconfig=$KUBECONFIG_DIR/kubelet-${node}.kubeconfig
    kubectl config set-context default \
      --cluster="$CLUSTER_NAME" \
      --user=system:node:${node} \
      --kubeconfig=$KUBECONFIG_DIR/kubelet-${node}.kubeconfig
    kubectl config use-context default --kubeconfig=$KUBECONFIG_DIR/kubelet-${node}.kubeconfig
  done
}

#============================
# 4. Distribute kubeconfigs & PKI
#============================
copy_artifacts(){
  log "Copying kubeconfigs & certs"
  # Single secondary master (extend list if adding more)
  for host in master-2; do
    run_remote $host "mkdir -p ~/kubeconfigs ~/pki/ca ~/pki/apiserver ~/pki/sa"
    scp_to $KUBECONFIG_DIR/admin.kubeconfig $host ~/kubeconfigs/
    scp_to $KUBECONFIG_DIR/controller-manager.kubeconfig $host ~/kubeconfigs/
    scp_to $KUBECONFIG_DIR/scheduler.kubeconfig $host ~/kubeconfigs/
    scp_to $PKI_DIR/ca/ca.crt $host ~/pki/ca/
    scp_to $PKI_DIR/ca/ca.key $host ~/pki/ca/
    scp_to $PKI_DIR/apiserver/apiserver.{crt,key} $host ~/pki/apiserver/
    scp_to $PKI_DIR/sa/sa.{key,pub} $host ~/pki/sa/
    run_remote $host "sudo mkdir -p $REMOTE_KUBECONFIG_DIR && sudo cp ~/kubeconfigs/*.kubeconfig $REMOTE_KUBECONFIG_DIR/"
  done
  # Workers (single consolidated loop)
  for node in "${WORKERS[@]}"; do
    run_remote $node "mkdir -p ~/kubeconfigs ~/pki/ca ~/pki/proxy ~/pki/kubelet"
    scp_to $KUBECONFIG_DIR/kube-proxy.kubeconfig $node ~/kubeconfigs/
    scp_to $KUBECONFIG_DIR/kubelet-${node}.kubeconfig $node ~/kubeconfigs/
    scp_to $PKI_DIR/ca/ca.crt $node ~/pki/ca/
    scp_to $PKI_DIR/proxy/kube-proxy.{crt,key} $node ~/pki/proxy/
    scp_to $PKI_DIR/kubelet-${node}/kubelet-${node}.{crt,key} $node ~/pki/kubelet/
    run_remote $node "sudo mkdir -p $REMOTE_KUBECONFIG_DIR && sudo cp ~/kubeconfigs/*.kubeconfig $REMOTE_KUBECONFIG_DIR/"
  done
  # Local root copies
  sudo mkdir -p $REMOTE_KUBECONFIG_DIR && sudo cp $KUBECONFIG_DIR/*.kubeconfig $REMOTE_KUBECONFIG_DIR/
}

#============================
# 5. Encryption config
#============================
make_encryption_config(){
  log "Creating encryption config"
  local key; key=$(head -c 32 /dev/urandom | base64)
  cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: apiserver.config.k8s.io/v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${key}
      - identity: {}
EOF
  for m in "${MASTERS[@]}"; do
    scp_to encryption-config.yaml $m ~/encryption-config.yaml
  done
}

#============================
# 6. etcd setup
#============================
setup_etcd(){
  log "Setting up etcd on masters"
  for m in "${MASTERS[@]}"; do
    run_remote $m "sudo useradd --system --home /var/lib/etcd --shell /sbin/nologin etcd || true"
    run_remote $m "sudo mkdir -p /etc/etcd /var/lib/etcd"
    # Reuse apiserver cert for etcd TLS (simplified) - production should separate
    scp_to $PKI_DIR/apiserver/apiserver.crt $m /tmp/etcd-server.crt
    scp_to $PKI_DIR/apiserver/apiserver.key $m /tmp/etcd-server.key
    scp_to $PKI_DIR/ca/ca.crt $m /tmp/ca.crt
    run_remote $m "sudo cp /tmp/etcd-server.crt /tmp/etcd-server.key /tmp/ca.crt /etc/etcd/"
    fetch https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz etcd.tgz
    scp_to $ARTIFACT_CACHE/etcd.tgz $m /tmp/etcd.tgz
    run_remote $m "sudo tar -C /usr/local/bin -xzf /tmp/etcd.tgz --strip-components=1 etcd-${ETCD_VERSION}-linux-amd64/etcd{,ctl}; rm /tmp/etcd.tgz"
    # systemd unit
    run_remote $m "THIS_IP=$(ip -4 addr show enp0s8 | awk '/inet /{print $2}' | cut -d/ -f1); ETCD_NAME=$(hostname -s); cat <<EOF | sudo tee /etc/systemd/system/etcd.service >/dev/null
[Unit]
Description=etcd key-value store
After=network-online.target
Wants=network-online.target

[Service]
User=etcd
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --data-dir /var/lib/etcd \\
  --initial-advertise-peer-urls https://${THIS_IP}:2380 \\
  --listen-peer-urls https://${THIS_IP}:2380 \\
  --listen-client-urls https://${THIS_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${THIS_IP}:2379 \\
  --initial-cluster master-1=https://192.168.5.11:2380,master-2=https://192.168.5.12:2380 \\
  --initial-cluster-token etcd-kthw \\
  --initial-cluster-state new \\
  --cert-file=/etc/etcd/etcd-server.crt \\
  --key-file=/etc/etcd/etcd-server.key \\
  --client-cert-auth --trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-cert-file=/etc/etcd/etcd-server.crt \\
  --peer-key-file=/etc/etcd/etcd-server.key \\
  --peer-client-cert-auth --peer-trusted-ca-file=/etc/etcd/ca.crt \\
  --logger=zap \\
  --quota-backend-bytes=8589934592 \\
  --auto-compaction-retention=1 \\
  --max-txn-ops=1024 \\
  --max-request-bytes=33554432
LimitNOFILE=100000
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/etcd /etc/etcd

[Install]
WantedBy=multi-user.target
EOF"
    run_remote $m "sudo systemctl daemon-reload && sudo systemctl enable etcd && sudo systemctl start etcd"
  done
}

#============================
# 7. Control plane components
#============================
setup_control_plane(){
  log "Configuring control plane components"
  for m in "${MASTERS[@]}"; do
    # Copy binaries (already present on master-1) & certs
    for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl; do
      if [[ $m != master-1 ]]; then scp_to /usr/local/bin/$bin $m /tmp/$bin; run_remote $m "sudo install -m 0755 /tmp/$bin /usr/local/bin/$bin"; fi
    done
    for f in admin controller-manager scheduler; do
      if [[ $m != master-1 ]]; then scp_to $KUBECONFIG_DIR/${f}.kubeconfig $m ~/kubeconfigs/${f}.kubeconfig; fi
    done
    # Required dirs
    run_remote $m "sudo mkdir -p /var/lib/kubernetes"
    scp_to $PKI_DIR/ca/ca.crt $m /tmp/ca.crt
    scp_to $PKI_DIR/apiserver/apiserver.{crt,key} $m /tmp/
    scp_to $PKI_DIR/sa/sa.{key,pub} $m /tmp/
    run_remote $m "sudo mv /tmp/ca.crt /tmp/apiserver.crt /tmp/apiserver.key /tmp/sa.key /tmp/sa.pub /var/lib/kubernetes/"
    scp_to encryption-config.yaml $m /tmp/encryption-config.yaml
    run_remote $m "sudo mv /tmp/encryption-config.yaml /var/lib/kubernetes/"
    # kube-apiserver unit
    run_remote $m "cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service >/dev/null
[Unit]
Description=Kubernetes API Server
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=$(run_remote $m "ip -4 addr show enp0s8 | awk '/inet /{print $2}' | cut -d/ -f1") \\
  --allow-privileged=true \\
  --apiserver-count=2 \\
  --authorization-mode=Node,RBAC \\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\
  --disable-admission-plugins=StorageObjectInUseProtection \\
  --enable-admission-plugins=NodeRestriction,PodSecurity \\
  --etcd-cafile=/var/lib/kubernetes/ca.crt \\
  --etcd-certfile=/var/lib/kubernetes/apiserver.crt \\
  --etcd-keyfile=/var/lib/kubernetes/apiserver.key \\
  --etcd-servers=https://192.168.5.11:2379,https://192.168.5.12:2379 \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-client-certificate=/var/lib/kubernetes/apiserver.crt \\
  --kubelet-client-key=/var/lib/kubernetes/apiserver.key \\
  --kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP \\
  --service-account-key-file=/var/lib/kubernetes/sa.pub \\
  --service-account-signing-key-file=/var/lib/kubernetes/sa.key \\
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/apiserver.crt \\
  --tls-private-key-file=/var/lib/kubernetes/apiserver.key \\
  --proxy-client-cert-file=/var/lib/kubernetes/apiserver.crt \\
  --proxy-client-key-file=/var/lib/kubernetes/apiserver.key \\
  --requestheader-client-ca-file=/var/lib/kubernetes/ca.crt \\
  --requestheader-allowed-names=kubernetes \\
  --requestheader-extra-headers-prefix=X-Remote-Extra- \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --runtime-config=api/all=true \\
  --secure-port=6443 \\
  --event-ttl=1h
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    # controller manager
    run_remote $m "cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service >/dev/null
[Unit]
Description=Kubernetes Controller Manager
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --allocate-node-cidrs=true \\
  --authentication-kubeconfig=$REMOTE_KUBECONFIG_DIR/controller-manager.kubeconfig \\
  --authorization-kubeconfig=$REMOTE_KUBECONFIG_DIR/controller-manager.kubeconfig \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\
  --cluster-cidr=${POD_CIDR} \\
  --cluster-name=${CLUSTER_NAME} \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.crt \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca.key \\
  --controllers=*,bootstrapsigner,tokencleaner \\
  --kubeconfig=$REMOTE_KUBECONFIG_DIR/controller-manager.kubeconfig \\
  --leader-elect=true \\
  --requestheader-client-ca-file=/var/lib/kubernetes/ca.crt \\
  --root-ca-file=/var/lib/kubernetes/ca.crt \\
  --service-account-private-key-file=/var/lib/kubernetes/sa.key \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --use-service-account-credentials=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    # scheduler
    run_remote $m "cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service >/dev/null
[Unit]
Description=Kubernetes Scheduler
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --authentication-kubeconfig=$REMOTE_KUBECONFIG_DIR/scheduler.kubeconfig \\
  --authorization-kubeconfig=$REMOTE_KUBECONFIG_DIR/scheduler.kubeconfig \\
  --bind-address=127.0.0.1 \\
  --kubeconfig=$REMOTE_KUBECONFIG_DIR/scheduler.kubeconfig \\
  --leader-elect=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    run_remote $m "sudo systemctl daemon-reload && sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler && sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler"
  done
}

#============================
# 8. HAProxy (load balancer)
#============================
setup_load_balancer(){
  log "Configuring HAProxy on lb"
  run_remote lb "sudo apt-get update -y && sudo apt-get install -y haproxy"
  run_remote lb "sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<'EOF'
frontend kubernetes-frontend
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-backend
backend kubernetes-backend
    mode tcp
    balance roundrobin
    server master-1 192.168.5.11:6443 check
    server master-2 192.168.5.12:6443 check
EOF"
  run_remote lb "sudo systemctl enable haproxy && sudo systemctl restart haproxy"
}

#============================
# 9. Worker nodes (kubelet + kube-proxy)
#============================
setup_workers(){
  log "Setting up worker nodes"
  for w in "${WORKERS[@]}"; do
    # containerd + tools
    run_remote $w "if ! command -v containerd >/dev/null; then sudo apt-get update -y && sudo apt-get install -y socat conntrack ipset; fi"
    # copy binaries
    for bin in kubelet kube-proxy kubectl; do
      scp_to /usr/local/bin/$bin $w /tmp/$bin
      run_remote $w "sudo install -m 0755 /tmp/$bin /usr/local/bin/$bin"
    done
    # kubelet config
    run_remote $w "sudo mkdir -p /var/lib/kubelet /var/lib/kube-proxy /etc/kubernetes/manifests"
    # Kubelet config YAML
    run_remote $w "cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml >/dev/null
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
clusterDNS:
  - 10.96.0.10
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook
EOF"
    # systemd units
    run_remote $w "cat <<EOF | sudo tee /etc/systemd/system/kubelet.service >/dev/null
[Unit]
Description=Kubernetes Kubelet
After=network.target

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime=remote \\
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \\
  --kubeconfig=/var/lib/kubelet/kubelet.kubeconfig \\
  --network-plugin=cni \\
  --register-node=true \\
  --tls-cert-file=/var/lib/kubelet/pki/kubelet.crt \\
  --tls-private-key-file=/var/lib/kubelet/pki/kubelet.key \\
  --v=2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    run_remote $w "cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service >/dev/null
[Unit]
Description=Kubernetes Kube-Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/config.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    run_remote $w "cat <<EOF | sudo tee /var/lib/kube-proxy/config.conf >/dev/null
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
clientConnection:
  kubeconfig: $REMOTE_KUBECONFIG_DIR/kube-proxy.kubeconfig
mode: iptables
clusterCIDR: ${POD_CIDR}
EOF"
  # Install kubelet certs + kubeconfig into expected paths then enable services
  run_remote $w "sudo mkdir -p /var/lib/kubelet/pki && sudo cp ~/pki/kubelet/kubelet-${w}.crt /var/lib/kubelet/pki/kubelet.crt && sudo cp ~/pki/kubelet/kubelet-${w}.key /var/lib/kubelet/pki/kubelet.key && sudo cp ~/kubeconfigs/kubelet-${w}.kubeconfig /var/lib/kubelet/kubelet.kubeconfig"
  run_remote $w "sudo systemctl daemon-reload && sudo systemctl enable kubelet kube-proxy && sudo systemctl restart kubelet kube-proxy || sudo systemctl start kubelet kube-proxy"
  done
}

#============================
# 10. CoreDNS (after network)
#============================
install_cni_and_coredns(){
  log "Installing Cilium CNI and CoreDNS"
  if ! command -v cilium >/dev/null; then
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
    sudo tar -C /usr/local/bin -xzf cilium-linux-amd64.tar.gz
    rm cilium-linux-amd64.tar.gz
  fi
  KUBECONFIG=$KUBECONFIG_DIR/admin.kubeconfig cilium install --set cluster.name=kthw --set ipam.mode=kubernetes
  KUBECONFIG=$KUBECONFIG_DIR/admin.kubeconfig kubectl apply -f https://raw.githubusercontent.com/coredns/deployment/master/kubernetes/coredns.yaml.sed || true
}

#============================
#============================
# Main (stops before smoke test)
#============================
main(){
  require_tools
  log "Verifying SSH connectivity to nodes..."
  for h in "${MASTERS[@]}" "${WORKERS[@]}" lb; do
    if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$h" "echo ok" >/dev/null 2>&1; then
      err "SSH to $h failed. Configure passwordless SSH before running."; exit 1; fi
  done
  prepare_local_runtime
  make_pki
  make_kubeconfigs
  copy_artifacts
  make_encryption_config
  setup_load_balancer
  setup_etcd
  setup_control_plane
  setup_workers
  install_cni_and_coredns
  log "Core cluster build sequence completed (pre-smoke-test). Run validation manually."
}

main "$@"
