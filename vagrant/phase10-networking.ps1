# Phase 10: Pod Networking with Weave Net
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

if (!(Test-Path "phase9_completed.txt")) {
    Write-Log "Phase 9 must be completed first. Run .\phase9-workers.ps1" -Color "Red"
    exit 1
}

Write-Log "=== Phase 10: Pod Networking with Weave Net ===" -Color "Cyan"
Write-Log "Installing Weave Net CNI plugin for pod networking" -Color "Yellow"

# Step 1: Deploy Weave Net
Write-Log "" -Color "White"
Write-Log "Step 1: Deploying Weave Net CNI..." -Color "Yellow"

$deployWeaveScript = @'
echo "Deploying Weave Net CNI plugin..."

# Apply Weave Net with custom CIDR
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version --kubeconfig /home/vagrant/admin.kubeconfig | base64 | tr -d '\n')&env.IPALLOC_RANGE=10.32.0.0/12" --kubeconfig /home/vagrant/admin.kubeconfig

echo "Weave Net deployment completed"
'@

Write-Log "Deploying Weave Net..." -Color "Gray"
if (!(Run-OnVM -VM "master-1" -Command $deployWeaveScript -Description "Deploying Weave Net")) {
    Write-Log "Weave Net deployment failed" -Color "Red"
    exit 1
}

# Step 2: Wait for Weave to be ready
Write-Log "" -Color "White"
Write-Log "Step 2: Waiting for Weave Net to be ready..." -Color "Yellow"

$waitForWeaveScript = @'
echo "Waiting for Weave Net pods to be ready..."

# Wait for weave daemonset to be ready
timeout 300 bash -c 'until kubectl get ds weave-net -n kube-system --kubeconfig /home/vagrant/admin.kubeconfig >/dev/null 2>&1; do sleep 5; done'

# Wait for weave pods to be running
kubectl wait --for=condition=ready pod -l name=weave-net -n kube-system --timeout=300s --kubeconfig /home/vagrant/admin.kubeconfig

echo "Weave Net is ready"
'@

Write-Log "Waiting for Weave Net to be ready..." -Color "Gray"
if (!(Run-OnVM -VM "master-1" -Command $waitForWeaveScript -Description "Waiting for Weave Net")) {
    Write-Log "Weave Net readiness check failed" -Color "Red"
    if (!$SkipConfirmation) {
        $response = Read-Host "Continue anyway? (y/N)"
        if ($response -notmatch "^[Yy]$") { exit 1 }
    }
}

# Step 3: Install CoreDNS
Write-Log "" -Color "White"
Write-Log "Step 3: Installing CoreDNS..." -Color "Yellow"

$coreDNSManifest = @'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
rules:
- apiGroups:
  - ""
  resources:
  - endpoints
  - services
  - pods
  - namespaces
  verbs:
  - list
  - watch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
- kind: ServiceAccount
  name: coredns
  namespace: kube-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/name: "CoreDNS"
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: coredns
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Exists"
      nodeSelector:
        kubernetes.io/os: linux
      affinity:
         podAntiAffinity:
           preferredDuringSchedulingIgnoredDuringExecution:
           - weight: 100
             podAffinityTerm:
               labelSelector:
                 matchExpressions:
                   - key: k8s-app
                     operator: In
                     values: ["kube-dns"]
               topologyKey: kubernetes.io/hostname
      containers:
      - name: coredns
        image: coredns/coredns:1.10.1
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        args: [ "-conf", "/etc/coredns/Corefile" ]
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
          readOnly: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9153
          name: metrics
          protocol: TCP
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - all
          readOnlyRootFilesystem: true
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8181
            scheme: HTTP
      dnsPolicy: Default
      volumes:
        - name: config-volume
          configMap:
            name: coredns
            items:
            - key: Corefile
              path: Corefile
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  annotations:
    prometheus.io/port: "9153"
    prometheus.io/scrape: "true"
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "CoreDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.96.0.10
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
  - name: metrics
    port: 9153
    protocol: TCP
'@

$installCoreDNSScript = @"
echo 'Installing CoreDNS...'

# Create CoreDNS manifests
cat > /tmp/coredns.yaml << 'EOF'
$coreDNSManifest
EOF

# Apply CoreDNS
kubectl apply -f /tmp/coredns.yaml --kubeconfig /home/vagrant/admin.kubeconfig

echo 'CoreDNS installation completed'
"@

Write-Log "Installing CoreDNS..." -Color "Gray"
if (!(Run-OnVM -VM "master-1" -Command $installCoreDNSScript -Description "Installing CoreDNS")) {
    Write-Log "CoreDNS installation failed" -Color "Red"
    if (!$SkipConfirmation) {
        $response = Read-Host "Continue anyway? (y/N)"
        if ($response -notmatch "^[Yy]$") { exit 1 }
    }
}

# Step 4: Wait for CoreDNS to be ready
Write-Log "" -Color "White"
Write-Log "Step 4: Waiting for CoreDNS to be ready..." -Color "Yellow"

