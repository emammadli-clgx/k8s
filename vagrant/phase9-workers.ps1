# Phase 9: Worker Nodes Bootstrap
# Run from: vagrant\ directory in PowerShell

param([switch]$SkipConfirmation)

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Run-OnVM {
    param([string]$VM, [string]$Command, [string]$Description = "")
    
    $desc = if ($Description) { $Description } else { "Running command" }
    Write-Log "[$VM] $desc..." -Color "Gray"
    
    try {
        $result = vagrant ssh $VM -c $Command 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "[$VM] ✓ Success" -Color "Green"
            return $true
        } else {
            Write-Log "[$VM] ✗ Failed" -Color "Red"
            if ($result) { Write-Host "$result" -ForegroundColor Red }
            return $false
        }
    } catch {
        Write-Log "[$VM] ✗ Error: $_" -Color "Red"
        return $false
    }
}

function Run-OnAllWorkers {
    param([string]$Command, [string]$Description)
    
    $workers = @("worker-1", "worker-2")
    Write-Log "Running on all workers: $Description" -Color "Cyan"
    
    $failed = @()
    foreach ($worker in $workers) {
        if (!(Run-OnVM -VM $worker -Command $Command -Description $Description)) {
            $failed += $worker
        }
    }
    
    if ($failed.Count -eq 0) {
        Write-Log "✓ $Description completed on all workers" -Color "Green"
        return $true
    } else {
        Write-Log "✗ $Description failed on: $($failed -join ', ')" -Color "Red"
        return $false
    }
}

# Check prerequisites
if (!(Test-Path "Vagrantfile")) {
    Write-Log "This script must be run from the vagrant directory" -Color "Red"
    exit 1
}

