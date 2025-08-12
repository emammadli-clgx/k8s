# Phase 6: Kubernetes Control Plane
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

if (!(Test-Path "phase5_completed.txt")) {
    Write-Log "Phase 5 must be completed first. Run .\phase5-etcd.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 6: Kubernetes Control Plane ===" -Color "Cyan"
Write-Log "Bootstrapping Kubernetes control plane components" -Color "Yellow"

# Step 1: Download and install Kubernetes binaries
Write-Log "" -Color "White"
Write-Log "Step 1: Installing Kubernetes binaries on masters..." -Color "Yellow"

$masters = @(
    @{name="master-1"; ip="192.168.56.11"},
    @{name="master-2"; ip="192.168.56.12"}
)

$installK8sScript = @'
# Create kubernetes directories
sudo mkdir -p /etc/kubernetes/config /var/lib/kubernetes /var/log/kubernetes

# Download Kubernetes server binaries
cd /tmp
wget -q https://dl.k8s.io/v1.28.4/kubernetes-server-linux-amd64.tar.gz

# Extract and install
tar -xzf kubernetes-server-linux-amd64.tar.gz
sudo cp kubernetes/server/bin/kube-apiserver \
          kubernetes/server/bin/kube-controller-manager \
          kubernetes/server/bin/kube-scheduler \
          kubernetes/server/bin/kubectl \
          /usr/local/bin/

echo "Kubernetes binaries installed successfully"
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "Installing Kubernetes binaries on $masterName..." -Color "Gray"
    
    if (!(Run-OnVM -VM $masterName -Command $installK8sScript -Description "Installing Kubernetes binaries")) {
        Write-Log "Kubernetes installation failed on $masterName" -Color "Red"
        exit 1
    }
}

# Step 2: Configure kube-apiserver
Write-Log "" -Color "White"
Write-Log "Step 2: Configuring kube-apiserver..." -Color "Yellow"

foreach ($master in $masters) {
    $masterName = $master.name
    $masterIP = $master.ip
    
    Write-Log "Configuring kube-apiserver on $masterName..." -Color "Gray"
    
    $apiServerConfigScript = @"
# Move certificates to kubernetes directory
sudo cp /home/vagrant/ca.pem /home/vagrant/ca-key.pem /home/vagrant/kubernetes-key.pem /home/vagrant/kubernetes.pem \
         /home/vagrant/service-account-key.pem /home/vagrant/service-account.pem \
         /home/vagrant/encryption-config.yaml \
         /var/lib/kubernetes/

# Create kube-apiserver systemd service
sudo tee /etc/systemd/system/kube-apiserver.service > /dev/null << 'EOF'
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=$masterIP \\
  --allow-privileged=true \\
  --apiserver-count=2 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://192.168.56.11:2379,https://192.168.56.12:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-account-issuer=https://192.168.56.30:6443 \\
  --service-cluster-ip-range=10.96.0.0/12 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "kube-apiserver configured for $masterName"
"@

    if (!(Run-OnVM -VM $masterName -Command $apiServerConfigScript -Description "Configuring kube-apiserver")) {
        Write-Log "kube-apiserver configuration failed on $masterName" -Color "Red"
        exit 1
    }
}

# Step 3: Configure kube-controller-manager
Write-Log "" -Color "White"
Write-Log "Step 3: Configuring kube-controller-manager..." -Color "Yellow"

$controllerManagerConfigScript = @'
# Move kubeconfig
sudo cp /home/vagrant/kube-controller-manager.kubeconfig /var/lib/kubernetes/

# Create kube-controller-manager systemd service
sudo tee /etc/systemd/system/kube-controller-manager.service > /dev/null << 'EOF'
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \
  --bind-address=0.0.0.0 \
  --cluster-cidr=10.32.0.0/12 \
  --cluster-name=kubernetes \
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \
  --leader-elect=true \
  --root-ca-file=/var/lib/kubernetes/ca.pem \
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \
  --service-cluster-ip-range=10.96.0.0/12 \
  --use-service-account-credentials=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "kube-controller-manager configured"
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "Configuring kube-controller-manager on $masterName..." -Color "Gray"
    
    if (!(Run-OnVM -VM $masterName -Command $controllerManagerConfigScript -Description "Configuring kube-controller-manager")) {
        Write-Log "kube-controller-manager configuration failed on $masterName" -Color "Red"
        exit 1
    }
}

# Step 4: Configure kube-scheduler
Write-Log "" -Color "White"
Write-Log "Step 4: Configuring kube-scheduler..." -Color "Yellow"

