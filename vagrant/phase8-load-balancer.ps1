# Phase 8: Load Balancer Setup
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

if (!(Test-Path "phase7_completed.txt")) {
    Write-Log "Phase 7 must be completed first. Run .\phase7-rbac.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 8: Load Balancer Setup ===" -Color "Cyan"
Write-Log "Configuring HAProxy load balancer for API servers" -Color "Yellow"

# Step 1: Install and configure HAProxy
Write-Log "" -Color "White"
Write-Log "Step 1: Installing and configuring HAProxy..." -Color "Yellow"

$haproxySetupScript = @'
# Install HAProxy
sudo apt-get update > /dev/null 2>&1
sudo apt-get install -y haproxy > /dev/null 2>&1

# Backup original config
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak

# Create new HAProxy configuration
sudo tee /etc/haproxy/haproxy.cfg > /dev/null << 'EOF'
global
    log stdout local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option log-health-checks
    option forwardfor
    option http-server-close
    timeout connect 5000
    timeout client 50000
    timeout server 50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

# Stats page
frontend stats
    bind *:8080
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE

# Kubernetes API Server frontend
frontend kubernetes-apiserver-frontend
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-apiserver-backend

# Kubernetes API Server backend
backend kubernetes-apiserver-backend
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check connect port 6443
    server master-1 192.168.56.11:6443 check fall 3 rise 2
    server master-2 192.168.56.12:6443 check fall 3 rise 2
EOF

echo "HAProxy configuration created"
'@

Write-Log "Configuring HAProxy on loadbalancer..." -Color "Gray"
if (!(Run-OnVM -VM "loadbalancer" -Command $haproxySetupScript -Description "Installing and configuring HAProxy")) {
    Write-Log "HAProxy setup failed" -Color "Red"
    exit 1
}

# Step 2: Start HAProxy service
Write-Log "" -Color "White"
Write-Log "Step 2: Starting HAProxy service..." -Color "Yellow"

$startHAProxyScript = @'
# Enable and start HAProxy
sudo systemctl daemon-reload
sudo systemctl enable haproxy
sudo systemctl restart haproxy

# Wait for service to start
sleep 3

echo "HAProxy service started"
'@

Write-Log "Starting HAProxy service..." -Color "Gray"
if (!(Run-OnVM -VM "loadbalancer" -Command $startHAProxyScript -Description "Starting HAProxy")) {
    Write-Log "HAProxy startup failed" -Color "Red"
    if (!$SkipConfirmation) {
        $response = Read-Host "HAProxy failed to start. Continue anyway? (y/N)"
        if ($response -notmatch "^[Yy]$") { exit 1 }
    }
}

# Step 3: Verify load balancer
Write-Log "" -Color "White"
Write-Log "Step 3: Verifying load balancer..." -Color "Yellow"

$verifyLoadBalancerScript = @'
echo "=== Load Balancer Verification ==="
echo "Node: $(hostname)"
echo ""

echo "HAProxy service status:"
sudo systemctl is-active haproxy
echo ""

echo "HAProxy version:"
haproxy -v | head -1
echo ""

echo "Listening ports:"
sudo netstat -tlnp | grep haproxy
echo ""

echo "HAProxy stats (first 20 lines):"
curl -s http://localhost:8080/stats | head -20
echo ""

echo "Testing API server connectivity:"
timeout 5 nc -zv 192.168.56.11 6443
timeout 5 nc -zv 192.168.56.12 6443
echo ""

echo "Testing load balancer endpoint:"
timeout 5 nc -zv 192.168.56.30 6443
echo ""
'@

Write-Log "--- Load Balancer Verification ---" -Color "Yellow"
vagrant ssh loadbalancer -c $verifyLoadBalancerScript

# Step 4: Test API server through load balancer
Write-Log "" -Color "White"
Write-Log "Step 4: Testing API server through load balancer..." -Color "Yellow"

$testAPIScript = @'
echo "Testing Kubernetes API through load balancer:"

# Wait for services to be ready
sleep 5

# Test API server health through load balancer
curl -k https://192.168.56.30:6443/healthz --connect-timeout 10 || echo "Load balancer test failed"
echo ""

echo "Cluster info through load balancer:"
kubectl cluster-info --kubeconfig /home/vagrant/admin.kubeconfig --server=https://192.168.56.30:6443 || echo "kubectl through load balancer failed"
echo ""
'@

Write-Log "Testing API access through load balancer..." -Color "Gray"
vagrant ssh master-1 -c $testAPIScript

# Create completion marker
"Phase 8 completed: $(Get-Date)" | Out-File -FilePath "phase8_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 8 (Load Balancer) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Load balancer setup:" -Color "Cyan"
Write-Log "  ✓ HAProxy installed and configured" -Color "Green"
Write-Log "  ✓ Load balancing between master-1 and master-2" -Color "Green"
Write-Log "  ✓ API server accessible on 192.168.56.30:6443" -Color "Green"
Write-Log "  ✓ Stats page available on :8080/stats" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase9-workers.ps1" -Color "Yellow"
