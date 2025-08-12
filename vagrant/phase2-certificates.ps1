# Phase 2: Certificate Generation
# Run from: vagrant\ directory in PowerShell

param([switch]$SkipConfirmation)

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Run-LocalCommand {
    param([string]$Command, [string]$Description = "")
    
    $desc = if ($Description) { $Description } else { "Running command" }
    Write-Log "$desc..." -Color "Gray"
    
    try {
        Invoke-Expression $Command
        if ($LASTEXITCODE -eq 0) {
            Write-Log "✓ Success" -Color "Green"
            return $true
        } else {
            Write-Log "✗ Failed" -Color "Red"
            return $false
        }
    } catch {
        Write-Log "✗ Error: $_" -Color "Red"
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

if (!(Test-Path "phase1_completed.txt")) {
    Write-Log "Phase 1 must be completed first. Run .\phase1-prerequisites.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 2: Certificate Generation ===" -Color "Cyan"
Write-Log "Generating SSL certificates for Kubernetes cluster" -Color "Yellow"

# Ensure directories exist
$dirs = @("certs", "configs")
foreach ($dir in $dirs) {
    if (!(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Created directory: $dir" -Color "Green"
    }
}

# Step 1: Download cfssl tools
Write-Log "" -Color "White"
Write-Log "Step 1: Downloading cfssl tools..." -Color "Yellow"
Set-Location "certs"

if (!(Test-Path "cfssl.exe")) {
    Write-Log "Downloading cfssl..." -Color "Gray"
    Invoke-WebRequest -Uri "https://github.com/cloudflare/cfssl/releases/download/v1.6.4/cfssl_1.6.4_windows_amd64.exe" -OutFile "cfssl.exe"
}

if (!(Test-Path "cfssljson.exe")) {
    Write-Log "Downloading cfssljson..." -Color "Gray"
    Invoke-WebRequest -Uri "https://github.com/cloudflare/cfssl/releases/download/v1.6.4/cfssljson_1.6.4_windows_amd64.exe" -OutFile "cfssljson.exe"
}

Write-Log "✓ cfssl tools ready" -Color "Green"

# Step 2: Generate CA certificate
Write-Log "" -Color "White"
Write-Log "Step 2: Generating Certificate Authority..." -Color "Yellow"

# CA config
$caConfig = @'
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
'@

$caConfig | Out-File -FilePath "ca-config.json" -Encoding UTF8

# CA CSR
$caCsr = @'
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
'@

$caCsr | Out-File -FilePath "ca-csr.json" -Encoding UTF8

# Generate CA certificate
Write-Log "Generating CA certificate..." -Color "Gray"
$result = .\cfssl.exe gencert -initca ca-csr.json | .\cfssljson.exe -bare ca
if ($LASTEXITCODE -ne 0) {
    Write-Log "CA certificate generation failed" -Color "Red"
    exit 1
}
Write-Log "✓ CA certificate generated" -Color "Green"

# Step 3: Generate admin client certificate
Write-Log "" -Color "White"
Write-Log "Step 3: Generating admin client certificate..." -Color "Yellow"

$adminCsr = @'
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
'@

$adminCsr | Out-File -FilePath "admin-csr.json" -Encoding UTF8

$result = .\cfssl.exe gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes admin-csr.json | .\cfssljson.exe -bare admin
Write-Log "✓ Admin certificate generated" -Color "Green"

# Step 4: Generate worker certificates
Write-Log "" -Color "White"
Write-Log "Step 4: Generating worker certificates..." -Color "Yellow"

$workers = @("worker-1", "worker-2")
foreach ($worker in $workers) {
    Write-Log "Generating certificate for $worker..." -Color "Gray"
    
    $workerCsr = @"
{
  "CN": "system:node:$worker",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
"@

    $workerCsr | Out-File -FilePath "$worker-csr.json" -Encoding UTF8
    
    $result = .\cfssl.exe gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -hostname="$worker,192.168.56.21,192.168.56.22" -profile=kubernetes "$worker-csr.json" | .\cfssljson.exe -bare $worker
    Write-Log "✓ $worker certificate generated" -Color "Green"
}

# Step 5: Generate controller manager certificate
Write-Log "" -Color "White"
Write-Log "Step 5: Generating controller manager certificate..." -Color "Yellow"

$controllerManagerCsr = @'
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
'@

$controllerManagerCsr | Out-File -FilePath "kube-controller-manager-csr.json" -Encoding UTF8

$result = .\cfssl.exe gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-controller-manager-csr.json | .\cfssljson.exe -bare kube-controller-manager
Write-Log "✓ Controller manager certificate generated" -Color "Green"

# Step 6: Generate kube-proxy certificate
Write-Log "" -Color "White"
Write-Log "Step 6: Generating kube-proxy certificate..." -Color "Yellow"

$kubeProxyCsr = @'
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
'@

$kubeProxyCsr | Out-File -FilePath "kube-proxy-csr.json" -Encoding UTF8

$result = .\cfssl.exe gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-proxy-csr.json | .\cfssljson.exe -bare kube-proxy
Write-Log "✓ Kube-proxy certificate generated" -Color "Green"

# Step 7: Generate scheduler certificate
Write-Log "" -Color "White"
Write-Log "Step 7: Generating scheduler certificate..." -Color "Yellow"

$schedulerCsr = @'
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
'@

$schedulerCsr | Out-File -FilePath "kube-scheduler-csr.json" -Encoding UTF8

$result = .\cfssl.exe gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-scheduler-csr.json | .\cfssljson.exe -bare kube-scheduler
Write-Log "✓ Scheduler certificate generated" -Color "Green"

# Step 8: Generate API server certificate
Write-Log "" -Color "White"
Write-Log "Step 8: Generating API server certificate..." -Color "Yellow"

$apiServerCsr = @'
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
'@

$apiServerCsr | Out-File -FilePath "kubernetes-csr.json" -Encoding UTF8

$hostnames = "10.32.0.1,10.96.0.1,192.168.56.11,192.168.56.12,192.168.56.30,127.0.0.1,localhost,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local"

$result = .\cfssl.exe gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -hostname="$hostnames" -profile=kubernetes kubernetes-csr.json | .\cfssljson.exe -bare kubernetes
Write-Log "✓ API server certificate generated" -Color "Green"

# Step 9: Generate service account key pair
Write-Log "" -Color "White"
Write-Log "Step 9: Generating service account key pair..." -Color "Yellow"

$serviceAccountCsr = @'
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
'@

$serviceAccountCsr | Out-File -FilePath "service-account-csr.json" -Encoding UTF8

$result = .\cfssl.exe gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes service-account-csr.json | .\cfssljson.exe -bare service-account
Write-Log "✓ Service account key pair generated" -Color "Green"

# Step 10: Distribute certificates
Write-Log "" -Color "White"
Write-Log "Step 10: Distributing certificates to VMs..." -Color "Yellow"

# Worker certificates
foreach ($worker in $workers) {
    Write-Log "Distributing certificates to $worker..." -Color "Gray"
    
    Copy-ToVM -VM $worker -LocalPath "ca.pem" -RemotePath "/home/vagrant/ca.pem"
    Copy-ToVM -VM $worker -LocalPath "$worker-key.pem" -RemotePath "/home/vagrant/$worker-key.pem"
    Copy-ToVM -VM $worker -LocalPath "$worker.pem" -RemotePath "/home/vagrant/$worker.pem"
    
    Write-Log "✓ $worker certificates distributed" -Color "Green"
}

# Master certificates
$masters = @("master-1", "master-2")
foreach ($master in $masters) {
    Write-Log "Distributing certificates to $master..." -Color "Gray"
    
    Copy-ToVM -VM $master -LocalPath "ca.pem" -RemotePath "/home/vagrant/ca.pem"
    Copy-ToVM -VM $master -LocalPath "ca-key.pem" -RemotePath "/home/vagrant/ca-key.pem"
    Copy-ToVM -VM $master -LocalPath "kubernetes-key.pem" -RemotePath "/home/vagrant/kubernetes-key.pem"
    Copy-ToVM -VM $master -LocalPath "kubernetes.pem" -RemotePath "/home/vagrant/kubernetes.pem"
    Copy-ToVM -VM $master -LocalPath "service-account-key.pem" -RemotePath "/home/vagrant/service-account-key.pem"
    Copy-ToVM -VM $master -LocalPath "service-account.pem" -RemotePath "/home/vagrant/service-account.pem"
    
    Write-Log "✓ $master certificates distributed" -Color "Green"
}

Set-Location ".."

# Create completion marker
"Phase 2 completed: $(Get-Date)" | Out-File -FilePath "phase2_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 2 (Certificates) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Generated certificates:" -Color "Cyan"
Write-Log "  ✓ Certificate Authority (CA)" -Color "Green"
Write-Log "  ✓ Admin client certificate" -Color "Green"
Write-Log "  ✓ Worker node certificates" -Color "Green"
Write-Log "  ✓ Controller manager certificate" -Color "Green"
Write-Log "  ✓ Kube-proxy certificate" -Color "Green"
Write-Log "  ✓ Scheduler certificate" -Color "Green"
Write-Log "  ✓ API server certificate" -Color "Green"
Write-Log "  ✓ Service account key pair" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase3-kubeconfig.ps1" -Color "Yellow"