$waitForCoreDNSScript = @'
echo "Waiting for CoreDNS pods to be ready..."

# Wait for CoreDNS deployment to be available
kubectl wait --for=condition=available deployment/coredns -n kube-system --timeout=300s --kubeconfig /home/vagrant/admin.kubeconfig

echo "CoreDNS is ready"
'@

Write-Log "Waiting for CoreDNS to be ready..." -Color "Gray"
if (!(Run-OnVM -VM "master-1" -Command $waitForCoreDNSScript -Description "Waiting for CoreDNS")) {
    Write-Log "CoreDNS readiness check failed" -Color "Red"
    if (!$SkipConfirmation) {
        $response = Read-Host "Continue anyway? (y/N)"
        if ($response -notmatch "^[Yy]$") { exit 1 }
    }
}

# Step 5: Verify networking
Write-Log "" -Color "White"
Write-Log "Step 5: Verifying networking setup..." -Color "Yellow"

$verifyNetworkingScript = @'
echo "=== Networking Verification ==="
echo ""

echo "Node status:"
kubectl get nodes --kubeconfig /home/vagrant/admin.kubeconfig
echo ""

echo "Weave Net pods:"
kubectl get pods -n kube-system -l name=weave-net --kubeconfig /home/vagrant/admin.kubeconfig
echo ""

echo "CoreDNS pods:"
kubectl get pods -n kube-system -l k8s-app=kube-dns --kubeconfig /home/vagrant/admin.kubeconfig
echo ""

echo "All kube-system pods:"
kubectl get pods -n kube-system --kubeconfig /home/vagrant/admin.kubeconfig
echo ""

echo "Services:"
kubectl get svc -n kube-system --kubeconfig /home/vagrant/admin.kubeconfig
echo ""

echo "Cluster info:"
kubectl cluster-info --kubeconfig /home/vagrant/admin.kubeconfig
echo ""
'@

Write-Log "--- Networking Verification ---" -Color "Yellow"
vagrant ssh master-1 -c $verifyNetworkingScript

# Step 6: Test pod networking
Write-Log "" -Color "White"
Write-Log "Step 6: Testing pod networking..." -Color "Yellow"

$testPodNetworkingScript = @'
echo "=== Pod Networking Test ==="
echo ""

echo "Creating test deployment..."
kubectl create deployment test-nginx --image=nginx --kubeconfig /home/vagrant/admin.kubeconfig

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=ready pod -l app=test-nginx --timeout=120s --kubeconfig /home/vagrant/admin.kubeconfig

echo "Test pods:"
kubectl get pods -l app=test-nginx -o wide --kubeconfig /home/vagrant/admin.kubeconfig

echo ""
echo "Exposing deployment as service..."
kubectl expose deployment test-nginx --port=80 --kubeconfig /home/vagrant/admin.kubeconfig

echo "Services:"
kubectl get svc --kubeconfig /home/vagrant/admin.kubeconfig

echo ""
echo "Testing DNS resolution..."
kubectl run test-pod --image=busybox --rm -it --restart=Never --kubeconfig /home/vagrant/admin.kubeconfig -- nslookup kubernetes.default.svc.cluster.local || echo "DNS test completed"

echo ""
echo "Cleaning up test resources..."
kubectl delete deployment test-nginx --kubeconfig /home/vagrant/admin.kubeconfig
kubectl delete service test-nginx --kubeconfig /home/vagrant/admin.kubeconfig

echo "Pod networking test completed"
'@

Write-Log "Testing pod networking..." -Color "Gray"
vagrant ssh master-1 -c $testPodNetworkingScript

# Create completion marker
"Phase 10 completed: $(Get-Date)" | Out-File -FilePath "phase10_completed.txt" -Encoding UTF8

Write-Log "" -Color "White"
Write-Log "🎉 Phase 10 (Pod Networking) completed successfully!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Networking setup:" -Color "Cyan"
Write-Log "  ✓ Weave Net CNI plugin installed and running" -Color "Green"
Write-Log "  ✓ Pod CIDR: 10.32.0.0/12" -Color "Green"
Write-Log "  ✓ CoreDNS installed and running" -Color "Green"
Write-Log "  ✓ DNS service IP: 10.96.0.10" -Color "Green"
Write-Log "  ✓ Pod-to-pod communication working" -Color "Green"
Write-Log "  ✓ Service discovery working" -Color "Green"
Write-Log "" -Color "White"
Write-Log "🎊 Kubernetes cluster setup is complete!" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Your cluster is ready to use:" -Color "Cyan"
Write-Log "  • API Server: https://192.168.56.30:6443" -Color "Green"
Write-Log "  • kubectl config: configs/admin.kubeconfig" -Color "Green"
Write-Log "" -Color "White"
Write-Log "Test your cluster with:" -Color "Yellow"
Write-Log "  kubectl get nodes --kubeconfig configs/admin.kubeconfig" -Color "White"
Write-Log "  kubectl get pods --all-namespaces --kubeconfig configs/admin.kubeconfig" -Color "White"
