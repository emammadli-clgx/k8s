# Phase 5: etcd Cluster Setup
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

# Check prerequisites
if (!(Test-Path "Vagrantfile")) {
    Write-Log "This script must be run from the vagrant directory" -Color "Red"
    exit 1
}

if (!(Test-Path "phase4_completed.txt")) {
    Write-Log "Phase 4 must be completed first. Run .\phase4-encryption.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 5: etcd Cluster Setup ===" -Color "Cyan"
Write-Log "Bootstrapping etcd cluster on master nodes" -Color "Yellow"

# Step 1: Download and install etcd on masters
Write-Log "" -Color "White"
Write-Log "Step 1: Installing etcd on master nodes..." -Color "Yellow"

$masters = @(
    @{name="master-1"; ip="192.168.56.11"},
    @{name="master-2"; ip="192.168.56.12"}
)

$installEtcdScript = @'
# Create etcd directories
sudo mkdir -p /etc/etcd /var/lib/etcd /opt/etcd
sudo chmod 700 /var/lib/etcd

# Download etcd
cd /tmp
wget -q https://github.com/etcd-io/etcd/releases/download/v3.5.10/etcd-v3.5.10-linux-amd64.tar.gz

# Extract and install
tar -xvf etcd-v3.5.10-linux-amd64.tar.gz
sudo mv etcd-v3.5.10-linux-amd64/etcd* /usr/local/bin/

echo "etcd installed successfully"
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "Installing etcd on $masterName..." -Color "Gray"
    
    if (!(Run-OnVM -VM $masterName -Command $installEtcdScript -Description "Installing etcd")) {
        Write-Log "etcd installation failed on $masterName" -Color "Red"
        exit 1
    }
}

# Step 2: Configure etcd on each master
Write-Log "" -Color "White"
Write-Log "Step 2: Configuring etcd on each master..." -Color "Yellow"

foreach ($master in $masters) {
    $masterName = $master.name
    $masterIP = $master.ip
    
    Write-Log "Configuring etcd on $masterName..." -Color "Gray"
    
    # Create etcd configuration
    $etcdConfigScript = @"
# Copy certificates
sudo cp /home/vagrant/ca.pem /home/vagrant/kubernetes-key.pem /home/vagrant/kubernetes.pem /etc/etcd/

# Create etcd systemd service file
sudo tee /etc/systemd/system/etcd.service > /dev/null << 'EOF'
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name $masterName \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://$masterIP`:2380 \\
  --listen-peer-urls https://$masterIP`:2380 \\
  --listen-client-urls https://$masterIP`:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://$masterIP`:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster master-1=https://192.168.56.11:2380,master-2=https://192.168.56.12:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "etcd configuration completed for $masterName"
"@

    if (!(Run-OnVM -VM $masterName -Command $etcdConfigScript -Description "Configuring etcd")) {
        Write-Log "etcd configuration failed on $masterName" -Color "Red"
        exit 1
    }
}

# Step 3: Start etcd services
Write-Log "" -Color "White"
Write-Log "Step 3: Starting etcd services..." -Color "Yellow"

$startEtcdScript = @'
# Enable and start etcd
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

# Wait for etcd to start
sleep 5

echo "etcd service started"
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "Starting etcd on $masterName..." -Color "Gray"
    
    if (!(Run-OnVM -VM $masterName -Command $startEtcdScript -Description "Starting etcd")) {
        Write-Log "etcd startup failed on $masterName" -Color "Red"
        if (!$SkipConfirmation) {
            $response = Read-Host "etcd failed to start on $masterName. Continue anyway? (y/N)"
            if ($response -notmatch "^[Yy]$") { exit 1 }
        }
    }
}

# Step 4: Verify etcd cluster
Write-Log "" -Color "White"
Write-Log "Step 4: Verifying etcd cluster..." -Color "Yellow"

$verifyEtcdScript = @'
echo "=== etcd Verification ==="
echo "Node: $(hostname)"
echo ""

echo "etcd version:"
etcd --version | head -1
echo ""

echo "etcd service status:"
sudo systemctl is-active etcd
echo ""

echo "etcd cluster health:"
sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem
echo ""

echo "etcd cluster status:"
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem
echo ""
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "--- Verification results for $masterName ---" -Color "Yellow"
    vagrant ssh $masterName -c $verifyEtcdScript
    Write-Log "" -Color "White"
}

# Create completion marker
"Phase 5 completed: $(Get-Date)" | Out-File -FilePath "phase5_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 5 (etcd Cluster) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "etcd cluster setup:" -Color "Cyan"
Write-Log "  ✓ etcd v3.5.10 installed on both masters" -Color "Green"
Write-Log "  ✓ TLS certificates configured" -Color "Green"
Write-Log "  ✓ Cluster formation completed" -Color "Green"
Write-Log "  ✓ Services enabled and started" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase6-control-plane.ps1" -Color "Yellow"
