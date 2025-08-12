# Master Script: Complete Kubernetes Cluster Setup
# Run from: vagrant\ directory in PowerShell

param(
    [switch]$SkipConfirmation,
    [int]$StartFromPhase = 1,
    [int]$EndAtPhase = 10,
    [switch]$ContinueOnError
)

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Run-Phase {
    param([int]$PhaseNumber, [string]$PhaseDescription, [string]$ScriptName)
    
    Write-Log "" -Color "White"
    Write-Log "=============================================" -Color "Magenta"
    Write-Log "PHASE $PhaseNumber`: $PhaseDescription" -Color "Magenta"
    Write-Log "=============================================" -Color "Magenta"
    
    $startTime = Get-Date
    
    try {
        if ($SkipConfirmation) {
            & ".\$ScriptName" -SkipConfirmation
        } else {
            & ".\$ScriptName"
        }
        
        if ($LASTEXITCODE -eq 0) {
            $endTime = Get-Date
            $duration = $endTime - $startTime
            Write-Log "✅ Phase $PhaseNumber completed successfully in $($duration.TotalMinutes.ToString('F1')) minutes" -Color "Green"
            return $true
        } else {
            Write-Log "❌ Phase $PhaseNumber failed with exit code $LASTEXITCODE" -Color "Red"
            return $false
        }
    } catch {
        Write-Log "❌ Phase $PhaseNumber failed with error: $_" -Color "Red"
        return $false
    }
}

# Check prerequisites
if (!(Test-Path "Vagrantfile")) {
    Write-Log "❌ This script must be run from the vagrant directory" -Color "Red"
    exit 1
}

Write-Log "🚀 KUBERNETES THE HARD WAY - COMPLETE SETUP" -Color "Cyan"
Write-Log "=============================================" -Color "Cyan"
Write-Log "Modernized setup using containerd runtime" -Color "Yellow"
Write-Log "Kubernetes v1.28.4 | etcd v3.5.10 | containerd v1.7.8" -Color "Yellow"
Write-Log "" -Color "White"
Write-Log "Setup will run phases $StartFromPhase through $EndAtPhase" -Color "Cyan"

if (!$SkipConfirmation) {
    Write-Log "" -Color "White"
    Write-Host "⚠️  This will set up a complete Kubernetes cluster. Continue? (Y/n): " -ForegroundColor Yellow -NoNewline
    $response = Read-Host
    if ($response -match "^[Nn]$") {
        Write-Log "Setup cancelled by user" -Color "Yellow"
        exit 0
    }
}

$globalStartTime = Get-Date
$failedPhases = @()
$successfulPhases = @()

# Define all phases
$phases = @(
    @{Number=1; Description="Prerequisites Setup"; Script="phase1-prerequisites.ps1"},
    @{Number=2; Description="Certificate Generation"; Script="phase2-certificates.ps1"},
    @{Number=3; Description="Kubeconfig Generation"; Script="phase3-kubeconfig.ps1"},
    @{Number=4; Description="Data Encryption Keys"; Script="phase4-encryption.ps1"},
    @{Number=5; Description="etcd Cluster Bootstrap"; Script="phase5-etcd.ps1"},
    @{Number=6; Description="Kubernetes Control Plane"; Script="phase6-control-plane.ps1"},
    @{Number=7; Description="RBAC Authorization"; Script="phase7-rbac.ps1"},
    @{Number=8; Description="Load Balancer Setup"; Script="phase8-load-balancer.ps1"},
    @{Number=9; Description="Worker Nodes Bootstrap"; Script="phase9-workers.ps1"},
    @{Number=10; Description="Pod Networking (Weave Net + CoreDNS)"; Script="phase10-networking.ps1"}
)

# Execute phases
foreach ($phase in $phases) {
    if ($phase.Number -ge $StartFromPhase -and $phase.Number -le $EndAtPhase) {
        $success = Run-Phase -PhaseNumber $phase.Number -PhaseDescription $phase.Description -ScriptName $phase.Script
        
        if ($success) {
            $successfulPhases += $phase.Number
        } else {
            $failedPhases += $phase.Number
            
            if (!$ContinueOnError) {
                Write-Log "" -Color "White"
                Write-Log "❌ Phase $($phase.Number) failed. Stopping execution." -Color "Red"
                Write-Log "Use -ContinueOnError to continue despite failures" -Color "Yellow"
                break
            } else {
                Write-Log "⚠️  Continuing despite Phase $($phase.Number) failure..." -Color "Yellow"
            }
        }
    }
}

# Final summary
$globalEndTime = Get-Date
$totalDuration = $globalEndTime - $globalStartTime

Write-Log "" -Color "White"
Write-Log "=============================================" -Color "Cyan"
Write-Log "🏁 SETUP COMPLETE" -Color "Cyan"
Write-Log "=============================================" -Color "Cyan"
Write-Log "Total execution time: $($totalDuration.TotalMinutes.ToString('F1')) minutes" -Color "White"
Write-Log "" -Color "White"

if ($successfulPhases.Count -gt 0) {
    Write-Log "✅ Successful phases: $($successfulPhases -join ', ')" -Color "Green"
}

if ($failedPhases.Count -gt 0) {
    Write-Log "❌ Failed phases: $($failedPhases -join ', ')" -Color "Red"
    Write-Log "" -Color "White"
    Write-Log "To retry failed phases:" -Color "Yellow"
    foreach ($failedPhase in $failedPhases) {
        $phaseInfo = $phases | Where-Object { $_.Number -eq $failedPhase }
        Write-Log "  .\$($phaseInfo.Script)" -Color "White"
    }
} else {
    Write-Log "🎉 All phases completed successfully!" -Color "Green"
    Write-Log "" -Color "White"
    Write-Log "Your Kubernetes cluster is ready!" -Color "Green"
    Write-Log "" -Color "White"
    Write-Log "🔧 Cluster Details:" -Color "Cyan"
    Write-Log "  • API Server: https://192.168.56.30:6443" -Color "Green"
    Write-Log "  • kubectl config: configs/admin.kubeconfig" -Color "Green"
    Write-Log "  • HAProxy Stats: http://192.168.56.30:8080/stats" -Color "Green"
    Write-Log "" -Color "White"
    Write-Log "🧪 Test your cluster:" -Color "Yellow"
    Write-Log "  kubectl get nodes --kubeconfig configs/admin.kubeconfig" -Color "White"
    Write-Log "  kubectl get pods --all-namespaces --kubeconfig configs/admin.kubeconfig" -Color "White"
    Write-Log "  kubectl create deployment test --image=nginx --kubeconfig configs/admin.kubeconfig" -Color "White"
}

Write-Log "" -Color "White"
exit $(if ($failedPhases.Count -eq 0) { 0 } else { 1 })
