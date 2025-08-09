# Prerequisites (Modernized 2025)

This guide modernizes the original prerequisites for running "Kubernetes the Hard Way" in this repository while keeping the same overall workflow. Explanations are included to justify changes versus the legacy document.

## Why Modernize?
- Original guide targeted Ubuntu 18.04 era tooling; we now use Ubuntu 22.04 (Jammy) in the Vagrantfile.
- Some components (Docker as the CRI, legacy iptables settings location, older kubectl install methods) have changed. Kubernetes 1.24+ removed the dockershim; containerd is now the recommended runtime.
- Added optional support for Windows 11 (Hyper-V) notes and Apple Silicon considerations.
- Security posture hardened: explicit verification of downloaded binaries, enabled automatic security updates, and supply‑chain integrity steps (sha256 / cosign optional).

## Host Machine Requirements
- CPU: 4 cores (8+ recommended for smoother parallel control-plane bring-up)
- RAM: Minimum 16 GB (absolute minimum 12 GB if you reduce VM counts). Original 8 GB often leads to swapping during etcd + control plane init.
- Disk: 80 GB free (original 50 GB was tight once images are pulled and logs accumulate).
- Virtualization Support: VT-x/AMD-V enabled in BIOS/UEFI.

## Software on Host
| Component | Required Version (or New Baseline) | Notes |
|-----------|------------------------------------|-------|
| VirtualBox | 7.0.x latest | Matches Ubuntu 22.04 guest additions better. |
| Vagrant | 2.4.x+ | Newer networking & plugin fixes. |
| PowerShell (Windows) | 7.x (pwsh) optional | Legacy 5.1 works; pwsh offers better UTF-8 and module ecosystem. |
| Git | Latest stable | For cloning repo and verifying signatures. |
| OpenSSL | Latest (macOS/Linux usually bundled) | For manual cert inspections. |

## Optional Tooling
- `kubectl` (You can also install later inside a management workstation VM.)
- `helm` for chart-based addon experimentation (not required for core steps).
- `cosign` for optional binary/image signature verification.

## Network Layout (Unchanged Fundamentals)
The existing Vagrantfile provisions:
- 2 control-plane nodes: master-1, master-2
- 2 worker nodes: worker-1, worker-2
- 1 HA load balancer: loadbalancer
- Private network: 192.168.5.0/24 (Static IPs assigned in Vagrantfile)

Keep host firewall rules open for the forwarded SSH ports (2711, 2712, 2720, 2721, 2730) if using external SSH clients.

## Performance Tips (New)
- Enable nested virtualization if running inside another hypervisor.
- On Windows hosts, disable real-time AV scanning of the project folder to reduce I/O latency.
- Consider lowering NUM_WORKER_NODE to 1 temporarily if RAM constrained.

## Security & Supply Chain Enhancements
1. Verify Vagrant box checksum:
   - Run `vagrant box list` after first download and record version.
   - Compare box checksum from HashiCorp releases when possible.
2. Keep host patched; enable unattended-upgrades on Linux host.
3. Use separate, non-admin user for daily virtualization tasks on Linux/macOS.

## Windows Specific Notes (Modern)
- Enable WSL2 for auxiliary tooling (e.g., `kubectl`, `jq`).
- Use PowerShell 7 or Windows Terminal for better UTF-8 output.

## Apple Silicon (ARM64) Considerations
Current Vagrantfile pins `ubuntu/jammy64` (AMD64). For ARM hosts you may need to switch to a provider supporting ARM (UTM/QEMU) or use an `arm64` box and adjust images (outside current scope). Keep this repo as-is for x86_64.

## Next Step
Proceed to modernized compute resources provisioning guide (`02-compute-resources-modern.md`).
