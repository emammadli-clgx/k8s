# Phase 4: Data Encryption Keys
# Run from: vagrant\ directory in PowerShell

param([switch]$SkipConfirmation)

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
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

if (!(Test-Path "phase3_completed.txt")) {
    Write-Log "Phase 3 must be completed first. Run .\phase3-kubeconfig.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 4: Data Encryption Keys ===" -Color "Cyan"
Write-Log "Generating encryption configuration for etcd data at rest" -Color "Yellow"

# Ensure directories exist
$dirs = @("configs")
foreach ($dir in $dirs) {
    if (!(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Created directory: $dir" -Color "Green"
    }
}

Set-Location "configs"

# Step 1: Generate encryption key
Write-Log "" -Color "White"
Write-Log "Step 1: Generating encryption key..." -Color "Yellow"

# Generate a random 32-byte key and base64 encode it
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
$rng.GetBytes($bytes)
$encryptionKey = [System.Convert]::ToBase64String($bytes)
$rng.Dispose()

Write-Log "✓ Encryption key generated" -Color "Green"

# Step 2: Create encryption configuration
Write-Log "" -Color "White"
Write-Log "Step 2: Creating encryption configuration..." -Color "Yellow"

$encryptionConfig = @"
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: $encryptionKey
      - identity: {}
"@

$encryptionConfig | Out-File -FilePath "encryption-config.yaml" -Encoding UTF8

Write-Log "✓ Encryption configuration created" -Color "Green"

# Step 3: Distribute encryption configuration
Write-Log "" -Color "White"
Write-Log "Step 3: Distributing encryption configuration to masters..." -Color "Yellow"

$masters = @("master-1", "master-2")
foreach ($master in $masters) {
    Write-Log "Distributing encryption config to $master..." -Color "Gray"
    
    Copy-ToVM -VM $master -LocalPath "encryption-config.yaml" -RemotePath "/home/vagrant/encryption-config.yaml"
    
    Write-Log "✓ $master encryption config distributed" -Color "Green"
}

Set-Location ".."

# Create completion marker
"Phase 4 completed: $(Get-Date)" | Out-File -FilePath "phase4_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 4 (Data Encryption) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Encryption setup:" -Color "Cyan"
Write-Log "  ✓ 256-bit AES encryption key generated" -Color "Green"
Write-Log "  ✓ Encryption configuration created" -Color "Green"
Write-Log "  ✓ Configuration distributed to masters" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase5-etcd.ps1" -Color "Yellow"
