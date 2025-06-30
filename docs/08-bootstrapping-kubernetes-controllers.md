# Bootstrapping the Kubernetes Control Plane

In this lab, you will bootstrap the Kubernetes control plane across two master nodes and configure it for high availability. You will also create an external load balancer that exposes the Kubernetes API to remote clients. The following components will be installed on each node: Kubernetes API Server, Scheduler, and Controller Manager.

## Prerequisites

The commands in this lab must be run on each master node: `master-1` and `master-2`. Log in to each master node using SSH.

### Running commands in parallel with tmux

[tmux](https://github.com/tmux/tmux/wiki) can be used to run commands on multiple compute instances at the same time. See the [tmux guide](https://www.hamvocke.com/blog/a-quick-and-easy-guide-to-tmux/) for more details.

## Provision the Kubernetes Control Plane

Create the Kubernetes configuration directory:

```bash
sudo mkdir -p /etc/kubernetes/config
```

### Download and Install the Kubernetes Controller Binaries

Download the official Kubernetes release binaries:

```bash
wget -q --show-progress --https-only --timestamping 
  "https://storage.googleapis.com/kubernetes-release/release/v1.29.2/bin/linux/amd64/kube-apiserver" 
  "https://storage.googleapis.com/kubernetes-release/release/v1.29.2/bin/linux/amd64/kube-controller-manager" 
  "https://storage.googleapis.com/kubernetes-release/release/v1.29.2/bin/linux/amd64/kube-scheduler" 
  "https://storage.googleapis.com/kubernetes-release/release/v1.29.2/bin/linux/amd64/kubectl"
```

Install the Kubernetes binaries:

```bash
{
  chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
  sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
}
```

### Configure the Kubernetes API Server

```bash
{
  sudo mkdir -p /var/lib/kubernetes/

  sudo cp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem 
    service-account-key.pem service-account.pem 
    etcd-server-key.pem etcd-server.pem 
    encryption-config.yaml /var/lib/kubernetes/
}
```

The instance's internal IP address will be used to advertise the API Server to members of the cluster. Retrieve the internal IP address for the current compute instance:

```bash
INTERNAL_IP=$(ip addr show enp0s8 | grep "inet " | awk '{print $2}' | cut -d / -f 1)
```

Create the `kube-apiserver.service` systemd unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver 
  --advertise-address=${INTERNAL_IP} 
  --allow-privileged=true 
  --apiserver-count=2 
  --audit-log-maxage=30 
  --audit-log-maxbackup=3 
  --audit-log-maxsize=100 
  --audit-log-path=/var/log/audit.log 
  --authorization-mode=Node,RBAC 
  --bind-address=0.0.0.0 
  --client-ca-file=/var/lib/kubernetes/ca.pem 
  --enable-admission-plugins=NodeRestriction,ServiceAccount 
  --enable-bootstrap-token-auth=true 
  --etcd-cafile=/var/lib/kubernetes/ca.pem 
  --etcd-certfile=/var/lib/kubernetes/etcd-server.pem 
  --etcd-keyfile=/var/lib/kubernetes/etcd-server-key.pem 
  --etcd-servers=https://192.168.5.11:2379,https://192.168.5.12:2379 
  --event-ttl=1h 
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml 
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem 
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem 
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem 
  --kubelet-https=true 
  --runtime-config=api/all=true 
  --service-account-key-file=/var/lib/kubernetes/service-account.pem 
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem 
  --service-account-issuer=https://kubernetes.default.svc.cluster.local 
  --service-cluster-ip-range=10.96.0.0/24 
  --service-node-port-range=30000-32767 
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem 
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem 
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Configure the Kubernetes Controller Manager

Move the `kube-controller-manager` kubeconfig into place:

```bash
sudo mv kube-controller-manager.kubeconfig /var/lib/kubernetes/
```

Create the `kube-controller-manager.service` systemd unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager 
  --bind-address=0.0.0.0 
  --cluster-cidr=192.168.5.0/24 
  --cluster-name=kubernetes 
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem 
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem 
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig 
  --leader-elect=true 
  --root-ca-file=/var/lib/kubernetes/ca.pem 
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem 
  --service-cluster-ip-range=10.96.0.0/24 
  --use-service-account-credentials=true 
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Configure the Kubernetes Scheduler

Move the `kube-scheduler` kubeconfig into place:

```bash
sudo mv kube-scheduler.kubeconfig /var/lib/kubernetes/
```

Create the `kube-scheduler.service` systemd unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler 
  --kubeconfig=/var/lib/kubernetes/kube-scheduler.kubeconfig 
  --bind-address=127.0.0.1 
  --leader-elect=true 
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Start the Controller Services

```bash
{
  sudo systemctl daemon-reload
  sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
  sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
}
```

> Allow up to 10 seconds for the Kubernetes API Server to fully initialize.

### Verification

Check the health of the control plane components:

```bash
kubectl get --raw '/healthz?verbose'
```

## The Kubernetes Frontend Load Balancer

In this section, you will provision an external load balancer to front the Kubernetes API servers.

### Provision a Network Load Balancer

Log in to the `loadbalancer` node and install HAProxy:

```bash
sudo apt-get update && sudo apt-get install -y haproxy
```

Configure HAProxy:

```bash
cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg 
frontend kubernetes
    bind 192.168.5.30:6443
    option tcplog
    mode tcp
    default_backend kubernetes-master-nodes

backend kubernetes-master-nodes
    mode tcp
    balance roundrobin
    option tcp-check
    server master-1 192.168.5.11:6443 check fall 3 rise 2
    server master-2 192.168.5.12:6443 check fall 3 rise 2
EOF
```

Restart HAProxy:

```bash
sudo service haproxy restart
```

### Verification

Make a request to the Kubernetes API server through the load balancer:

```bash
curl -k https://192.168.5.30:6443/version
```

> output

```json
{
  "major": "1",
  "minor": "29",
  "gitVersion": "v1.29.2",
  ...
}
```

Next: [Bootstrapping the Kubernetes Worker Nodes](09-bootstrapping-kubernetes-workers.md)
