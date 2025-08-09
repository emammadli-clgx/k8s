# TLS Bootstrapping (worker-2) (Modernized 2025)

## Why Update?
- Use bootstrap token with current RBAC names
- Enable server certificate rotation
- Avoid manual CSR approval by using proper ClusterRoleBindings

Prereqs: Control plane running, `--enable-bootstrap-token-auth=true` in kube-apiserver unit (already) and controller manager has signing flags.

## 1. Create Bootstrap Token (on master-1)
```bash
TOKEN_ID=07401b
TOKEN_SECRET=$(openssl rand -hex 8)   # 16 hex chars
EXPIRY=$(date -u -d '+24 hour' +%Y-%m-%dT%H:%M:%SZ)
cat > bootstrap-token-${TOKEN_ID}.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${TOKEN_ID}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  description: "Worker bootstrap token"
  token-id: ${TOKEN_ID}
  token-secret: ${TOKEN_SECRET}
  expiration: ${EXPIRY}
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: system:bootstrappers:workers
EOF
kubectl apply -f bootstrap-token-${TOKEN_ID}.yaml --kubeconfig ~/kubeconfigs/admin.kubeconfig
BOOTSTRAP_TOKEN="${TOKEN_ID}.${TOKEN_SECRET}"
```

## 2. RBAC Bindings
```bash
kubectl create clusterrolebinding bootstrap-node-auth \
  --clusterrole=system:node-bootstrapper \
  --group=system:bootstrappers:workers --kubeconfig ~/kubeconfigs/admin.kubeconfig

kubectl create clusterrolebinding node-client-cert-auto-approve \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:nodeclient \
  --group=system:bootstrappers:workers --kubeconfig ~/kubeconfigs/admin.kubeconfig

kubectl create clusterrolebinding node-renewal-auto-approve \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:selfnodeclient \
  --group=system:nodes --kubeconfig ~/kubeconfigs/admin.kubeconfig
```

## 3. Prepare worker-2
Copy CA cert (run from master-1 home where pki directory exists):
```bash
scp ~/pki/ca/ca.crt worker-2:~/
```
On worker-2 install binaries (if not already):
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
sudo mv ca.crt /var/lib/kubernetes/
scp master-1:~/kubeconfigs/kube-proxy.kubeconfig ~/  # if not already present locally
sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
```

Bootstrap kubeconfig:
```bash
LB=192.168.5.30
sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-cluster bootstrap \
  --server=https://${LB}:6443 --certificate-authority=/var/lib/kubernetes/ca.crt --embed-certs=true
sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-credentials kubelet-bootstrap --token=${BOOTSTRAP_TOKEN}
sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig set-context bootstrap --cluster=bootstrap --user=kubelet-bootstrap
sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig use-context bootstrap
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

Units:
```bash
sudo tee /etc/systemd/system/kubelet.service <<'EOF'
[Unit]
Description=Kubernetes Kubelet
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet \
  --bootstrap-kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
  --cert-dir=/var/lib/kubelet/pki \
  --register-node=true \
  --cgroup-driver=systemd \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml <<'EOF'
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.32.0.0/12"
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

Start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable kubelet kube-proxy
sudo systemctl start kubelet kube-proxy
```

## 4. Observe CSR
On master-1:
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get csr
```
Should auto-approve due to bindings. If pending, manually approve:
```bash
kubectl certificate approve <csr-name> --kubeconfig ~/kubeconfigs/admin.kubeconfig
```

## 5. Verify Nodes
```bash
kubectl --kubeconfig ~/kubeconfigs/admin.kubeconfig get nodes
```
Both workers appear NotReady until CNI deployed.

## Next
Deploy pod network: `12-configure-pod-networking-modern.md`.
