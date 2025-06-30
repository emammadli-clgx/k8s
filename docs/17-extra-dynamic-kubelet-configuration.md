# Dynamic Kubelet Configuration

`sudo apt install -y jq`

```bash
NODE_NAME="worker-1"; curl -sSL "https://localhost:6443/api/v1/nodes/${NODE_NAME}/proxy/configz" -k --kubeconfig admin.kubeconfig | jq '.kubeletconfig|.kind="KubeletConfiguration"|.apiVersion="kubelet.config.k8s.io/v1beta1"' > kubelet_configz_${NODE_NAME}
```

```bash
kubectl -n kube-system create configmap nodes-config --from-file=kubelet=kubelet_configz_${NODE_NAME} --append-hash -o yaml
```

Edit node to use the dynamically created configuration
```bash
kubectl edit worker-2
```

Configure Kubelet Service

Create the `kubelet.service` systemd unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --bootstrap-kubeconfig="/var/lib/kubelet/bootstrap-kubeconfig" \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --dynamic-config-dir=/var/lib/kubelet/dynamic-config \
  --cert-dir=/var/lib/kubelet/pki/ \
  --network-plugin=cni \
  --register-node=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```