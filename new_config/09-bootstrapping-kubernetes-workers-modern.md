# Bootstrapping Kubernetes Workers (Modernized 2025)

## Strategy
- worker-1: manual cert path (shows legacy style)
- worker-2: will rely on TLS bootstrap (next guide)
- Runtime: Prefer containerd (see migration guide) – adjust service units accordingly

Variables (on master-1 for creating worker-1 cert):
```bash
WORKER1_HOST=worker-1
WORKER1_IP=192.168.5.21
CA_DIR=~/pki/ca
cd ~/pki/workers
cat > openssl-${WORKER1_HOST}.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = dn
[ dn ]
[ v3_req ]
subjectAltName = DNS:${WORKER1_HOST},IP:${WORKER1_IP}
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
basicConstraints = CA:FALSE
EOF
openssl genrsa -out ${WORKER1_HOST}.key 2048
openssl req -new -key ${WORKER1_HOST}.key -subj "/CN=system:node:${WORKER1_HOST}/O=system:nodes" -out ${WORKER1_HOST}.csr -config openssl-${WORKER1_HOST}.cnf
openssl x509 -req -in ${WORKER1_HOST}.csr -CA ${CA_DIR}/ca.crt -CAkey ${CA_DIR}/ca.key -CAcreateserial -out ${WORKER1_HOST}.crt -days 1000 -sha256 -extensions v3_req -extfile openssl-${WORKER1_HOST}.cnf
```

Create kubeconfig for worker-1:
```bash
LB=192.168.5.30
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=${CA_DIR}/ca.crt \
  --embed-certs=true \
  --server=https://${LB}:6443 \
  --kubeconfig=${WORKER1_HOST}.kubeconfig
kubectl config set-credentials system:node:${WORKER1_HOST} \
  --client-certificate=${WORKER1_HOST}.crt \
  --client-key=${WORKER1_HOST}.key \
  --embed-certs=true \
  --kubeconfig=${WORKER1_HOST}.kubeconfig
kubectl config set-context default --cluster=kubernetes-the-hard-way --user=system:node:${WORKER1_HOST} --kubeconfig=${WORKER1_HOST}.kubeconfig
kubectl config use-context default --kubeconfig=${WORKER1_HOST}.kubeconfig
```

Copy artifacts to worker-1:
```bash
scp ${WORKER1_HOST}.crt ${WORKER1_HOST}.key ${WORKER1_HOST}.kubeconfig ${CA_DIR}/ca.crt worker-1:~/
scp ~/kube-proxy.kubeconfig worker-1:~/
```

## On worker-1: Install Binaries
```bash
K8S_VERSION=v1.30.4
ARCH=amd64
curl -L --remote-name-all https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/{kubelet,kube-proxy,kubectl}
chmod +x kubelet kube-proxy kubectl
sudo mv kubelet kube-proxy kubectl /usr/local/bin/
```

Directories:
```bash
sudo mkdir -p /etc/cni/net.d /opt/cni/bin /var/lib/{kubelet,kube-proxy,kubernetes} /var/run/kubernetes
sudo mv ${HOSTNAME}.crt ${HOSTNAME}.key /var/lib/kubelet/
sudo mv ${HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
sudo mv ca.crt /var/lib/kubernetes/
sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
```

Kubelet config:
```bash
sudo tee /var/lib/kubelet/kubelet-config.yaml <<'EOF'
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.crt"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.96.0.10"
resolvConf: "/run/systemd/resolve/resolv.conf"
rotateCertificates: true
serverTLSBootstrap: true
EOF
```

Kubelet unit (containerd runtime):
```bash
sudo tee /etc/systemd/system/kubelet.service <<'EOF'
[Unit]
Description=Kubernetes Kubelet
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
  --tls-cert-file=/var/lib/kubelet/${HOSTNAME}.crt \
  --tls-private-key-file=/var/lib/kubelet/${HOSTNAME}.key \
  --register-node=true \
  --cgroup-driver=systemd \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

kube-proxy config & unit:
```bash
sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml <<'EOF'
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.32.0.0/12"  # Adjust to chosen pod CIDR (Weave default)
EOF

sudo tee /etc/systemd/system/kube-proxy.service <<'EOF'
[Unit]
Description=Kubernetes Kube Proxy
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kube-proxy --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Start services:
```bash
sudo systemctl daemon-reload
sudo systemctl enable kubelet kube-proxy
sudo systemctl start kubelet kube-proxy
```

Verification (on master-1):
```bash
kubectl --kubeconfig ~/admin.kubeconfig get nodes
```
Expect NotReady until CNI applied.

## Next
TLS bootstrap for worker-2: `10-tls-bootstrapping-kubernetes-workers-modern.md`.
