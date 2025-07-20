#!/bin/bash
# Script: generate-kubeconfigs.sh
# Purpose: Generate Kubernetes configuration files for all components
# Run from: master-1

set -e

echo "=== Generating Kubernetes Configuration Files ==="

# Set load balancer address
LOADBALANCER_ADDRESS=192.168.5.30

# Change to certificates directory
cd ~/certificates

# Generate kube-proxy kubeconfig
echo "Generating kube-proxy kubeconfig..."
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://${LOADBALANCER_ADDRESS}:6443 \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-credentials system:kube-proxy \
    --client-certificate=kube-proxy.crt \
    --client-key=kube-proxy.key \
    --embed-certs=true \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
}

# Generate kube-controller-manager kubeconfig
echo "Generating kube-controller-manager kubeconfig..."
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=kube-controller-manager.crt \
    --client-key=kube-controller-manager.key \
    --embed-certs=true \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
}

# Generate kube-scheduler kubeconfig
echo "Generating kube-scheduler kubeconfig..."
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-credentials system:kube-scheduler \
    --client-certificate=kube-scheduler.crt \
    --client-key=kube-scheduler.key \
    --embed-certs=true \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
}

# Generate admin kubeconfig
echo "Generating admin kubeconfig..."
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=admin.kubeconfig

  kubectl config set-credentials admin \
    --client-certificate=admin.crt \
    --client-key=admin.key \
    --embed-certs=true \
    --kubeconfig=admin.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig=admin.kubeconfig

  kubectl config use-context default --kubeconfig=admin.kubeconfig
}

# Copy kubeconfigs to home directory on master-1
echo "Copying kubeconfigs to home directory on master-1..."
cp admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig ~/

# Distribute to worker nodes
echo "Distributing kube-proxy kubeconfig to worker nodes..."
for instance in worker-1 worker-2; do
  echo "  Copying to ${instance}..."
  scp kube-proxy.kubeconfig vagrant@${instance}:~/
done

# Distribute to master-2 (we're already on master-1)
echo "Distributing kubeconfigs to master-2..."
scp admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig vagrant@master-2:~/

echo "=== Kubeconfig generation completed ==="