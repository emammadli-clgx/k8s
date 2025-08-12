# Phase 3: Kubeconfig Generation
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

function Copy-ToVM {
    param([string]$VM, [string]$LocalPath, [string]$RemotePath)
    
    Write-Log "[$VM] Copying $LocalPath to $RemotePath..." -Color "Gray"
    
    try {
        # Copy file using vagrant's scp-like functionality
        $result = vagrant ssh $VM -c "sudo mkdir -p $(Split-Path $RemotePath -Parent)" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to create directory" }
        
        # Use temporary location first, then move with sudo
        $tempPath = "/tmp/$(Split-Path $LocalPath -Leaf)"
        
        # Read local file and create on remote
        $content = Get-Content $LocalPath -Raw
        $escapedContent = $content -replace "'", "'\''"
        $copyCmd = "echo '$escapedContent' > $tempPath && sudo mv $tempPath $RemotePath"
        
        $result = vagrant ssh $VM -c $copyCmd 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "[$VM] ✓ File copied successfully" -Color "Green"
            return $true
        } else {
            Write-Log "[$VM] ✗ Copy failed" -Color "Red"
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

if (!(Test-Path "phase2_completed.txt")) {
    Write-Log "Phase 2 must be completed first. Run .\phase2-certificates.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 3: Kubeconfig Generation ===" -Color "Cyan"
Write-Log "Generating Kubernetes configuration files" -Color "Yellow"

# Ensure directories exist
$dirs = @("certs", "configs")
foreach ($dir in $dirs) {
    if (!(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Created directory: $dir" -Color "Green"
    }
}

Set-Location "configs"

# Download kubectl if not present
if (!(Test-Path "kubectl.exe")) {
    Write-Log "Downloading kubectl..." -Color "Gray"
    Invoke-WebRequest -Uri "https://dl.k8s.io/release/v1.28.4/bin/windows/amd64/kubectl.exe" -OutFile "kubectl.exe"
    Write-Log "✓ kubectl downloaded" -Color "Green"
}

$kubectlPath = (Resolve-Path "kubectl.exe").Path
$clusterUrl = "https://192.168.56.30:6443"
$caPath = (Resolve-Path "..\certs\ca.pem").Path

# Step 1: Generate worker kubeconfigs
Write-Log "" -Color "White"
Write-Log "Step 1: Generating worker kubeconfigs..." -Color "Yellow"

$workers = @(
    @{name="worker-1"; ip="192.168.56.21"},
    @{name="worker-2"; ip="192.168.56.22"}
)

foreach ($worker in $workers) {
    $workerName = $worker.name
    $workerIP = $worker.ip
    
    Write-Log "Generating kubeconfig for $workerName..." -Color "Gray"
    
    $certPath = (Resolve-Path "..\certs\$workerName.pem").Path
    $keyPath = (Resolve-Path "..\certs\$workerName-key.pem").Path
    
    # Set cluster
    & $kubectlPath config set-cluster kubernetes-the-hard-way `
        --certificate-authority="$caPath" `
        --embed-certs=true `
        --server="$clusterUrl" `
        --kubeconfig="$workerName.kubeconfig"
    
    # Set credentials
    & $kubectlPath config set-credentials "system:node:$workerName" `
        --client-certificate="$certPath" `
        --client-key="$keyPath" `
        --embed-certs=true `
        --kubeconfig="$workerName.kubeconfig"
    
    # Set context
    & $kubectlPath config set-context default `
        --cluster=kubernetes-the-hard-way `
        --user="system:node:$workerName" `
        --kubeconfig="$workerName.kubeconfig"
    
    # Use context
    & $kubectlPath config use-context default --kubeconfig="$workerName.kubeconfig"
    
    Write-Log "✓ $workerName kubeconfig generated" -Color "Green"
}

# Step 2: Generate kube-proxy kubeconfig
Write-Log "" -Color "White"
Write-Log "Step 2: Generating kube-proxy kubeconfig..." -Color "Yellow"

$proxyKeyPath = (Resolve-Path "..\certs\kube-proxy-key.pem").Path
$proxyCertPath = (Resolve-Path "..\certs\kube-proxy.pem").Path

& $kubectlPath config set-cluster kubernetes-the-hard-way `
    --certificate-authority="$caPath" `
    --embed-certs=true `
    --server="$clusterUrl" `
    --kubeconfig="kube-proxy.kubeconfig"

& $kubectlPath config set-credentials system:kube-proxy `
    --client-certificate="$proxyCertPath" `
    --client-key="$proxyKeyPath" `
    --embed-certs=true `
    --kubeconfig="kube-proxy.kubeconfig"

& $kubectlPath config set-context default `
    --cluster=kubernetes-the-hard-way `
    --user=system:kube-proxy `
    --kubeconfig="kube-proxy.kubeconfig"

& $kubectlPath config use-context default --kubeconfig="kube-proxy.kubeconfig"

Write-Log "✓ kube-proxy kubeconfig generated" -Color "Green"

# Step 3: Generate kube-controller-manager kubeconfig
Write-Log "" -Color "White"
Write-Log "Step 3: Generating kube-controller-manager kubeconfig..." -Color "Yellow"

$controllerKeyPath = (Resolve-Path "..\certs\kube-controller-manager-key.pem").Path
$controllerCertPath = (Resolve-Path "..\certs\kube-controller-manager.pem").Path

& $kubectlPath config set-cluster kubernetes-the-hard-way `
    --certificate-authority="$caPath" `
    --embed-certs=true `
    --server="https://127.0.0.1:6443" `
    --kubeconfig="kube-controller-manager.kubeconfig"

& $kubectlPath config set-credentials system:kube-controller-manager `
    --client-certificate="$controllerCertPath" `
    --client-key="$controllerKeyPath" `
    --embed-certs=true `
    --kubeconfig="kube-controller-manager.kubeconfig"

& $kubectlPath config set-context default `
    --cluster=kubernetes-the-hard-way `
    --user=system:kube-controller-manager `
    --kubeconfig="kube-controller-manager.kubeconfig"

& $kubectlPath config use-context default --kubeconfig="kube-controller-manager.kubeconfig"

Write-Log "✓ kube-controller-manager kubeconfig generated" -Color "Green"

# Step 4: Generate kube-scheduler kubeconfig
Write-Log "" -Color "White"
Write-Log "Step 4: Generating kube-scheduler kubeconfig..." -Color "Yellow"

$schedulerKeyPath = (Resolve-Path "..\certs\kube-scheduler-key.pem").Path
$schedulerCertPath = (Resolve-Path "..\certs\kube-scheduler.pem").Path

& $kubectlPath config set-cluster kubernetes-the-hard-way `
    --certificate-authority="$caPath" `
    --embed-certs=true `
    --server="https://127.0.0.1:6443" `
    --kubeconfig="kube-scheduler.kubeconfig"

& $kubectlPath config set-credentials system:kube-scheduler `
    --client-certificate="$schedulerCertPath" `
    --client-key="$schedulerKeyPath" `
    --embed-certs=true `
    --kubeconfig="kube-scheduler.kubeconfig"

& $kubectlPath config set-context default `
    --cluster=kubernetes-the-hard-way `
    --user=system:kube-scheduler `
    --kubeconfig="kube-scheduler.kubeconfig"

& $kubectlPath config use-context default --kubeconfig="kube-scheduler.kubeconfig"

Write-Log "✓ kube-scheduler kubeconfig generated" -Color "Green"

# Step 5: Generate admin kubeconfig
Write-Log "" -Color "White"
Write-Log "Step 5: Generating admin kubeconfig..." -Color "Yellow"

$adminKeyPath = (Resolve-Path "..\certs\admin-key.pem").Path
$adminCertPath = (Resolve-Path "..\certs\admin.pem").Path

& $kubectlPath config set-cluster kubernetes-the-hard-way `
    --certificate-authority="$caPath" `
    --embed-certs=true `
    --server="$clusterUrl" `
    --kubeconfig="admin.kubeconfig"

& $kubectlPath config set-credentials admin `
    --client-certificate="$adminCertPath" `
    --client-key="$adminKeyPath" `
    --embed-certs=true `
    --kubeconfig="admin.kubeconfig"

& $kubectlPath config set-context default `
    --cluster=kubernetes-the-hard-way `
    --user=admin `
    --kubeconfig="admin.kubeconfig"

& $kubectlPath config use-context default --kubeconfig="admin.kubeconfig"

Write-Log "✓ admin kubeconfig generated" -Color "Green"

# Step 6: Distribute kubeconfigs
Write-Log "" -Color "White"
Write-Log "Step 6: Distributing kubeconfigs to VMs..." -Color "Yellow"

# Worker kubeconfigs
foreach ($worker in $workers) {
    $workerName = $worker.name
    Write-Log "Distributing kubeconfigs to $workerName..." -Color "Gray"
    
    Copy-ToVM -VM $workerName -LocalPath "$workerName.kubeconfig" -RemotePath "/home/vagrant/$workerName.kubeconfig"
    Copy-ToVM -VM $workerName -LocalPath "kube-proxy.kubeconfig" -RemotePath "/home/vagrant/kube-proxy.kubeconfig"
    
    Write-Log "✓ $workerName kubeconfigs distributed" -Color "Green"
}

# Master kubeconfigs
$masters = @("master-1", "master-2")
foreach ($master in $masters) {
    Write-Log "Distributing kubeconfigs to $master..." -Color "Gray"
    
    Copy-ToVM -VM $master -LocalPath "admin.kubeconfig" -RemotePath "/home/vagrant/admin.kubeconfig"
    Copy-ToVM -VM $master -LocalPath "kube-controller-manager.kubeconfig" -RemotePath "/home/vagrant/kube-controller-manager.kubeconfig"
    Copy-ToVM -VM $master -LocalPath "kube-scheduler.kubeconfig" -RemotePath "/home/vagrant/kube-scheduler.kubeconfig"
    
    Write-Log "✓ $master kubeconfigs distributed" -Color "Green"
}

Set-Location ".."

# Create completion marker
"Phase 3 completed: $(Get-Date)" | Out-File -FilePath "phase3_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 3 (Kubeconfig) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Generated kubeconfigs:" -Color "Cyan"
Write-Log "  ✓ Worker node kubeconfigs" -Color "Green"
Write-Log "  ✓ kube-proxy kubeconfig" -Color "Green"
Write-Log "  ✓ kube-controller-manager kubeconfig" -Color "Green"
Write-Log "  ✓ kube-scheduler kubeconfig" -Color "Green"
Write-Log "  ✓ admin kubeconfig" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase4-encryption.ps1" -Color "Yellow"