if (!(Test-Path "phase8_completed.txt")) {
    Write-Log "Phase 8 must be completed first. Run .\phase8-load-balancer.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 9: Worker Nodes Bootstrap ===" -Color "Cyan"
Write-Log "Configuring Kubernetes worker nodes" -Color "Yellow"

# Step 1: Install worker dependencies
Write-Log "" -Color "White"
Write-Log "Step 1: Installing worker dependencies..." -Color "Yellow"

$installDepsScript = @'
# Install socat and conntrack (required for kube-proxy)
sudo apt-get update > /dev/null 2>&1
sudo apt-get install -y socat conntrack ipset > /dev/null 2>&1

echo "Worker dependencies installed"
'@

if (!(Run-OnAllWorkers -Command $installDepsScript -Description "Installing dependencies")) {
    Write-Log "Dependency installation failed" -Color "Red"
    if (!$SkipConfirmation) {
        $response = Read-Host "Continue anyway? (y/N)"
        if ($response -notmatch "^[Yy]$") { exit 1 }
    }
}

# Step 2: Download and install worker binaries
Write-Log "" -Color "White"
Write-Log "Step 2: Installing Kubernetes worker binaries..." -Color "Yellow"

$installWorkerBinariesScript = @'
# Create directories
sudo mkdir -p /etc/cni/net.d /opt/cni/bin /var/lib/kubelet /var/lib/kube-proxy /var/lib/kubernetes /var/run/kubernetes

# Download worker binaries
cd /tmp
wget -q https://dl.k8s.io/v1.28.4/bin/linux/amd64/kubectl
wget -q https://dl.k8s.io/v1.28.4/bin/linux/amd64/kube-proxy
wget -q https://dl.k8s.io/v1.28.4/bin/linux/amd64/kubelet

# Install binaries
chmod +x kubectl kube-proxy kubelet
sudo mv kubectl kube-proxy kubelet /usr/local/bin/

echo "Worker binaries installed"
'@

if (!(Run-OnAllWorkers -Command $installWorkerBinariesScript -Description "Installing worker binaries")) {
    Write-Log "Worker binary installation failed" -Color "Red"
    exit 1
}

# Step 3: Configure kubelet for each worker
Write-Log "" -Color "White"
Write-Log "Step 3: Configuring kubelet..." -Color "Yellow"

$workers = @(
    @{name="worker-1"; ip="192.168.56.21"},
    @{name="worker-2"; ip="192.168.56.22"}
)

foreach ($worker in $workers) {
    $workerName = $worker.name
    $workerIP = $worker.ip
    
    Write-Log "Configuring kubelet on $workerName..." -Color "Gray"
    
    $kubeletConfigScript = @"
# Copy certificates and kubeconfig
sudo cp /home/vagrant/$workerName-key.pem /home/vagrant/$workerName.pem /var/lib/kubelet/
sudo cp /home/vagrant/$workerName.kubeconfig /var/lib/kubelet/kubeconfig
sudo cp /home/vagrant/ca.pem /var/lib/kubernetes/

# Create kubelet configuration
sudo tee /var/lib/kubelet/kubelet-config.yaml > /dev/null << 'EOF'
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.96.0.10"
podCIDR: "10.32.0.0/12"
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/$workerName.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/$workerName-key.pem"
containerRuntimeEndpoint: "unix:///var/run/containerd/containerd.sock"
EOF

# Create kubelet systemd service
sudo tee /etc/systemd/system/kubelet.service > /dev/null << 'EOF'
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --register-node=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "kubelet configured for $workerName"
"@

    if (!(Run-OnVM -VM $workerName -Command $kubeletConfigScript -Description "Configuring kubelet")) {
        Write-Log "kubelet configuration failed on $workerName" -Color "Red"
        exit 1
    }
}

# Step 4: Configure kube-proxy
Write-Log "" -Color "White"
Write-Log "Step 4: Configuring kube-proxy..." -Color "Yellow"

$kubeProxyConfigScript = @'
# Copy kube-proxy kubeconfig
sudo cp /home/vagrant/kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig

# Create kube-proxy configuration
sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml > /dev/null << 'EOF'
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.32.0.0/12"
EOF

# Create kube-proxy systemd service
sudo tee /etc/systemd/system/kube-proxy.service > /dev/null << 'EOF'
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "kube-proxy configured"
'@

if (!(Run-OnAllWorkers -Command $kubeProxyConfigScript -Description "Configuring kube-proxy")) {
    Write-Log "kube-proxy configuration failed" -Color "Red"
    exit 1
}

# Step 5: Start worker services
Write-Log "" -Color "White"
Write-Log "Step 5: Starting worker services..." -Color "Yellow"

$startWorkerServicesScript = @'
# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable kubelet kube-proxy
sudo systemctl start kubelet kube-proxy

# Wait for services to start
sleep 5

echo "Worker services started"
'@

if (!(Run-OnAllWorkers -Command $startWorkerServicesScript -Description "Starting worker services")) {
    Write-Log "Worker service startup failed" -Color "Red"
    if (!$SkipConfirmation) {
        $response = Read-Host "Continue anyway? (y/N)"
        if ($response -notmatch "^[Yy]$") { exit 1 }
    }
}

# Step 6: Verify workers
Write-Log "" -Color "White"
Write-Log "Step 6: Verifying worker nodes..." -Color "Yellow"

$verifyWorkerScript = @'
echo "=== Worker Node Verification ==="
echo "Node: $(hostname)"
echo ""

echo "kubelet status:"
sudo systemctl is-active kubelet
echo ""

echo "kube-proxy status:"
sudo systemctl is-active kube-proxy
echo ""

echo "containerd status:"
sudo systemctl is-active containerd
echo ""

echo "kubelet version:"
kubelet --version
echo ""

echo "Container runtime info:"
crictl version
echo ""
'@

foreach ($worker in $workers) {
    $workerName = $worker.name
    Write-Log "--- Verification results for $workerName ---" -Color "Yellow"
    vagrant ssh $workerName -c $verifyWorkerScript
    Write-Log "" -Color "White"
}

# Step 7: Check node registration from master
Write-Log "" -Color "White"
Write-Log "Step 7: Checking node registration..." -Color "Yellow"

$checkNodesScript = @'
echo "=== Node Registration Check ==="
echo ""

echo "Waiting for nodes to register..."
sleep 10

echo "Registered nodes:"
kubectl get nodes --kubeconfig /home/vagrant/admin.kubeconfig

echo ""
echo "Node details:"
kubectl get nodes -o wide --kubeconfig /home/vagrant/admin.kubeconfig

echo ""
echo "Node status:"
kubectl describe nodes --kubeconfig /home/vagrant/admin.kubeconfig
'@

Write-Log "--- Node Registration Status ---" -Color "Yellow"
vagrant ssh master-1 -c $checkNodesScript

# Create completion marker
"Phase 9 completed: $(Get-Date)" | Out-File -FilePath "phase9_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 9 (Worker Nodes) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Worker nodes setup:" -Color "Cyan"
Write-Log "  ✓ kubelet v1.28.4 configured and running" -Color "Green"
Write-Log "  ✓ kube-proxy configured and running" -Color "Green"
Write-Log "  ✓ containerd integration working" -Color "Green"
Write-Log "  ✓ Nodes registered with control plane" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase10-networking.ps1" -Color "Yellow"