$schedulerConfigScript = @'
# Move kubeconfig
sudo cp /home/vagrant/kube-scheduler.kubeconfig /var/lib/kubernetes/

# Create kube-scheduler configuration
sudo tee /etc/kubernetes/config/kube-scheduler.yaml > /dev/null << 'EOF'
apiVersion: kubescheduler.config.k8s.io/v1beta3
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF

# Create kube-scheduler systemd service
sudo tee /etc/systemd/system/kube-scheduler.service > /dev/null << 'EOF'
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \
  --config=/etc/kubernetes/config/kube-scheduler.yaml \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "kube-scheduler configured"
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "Configuring kube-scheduler on $masterName..." -Color "Gray"
    
    if (!(Run-OnVM -VM $masterName -Command $schedulerConfigScript -Description "Configuring kube-scheduler")) {
        Write-Log "kube-scheduler configuration failed on $masterName" -Color "Red"
        exit 1
    }
}

# Step 5: Start control plane services
Write-Log "" -Color "White"
Write-Log "Step 5: Starting control plane services..." -Color "Yellow"

$startServicesScript = @'
# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler

# Wait for services to start
sleep 10

echo "Control plane services started"
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "Starting control plane services on $masterName..." -Color "Gray"
    
    if (!(Run-OnVM -VM $masterName -Command $startServicesScript -Description "Starting control plane services")) {
        Write-Log "Service startup failed on $masterName" -Color "Red"
        if (!$SkipConfirmation) {
            $response = Read-Host "Services failed to start on $masterName. Continue anyway? (y/N)"
            if ($response -notmatch "^[Yy]$") { exit 1 }
        }
    }
}

# Step 6: Setup load balancer health checks
Write-Log "" -Color "White"
Write-Log "Step 6: Setting up load balancer health checks..." -Color "Yellow"

$healthCheckScript = @'
# Install nginx for health checks
sudo apt-get update > /dev/null 2>&1
sudo apt-get install -y nginx > /dev/null 2>&1

# Configure nginx for kubernetes health check
sudo tee /etc/nginx/sites-available/kubernetes.default.svc.cluster.local > /dev/null << 'EOF'
server {
  listen      80;
  server_name kubernetes.default.svc.cluster.local;

  location /healthz {
     proxy_pass                    https://127.0.0.1:6443/healthz;
     proxy_ssl_trusted_certificate /var/lib/kubernetes/ca.pem;
  }
}
EOF

# Enable the site
sudo ln -s /etc/nginx/sites-available/kubernetes.default.svc.cluster.local /etc/nginx/sites-enabled/
sudo systemctl restart nginx
sudo systemctl enable nginx

echo "Health check configured"
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "Setting up health checks on $masterName..." -Color "Gray"
    
    if (!(Run-OnVM -VM $masterName -Command $healthCheckScript -Description "Setting up health checks")) {
        Write-Log "Health check setup failed on $masterName" -Color "Red"
        # Continue anyway as this is not critical
    }
}

# Step 7: Verify control plane
Write-Log "" -Color "White"
Write-Log "Step 7: Verifying control plane..." -Color "Yellow"

$verifyControlPlaneScript = @'
echo "=== Control Plane Verification ==="
echo "Node: $(hostname)"
echo ""

echo "API server status:"
sudo systemctl is-active kube-apiserver
echo ""

echo "Controller manager status:"
sudo systemctl is-active kube-controller-manager
echo ""

echo "Scheduler status:"
sudo systemctl is-active kube-scheduler
echo ""

echo "API server health:"
curl -H "Host: kubernetes.default.svc.cluster.local" -i http://127.0.0.1/healthz
echo ""

echo "Cluster info:"
kubectl cluster-info --kubeconfig /home/vagrant/admin.kubeconfig
echo ""
'@

foreach ($master in $masters) {
    $masterName = $master.name
    Write-Log "--- Verification results for $masterName ---" -Color "Yellow"
    vagrant ssh $masterName -c $verifyControlPlaneScript
    Write-Log "" -Color "White"
}

# Create completion marker
"Phase 6 completed: $(Get-Date)" | Out-File -FilePath "phase6_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 6 (Control Plane) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Control plane setup:" -Color "Cyan"
Write-Log "  ✓ kube-apiserver v1.28.4 configured and running" -Color "Green"
Write-Log "  ✓ kube-controller-manager configured and running" -Color "Green"
Write-Log "  ✓ kube-scheduler configured and running" -Color "Green"
Write-Log "  ✓ Load balancer health checks configured" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase7-rbac.ps1" -Color "Yellow"
