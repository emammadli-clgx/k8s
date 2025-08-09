# Provisioning Compute Resources (Modernized 2025)

This updates the legacy instructions while preserving file names and node roles. Differences are explained inline.

## Why Modernize?
- Updated to Ubuntu 22.04 (Jammy) guests as found in `vagrant/Vagrantfile`.
- Docker is still installed by provisioning scripts on workers, but Kubernetes >=1.24+ prefers containerd. A separate migration guide (`extra-containerd-migration.md`) is provided to replace Docker with containerd.
- Reinforced memory sizing: each control-plane VM set to 2048 MB, workers 512 MB (sufficient for exercises but may need 1024 MB if pulling larger images; you can edit Vagrantfile variables if desired).

## Clone Repository
(If you have this repository already, skip.)

```bash
git clone <your-fork-or-this-repo-url> kubernetes-the-hard-way-modern
cd kubernetes-the-hard-way-modern/vagrant
```

## Review / Adjust Node Counts (Optional)
Edit the top of `vagrant/Vagrantfile`:
```
NUM_MASTER_NODE = 2
NUM_WORKER_NODE = 2
```
Reduce `NUM_WORKER_NODE` to `1` if short on RAM.

## Bring Up the Environment
```
vagrant up
```

### What Happens
- Creates 5 VMs:
  - master-1 (192.168.5.11) / SSH port forward 2711
  - master-2 (192.168.5.12) / SSH port forward 2712
  - worker-1 (192.168.5.21) / SSH port forward 2721 (NOTE: legacy doc mismapped some ports; check `Vagrantfile` directly)
  - worker-2 (192.168.5.22) / SSH port forward 2722
  - loadbalancer (192.168.5.30) / SSH port forward 2730

(Verify exact forwarded ports in Vagrantfile because ordering changed from legacy table.)

### Network Settings
- Private network: `192.168.5.0/24`
- Each VM configured with interface `enp0s8` for the private network (argument passed into `setup-hosts.sh`).

### Provisioning Scripts Executed
On masters / workers / lb:
- `ubuntu/vagrant/setup-hosts.sh` (adds host file entries & nic binding) [legacy improvement: ensure consistent hostnames]
- `ubuntu/update-dns.sh` (sets DNS to 8.8.8.8 for external reachability)

On workers only:
- `ubuntu/install-docker.sh` (installs Docker CE + containerd.io; we will replace with dedicated containerd later)
- `ubuntu/allow-bridge-nf-traffic.sh` (loads `br_netfilter`, sets persistent sysctl for kube networking)

## Accessing VMs
1. Via Vagrant:
   `vagrant ssh master-1`
2. Via native SSH client (example):
   ```bash
   ssh -i .vagrant/machines/master-1/virtualbox/private_key vagrant@192.168.5.11
   ```

Username: `vagrant`

## Verification Checklist
Run these from host or inside nodes.

1. All VMs running:
   ```bash
   vagrant status
   ```
2. IP assignments (inside a node):
   ```bash
   ip -4 addr show enp0s8
   ```
3. Inter-node reachability (from master-1):
   ```bash
   ping -c2 master-2
   ping -c2 worker-1
   ```
4. Docker currently installed on workers (pre-migration):
   ```bash
   ssh worker-1 docker --version
   ```
5. Kernel netfilter settings (any node):
   ```bash
   sysctl net.bridge.bridge-nf-call-iptables
   sysctl net.bridge.bridge-nf-call-ip6tables
   ```

## Troubleshooting Enhancements
| Symptom | Modern Action |
|---------|---------------|
| VMs fail with VT-x error | Enable virtualization in BIOS; disable Hyper-V if using VirtualBox on Windows (or use Hyper-V provider). |
| SSH key mismatch | Remove offending key from `~/.ssh/known_hosts` then retry. |
| Low memory OOM kills | Increase worker memory to 1024 MB or reduce number of workers. |
| Network unreachable | Confirm host-only adapter created in VirtualBox; re-run `vagrant reload --provision`. |

## Next
Proceed to certificate authority generation / configuration steps (modernized docs to be added) or migrate container runtime first using `extra-containerd-migration.md` if planning to use containerd.
