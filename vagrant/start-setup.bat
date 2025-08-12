@echo off
echo === Kubernetes The Hard Way - Vagrant Setup ===
echo.
echo Current directory: %CD%
echo.
echo All VMs Status:
vagrant status
echo.
echo === Setup Instructions ===
echo.
echo You are now ready to run the Kubernetes setup phases.
echo Run each phase script in order using bash:
echo.
echo Phase 1: bash ..\phase1-prerequisites.sh
echo Phase 2: bash ..\phase2-certificates.sh
echo Phase 3: bash ..\phase3-kubeconfig.sh
echo Phase 4: bash ..\phase4-encryption.sh
echo Phase 5: bash ..\phase5-etcd.sh
echo Phase 6: bash ..\phase6-control-plane.sh
echo Phase 7: bash ..\phase7-workers.sh
echo Phase 8: bash ..\phase8-networking.sh
echo Phase 9: bash ..\phase9-dns.sh
echo Phase 10: bash ..\phase10-smoke-tests.sh
echo.
echo === Vagrant Commands ===
echo vagrant ssh master-1    - Connect to master-1
echo vagrant ssh master-2    - Connect to master-2
echo vagrant ssh worker-1    - Connect to worker-1
echo vagrant ssh worker-2    - Connect to worker-2
echo vagrant ssh loadbalancer - Connect to loadbalancer
echo.
echo Start with: bash ..\phase1-prerequisites.sh
echo.
