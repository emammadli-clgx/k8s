# Phase 7: RBAC Authorization
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

if (!(Test-Path "phase6_completed.txt")) {
    Write-Log "Phase 6 must be completed first. Run .\phase6-control-plane.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 7: RBAC Authorization ===" -Color "Cyan"
Write-Log "Configuring Role-Based Access Control" -Color "Yellow"

# Step 1: Configure kubelet RBAC
Write-Log "" -Color "White"
Write-Log "Step 1: Configuring kubelet RBAC..." -Color "Yellow"

$rbacScript = @'
echo "Creating kubelet RBAC ClusterRole..."

# Create ClusterRole for kubelet API access
kubectl apply --kubeconfig /home/vagrant/admin.kubeconfig -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF

echo "Binding ClusterRole to kubernetes user..."

# Bind the ClusterRole to the kubernetes user
kubectl apply --kubeconfig /home/vagrant/admin.kubeconfig -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
EOF

echo "RBAC configuration completed successfully"
'@

# Run on master-1 only (any master will work)
Write-Log "Applying RBAC configuration..." -Color "Gray"
if (!(Run-OnVM -VM "master-1" -Command $rbacScript -Description "Configuring RBAC")) {
    Write-Log "RBAC configuration failed" -Color "Red"
    exit 1
}

# Step 2: Verify RBAC configuration
Write-Log "" -Color "White"
Write-Log "Step 2: Verifying RBAC configuration..." -Color "Yellow"

$verifyRbacScript = @'
echo "=== RBAC Verification ==="
echo ""

echo "ClusterRoles:"
kubectl get clusterroles --kubeconfig /home/vagrant/admin.kubeconfig | grep system:kube-apiserver-to-kubelet
echo ""

echo "ClusterRoleBindings:"
kubectl get clusterrolebindings --kubeconfig /home/vagrant/admin.kubeconfig | grep system:kube-apiserver
echo ""

echo "Detailed RBAC info:"
kubectl describe clusterrole system:kube-apiserver-to-kubelet --kubeconfig /home/vagrant/admin.kubeconfig
echo ""

kubectl describe clusterrolebinding system:kube-apiserver --kubeconfig /home/vagrant/admin.kubeconfig
echo ""
'@

Write-Log "--- RBAC Verification ---" -Color "Yellow"
vagrant ssh master-1 -c $verifyRbacScript

# Create completion marker
"Phase 7 completed: $(Get-Date)" | Out-File -FilePath "phase7_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 7 (RBAC) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "RBAC setup:" -Color "Cyan"
Write-Log "  ✓ kubelet API access ClusterRole created" -Color "Green"
Write-Log "  ✓ ClusterRoleBinding to kubernetes user created" -Color "Green"
Write-Log "  ✓ API server to kubelet communication authorized" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Next step: .\phase8-load-balancer.ps1" -Color "Yellow"
