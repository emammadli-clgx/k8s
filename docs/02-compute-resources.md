# Provisioning Compute Resources

Note: You must have VirtualBox and Vagrant configured at this point

Once you have cloned this repository, `cd` into the `vagrant` directory.

Run `vagrant up` to provision the virtual machines.

`vagrant up`

This command will:

- Deploy 5 VMs: 2 master nodes, 2 worker nodes, and 1 load balancer, each named `kubernetes-ha-*`.
    > These are the default settings. You can change them at the top of the `Vagrantfile`.

- Set IP addresses in the `192.168.5.0/24` range.

    | VM           | VM Name                | Purpose      | IP           | Forwarded Port |
    |--------------|------------------------|--------------|--------------|----------------|
    | master-1     | kubernetes-ha-master-1 | Master       | 192.168.5.11 | 2711           |
    | master-2     | kubernetes-ha-master-2 | Master       | 192.168.5.12 | 2712           |
    | worker-1     | kubernetes-ha-worker-1 | Worker       | 192.168.5.21 | 2721           |
    | worker-2     | kubernetes-ha-worker-2 | Worker       | 192.168.5.22 | 2722           |
    | loadbalancer | kubernetes-ha-lb       | LoadBalancer | 192.168.5.30 | 2730           |

    > These are the default settings and can be changed in the `Vagrantfile`.

- Add a DNS entry (`8.8.8.8`) to each node for internet access.

- Install the latest stable version of Docker on the worker nodes.

- Enable network forwarding in IPtables on all nodes, which is required for Kubernetes networking.
    > `sysctl net.bridge.bridge-nf-call-iptables=1`

## SSH to the nodes

There are two ways to SSH into the nodes:

### 1. SSH using Vagrant

From the `vagrant` directory, run `vagrant ssh <vm>` (e.g., `vagrant ssh master-1`).
> **Note:** Use the VM name from the table above.

### 2. SSH Using SSH Client Tools

You can use any SSH client (like PuTTY).

Use the IP addresses from the table. Password-based authentication is disabled. Vagrant generates a private key for each VM, located at the following path within the `vagrant` directory:

**Private Key Path:** `.vagrant/machines/<machine_name>/virtualbox/private_key`

**Username:** `vagrant`

## Verify Environment

- Ensure all VMs are running.
- Ensure each VM has the correct IP address.
- Ensure you can SSH into each VM.
- Ensure all VMs can ping each other.
- Ensure the worker nodes have Docker installed. You can verify this by running `sudo docker version`.

## Troubleshooting Tips

If a VM fails to provision or is not configured correctly, destroy it:

`vagrant destroy <vm>`

Then, run `vagrant up` again to reprovision only the missing VMs.

Sometimes, `vagrant destroy` may fail to delete the VM's folder, causing an error like this:

    VBoxManage.exe: error: Could not rename the directory '.../ubuntu-jammy-22.04-cloudimg' to '.../kubernetes-ha-worker-2' (VERR_ALREADY_EXISTS)

In this case, after destroying the VM, manually delete the VM's directory from your VirtualBox VMs folder and then run `vagrant up`.

`vagrant destroy <vm>`
`# Manually delete the VM folder`
`vagrant up`
