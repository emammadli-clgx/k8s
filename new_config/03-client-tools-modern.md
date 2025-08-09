# Installing Client & Admin Tools (Modernized 2025)

## Why Update?
Original instructions targeted kubectl 1.13 on Ubuntu 18.04. We now align with current stable (example: 1.30.x) and add optional tooling for debugging (crictl, nerdctl) plus secure download verification.

## Choose an Admin Workstation
You can still use `master-1` for all generation tasks, but a better pattern is to use your host (or a dedicated "admin" VM) and push artifacts via SSH. Benefit: reduces risk to control-plane if you regenerate assets.

Assumption: Performing steps on `master-1` (adjust if using another machine). Ensure it can SSH to all nodes passwordlessly.

## SSH Key Distribution (If Not Already Present)
On `master-1`:
```bash
ssh-keygen -t ed25519 -C "kthw-admin" -N '' -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub | tee -a ~/.ssh/authorized_keys
```
Copy the public key to each other VM (if not shared via base box). From host you can use `vagrant ssh-config` to extract paths, or inside `master-1`:
```bash
for h in master-2 worker-1 worker-2 loadbalancer; do
  ssh -o StrictHostKeyChecking=no $h 'echo "'"$(cat ~/.ssh/id_ed25519.pub)"'" >> ~/.ssh/authorized_keys';
done
```
Reason: Ed25519 keys are shorter & faster than RSA 2048; modern OpenSSH defaults.

## Install kubectl (Static Binary)
Set desired version:
```bash
KUBECTL_VER=v1.30.4   # example stable; check https://dl.k8s.io/release/stable.txt
OS=linux
ARCH=amd64
curl -L --remote-name https://dl.k8s.io/release/${KUBECTL_VER}/bin/${OS}/${ARCH}/kubectl
curl -L --remote-name https://dl.k8s.io/${KUBECTL_VER}/bin/${OS}/${ARCH}/kubectl.sha256
sha256sum -c kubectl.sha256
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```
Why: Use official HTTPS release; verify integrity with sha256.

Optional signature verification (cosign):
```bash
# cosign verify-blob --certificate-identity-regexp 'sigstore' ... (omitted for brevity)
```

## Install Supporting Tools
```bash
# jq for JSON, yq optional for YAML, bash-completion for UX
sudo apt-get update
sudo apt-get install -y jq bash-completion
```
Optional: kubectl completion
```bash
echo 'source <(kubectl completion bash)' >> ~/.bashrc
```

## Verify kubectl
```bash
kubectl version --client --output=yaml
```

## Next
Proceed to Certificate Authority modernization: `04-certificate-authority-modern.md`.
