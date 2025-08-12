# Phase 1: Prerequisites Setup
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

function Run-OnAllVMs {
    param([string]$Command, [string]$Description)
    
    $vms = @("master-1", "master-2", "worker-1", "worker-2")
    Write-Log "Running on all VMs: $Description" -Color "Cyan"
    
    $failed = @()
    foreach ($vm in $vms) {
        if (!(Run-OnVM -VM $vm -Command $Command -Description $Description)) {
            $failed += $vm
        }
    }
    
    if ($failed.Count -eq 0) {
        Write-Log "✓ $Description completed on all VMs" -Color "Green"
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

Write-Log "=== Phase 1: Prerequisites Setup ===" -Color "Cyan"
Write-Log "Setting up Kubernetes prerequisites on all VMs" -Color "Yellow"

# Step 1: Disable swap
Write-Log "" -Color "White"
Write-Log "Step 1: Disabling swap on all VMs..." -Color "Yellow"
$disableSwapCmd = 'sudo swapoff -a && sudo sed -i "/ swap / s/^\(.*\)$/#\1/g" /etc/fstab'
if (!(Run-OnAllVMs -Command $disableSwapCmd -Description "Disabling swap")) {
    if (!$SkipConfirmation) {
        $response = Read-Host "Swap disable failed on some VMs. Continue anyway? (y/N)"
        if ($response -notmatch "^[Yy]$") { exit 1 }
    }
}

# Step 2: Install containerd
Write-Log "" -Color "White"
Write-Log "Step 2: Installing containerd and dependencies..." -Color "Yellow"
$installContainerdScript = @'
# Create temp directory
sudo mkdir -p /tmp/k8s-install
cd /tmp/k8s-install

# Download containerd
echo "Downloading containerd..."
wget -q https://github.com/containerd/containerd/releases/download/v1.7.8/containerd-1.7.8-linux-amd64.tar.gz

# Extract and install containerd
echo "Installing containerd..."
sudo tar -C /usr/local -xzf containerd-1.7.8-linux-amd64.tar.gz

# Download runc
echo "Downloading runc..."
wget -q https://github.com/opencontainers/runc/releases/download/v1.1.9/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

# Download CNI plugins
echo "Downloading CNI plugins..."
wget -q https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-v1.3.0.tgz

echo "Containerd installation completed"
'@

if (!(Run-OnAllVMs -Command $installContainerdScript -Description "Installing containerd")) {
    Write-Log "Containerd installation failed. Exiting." -Color "Red"
    exit 1
}

# Step 3: Configure containerd
Write-Log "" -Color "White"
Write-Log "Step 3: Configuring containerd..." -Color "Yellow"
$configureContainerdScript = @'
# Create containerd config directory
sudo mkdir -p /etc/containerd

# Generate default config
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# Enable SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Create systemd service file
sudo tee /etc/systemd/system/containerd.service > /dev/null << 'EOF'
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

# Enable and start containerd
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd

echo "Containerd configured and started"
'@

if (!(Run-OnAllVMs -Command $configureContainerdScript -Description "Configuring containerd")) {
    Write-Log "Containerd configuration failed. Exiting." -Color "Red"
    exit 1
}

# Step 4: Install crictl
Write-Log "" -Color "White"
Write-Log "Step 4: Installing crictl..." -Color "Yellow"
$installCrictlScript = @'
cd /tmp/k8s-install
echo "Downloading crictl..."
wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/crictl-v1.28.0-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf crictl-v1.28.0-linux-amd64.tar.gz

# Configure crictl
sudo tee /etc/crictl.yaml > /dev/null << 'EOF'
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 2
debug: false
pull-image-on-create: false
EOF

echo "crictl installed and configured"
'@

if (!(Run-OnAllVMs -Command $installCrictlScript -Description "Installing crictl")) {
    Write-Log "crictl installation failed. Exiting." -Color "Red"
    exit 1
}

# Step 5: Configure kernel modules
Write-Log "" -Color "White"
Write-Log "Step 5: Configuring kernel modules and sysctl..." -Color "Yellow"
$configureKernelScript = @'
# Configure kernel modules
sudo tee /etc/modules-load.d/containerd.conf > /dev/null << 'EOF'
overlay
br_netfilter
EOF

# Load modules immediately
sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl parameters
sudo tee /etc/sysctl.d/99-kubernetes-cri.conf > /dev/null << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl settings
sudo sysctl --system > /dev/null

echo "Kernel configuration completed"
'@

if (!(Run-OnAllVMs -Command $configureKernelScript -Description "Configuring kernel")) {
    Write-Log "Kernel configuration failed. Exiting." -Color "Red"
    exit 1
}

# Step 6: Verify installation
Write-Log "" -Color "White"
Write-Log "Step 6: Verifying installation..." -Color "Yellow"
$verifyScript = @'
echo "=== Verification Results ==="
echo "Node: $(hostname)"
echo ""
echo "Containerd version:"
containerd --version
echo ""
echo "Runc version:"
runc --version | head -1
echo ""
echo "crictl version:"
crictl --version
echo ""
echo "Containerd service status:"
sudo systemctl is-active containerd
echo ""
echo "CNI plugins installed:"
ls /opt/cni/bin/ | wc -l
echo "plugins available"
echo ""
'@

Write-Log "Running verification on all VMs..." -Color "Gray"
$vms = @("master-1", "master-2", "worker-1", "worker-2")
foreach ($vm in $vms) {
    Write-Log "--- Verification results for $vm ---" -Color "Yellow"
    vagrant ssh $vm -c $verifyScript
    Write-Log "" -Color "White"
}

# Create completion marker
"Phase 1 completed: $(Get-Date)" | Out-File -FilePath "phase1_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 1 (Prerequisites) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "All VMs now have:" -Color "Cyan"
Write-Log "  ✓ containerd v1.7.8 installed and running" -Color "Green"
Write-Log "  ✓ runc v1.1.9 installed" -Color "Green"
Write-Log "  ✓ crictl v1.28.0 installed" -Color "Green"
Write-Log "  ✓ CNI plugins installed" -Color "Green"
Write-Log "  ✓ Kernel modules configured" -Color "Green"
Write-Log "  ✓ Swap disabled" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase2-certificates.ps1" -Color "Yellow"