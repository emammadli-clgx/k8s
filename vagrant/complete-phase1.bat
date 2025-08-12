@echo off
echo === Phase 1: Prerequisites Setup - Remaining Steps ===
echo.

echo [Step 1] Disabling swap on all VMs...
echo Running on master-1...
vagrant ssh master-1 -c "sudo swapoff -a && sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab"

echo Running on master-2...
vagrant ssh master-2 -c "sudo swapoff -a && sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab"

echo Running on worker-1...
vagrant ssh worker-1 -c "sudo swapoff -a && sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab"

echo Running on worker-2...
vagrant ssh worker-2 -c "sudo swapoff -a && sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab"

echo.
echo [Step 2] Installing containerd on all VMs...
echo This may take several minutes...

for %%i in (master-1 master-2 worker-1 worker-2) do (
    echo.
    echo Installing containerd on %%i...
    vagrant ssh %%i -c "sudo mkdir -p /tmp/k8s-install && cd /tmp/k8s-install && echo 'Downloading containerd...' && wget -q https://github.com/containerd/containerd/releases/download/v1.7.8/containerd-1.7.8-linux-amd64.tar.gz && echo 'Installing containerd...' && sudo tar -C /usr/local -xzf containerd-1.7.8-linux-amd64.tar.gz && echo 'Downloading runc...' && wget -q https://github.com/opencontainers/runc/releases/download/v1.1.9/runc.amd64 && sudo install -m 755 runc.amd64 /usr/local/sbin/runc && echo 'Downloading CNI plugins...' && wget -q https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz && sudo mkdir -p /opt/cni/bin && sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-v1.3.0.tgz && echo 'Installation completed on %%i'"
)

echo.
echo [Step 3] Configuring containerd on all VMs...
for %%i in (master-1 master-2 worker-1 worker-2) do (
    echo.
    echo Configuring containerd on %%i...
    vagrant ssh %%i -c "sudo mkdir -p /etc/containerd && containerd config default | sudo tee /etc/containerd/config.toml >/dev/null && sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml && sudo tee /etc/systemd/system/containerd.service >/dev/null <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable containerd && sudo systemctl start containerd && echo 'Containerd configured on %%i'"
)

echo.
echo [Step 4] Installing crictl on all VMs...
for %%i in (master-1 master-2 worker-1 worker-2) do (
    echo.
    echo Installing crictl on %%i...
    vagrant ssh %%i -c "cd /tmp/k8s-install && wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/crictl-v1.28.0-linux-amd64.tar.gz && sudo tar -C /usr/local/bin -xzf crictl-v1.28.0-linux-amd64.tar.gz && sudo tee /etc/crictl.yaml >/dev/null <<'EOF'
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock  
timeout: 2
debug: false
pull-image-on-create: false
EOF
echo 'crictl installed on %%i'"
)

echo.
echo [Step 5] Configuring kernel modules and sysctl on all VMs...
for %%i in (master-1 master-2 worker-1 worker-2) do (
    echo.
    echo Configuring kernel on %%i...
    vagrant ssh %%i -c "sudo tee /etc/modules-load.d/containerd.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter && sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system >/dev/null && echo 'Kernel configured on %%i'"
)

echo.
echo === Phase 1 Prerequisites Setup Completed! ===
echo.
echo All VMs now have:
echo   - containerd v1.7.8 installed and running
echo   - runc v1.1.9 installed  
echo   - crictl v1.28.0 installed
echo   - CNI plugins installed
echo   - Kernel modules configured
echo   - Swap disabled
echo.
echo Ready for Phase 2: Certificate generation
echo.
pause
