# Migrating Worker Nodes from Docker to containerd

Kubernetes 1.24+ removed dockershim; containerd is the recommended CRI. While Docker still works indirectly (it installs containerd under the hood), using pure containerd reduces dependencies and aligns with upstream defaults.

## Why Replace Docker?
- Removes an extra layer (dockershim) that is deprecated.
- Smaller footprint, fewer services to patch.
- Matches defaults used by kubeadm & most managed Kubernetes offerings.
- Native support for CRI image management and snapshotters (overlayfs).

## High-Level Steps
1. Drain (optional now, before workloads) – currently cluster not bootstrapped, so can skip.
2. Remove Docker related packages & systemd units.
3. Install containerd from upstream or Ubuntu repo (pin to a tested version).
4. Configure systemd cgroup driver to match kubelet.
5. Enable required kernel modules & sysctls (some already set by existing script).
6. Restart and validate `crictl` + `nerdctl` (optional) + image pull.

## Versions
- containerd: 1.7.x (current stable)
- runc: latest stable packaged with containerd
- CNI plugins: 1.4.x (to be installed during networking step)

## One-Step Script

Preferred: copy the helper script then execute as root (sudo). This encapsulates the manual steps below and is idempotent.

```bash
scp migrate-to-containerd.sh worker-1:~/
scp migrate-to-containerd.sh worker-2:~/
ssh worker-1 'chmod +x migrate-to-containerd.sh && sudo ./migrate-to-containerd.sh'
ssh worker-2 'chmod +x migrate-to-containerd.sh && sudo ./migrate-to-containerd.sh'
```

If you prefer to run commands manually, the raw sequence is:

## Commands (Run on each worker: worker-1, worker-2)

```bash
# 1. Remove Docker components
sudo systemctl disable --now docker.service docker.socket || true
sudo apt-get remove -y docker-ce docker-ce-cli containerd.io || true
sudo apt-get autoremove -y

# 2. Install dependencies
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# 3. Add containerd (Ubuntu) repo (uses Docker repo for latest containerd) OR use distro package.
# Option A: Use upstream Docker repo (already added previously). If removed, re-add:
if [ ! -f /usr/share/keyrings/docker-archive-keyring.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
fi
sudo apt-get update
sudo apt-get install -y containerd.io

# 4. Generate default config and switch to systemd cgroups
test -d /etc/containerd || sudo mkdir /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Optional: ensure sandbox (pause) image is reachable (registry.k8s.io):
if ! grep -q 'sandbox_image' /etc/containerd/config.toml; then
  sudo bash -c 'cat >> /etc/containerd/config.toml <<EOF
[plugins."io.containerd.grpc.v1.cri".sandbox_image]
# Using default pause image; can override if behind proxy.
EOF'
fi

# 5. Kernel modules (some already managed) & sysctl
sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 6. Enable & start containerd
sudo systemctl enable containerd
sudo systemctl restart containerd

# 7. Install crictl for debugging
CRICTL_VERSION=v1.30.0
ARCH=amd64
sudo curl -L https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz -o /tmp/crictl.tgz
sudo tar -C /usr/local/bin -xzf /tmp/crictl.tgz
rm /tmp/crictl.tgz

# 8. (Optional) nerdctl for Docker-like UX
NERDCTL_VERSION=1.7.6
curl -L https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-${ARCH}.tar.gz -o /tmp/nerdctl.tgz
sudo tar -C /usr/local/bin -xzf /tmp/nerdctl.tgz nerdctl
rm /tmp/nerdctl.tgz

# 9. Test runtime (should list no containers yet)
sudo crictl info | grep -i runtimeType || true
sudo nerdctl version || true
```

## Kubelet Configuration Alignment
When generating kubelet systemd unit later ensure the `--container-runtime-endpoint` points to:
```
--container-runtime-endpoint=unix:///run/containerd/containerd.sock
```
(Modern kubelets auto-detect via CRI socket if installed in default path.)

## Rollback
If needed:
```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
```
Then disable containerd specific customizations (or leave; Docker also uses containerd internally).

## Next
Proceed with certificate creation and kubelet bootstrap using the modernized docs (to be added in this folder).
