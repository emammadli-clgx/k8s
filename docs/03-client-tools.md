'''# Installing the Client Tools

It is recommended to perform administrative tasks from a dedicated machine. In this guide, we will use `master-1` as our administrative node.

## Access all VMs

From the `master-1` node, generate an SSH key pair:

```bash
ssh-keygen -t rsa -b 2048
```

Leave the passphrase empty for ease of use.

Now, copy the public key to all other nodes. You can do this easily with `ssh-copy-id`.

First, install `ssh-copy-id` on `master-1`:

```bash
sudo apt-get update
sudo apt-get install -y ssh-copy-id
```

Then, for each of the other nodes (`master-2`, `worker-1`, `worker-2`, `loadbalancer`), run the following command from `master-1`, replacing `<node-ip>` with the IP address of the target node:

```bash
ssh-copy-id vagrant@<node-ip>
```

For example:

```bash
ssh-copy-id vagrant@192.168.5.12
ssh-copy-id vagrant@192.168.5.21
ssh-copy-id vagrant@192.168.5.22
ssh-copy-id vagrant@192.168.5.30
```

## Install kubectl

The [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl) command-line utility is used to interact with the Kubernetes API Server.

### Linux

Install `kubectl` on `master-1` using the latest stable release:

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

### Verification

Verify the installed `kubectl` version:

```bash
kubectl version --client
```

The output should show the latest stable version of `kubectl`.

Next: [Certificate Authority](04-certificate-authority.md)''
