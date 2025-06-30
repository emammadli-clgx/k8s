# Provisioning a CA and Generating TLS Certificates

In this lab, you will provision a [PKI](https://en.wikipedia.org/wiki/Public_key_infrastructure) using CloudFlare's PKI toolkit, `cfssl`. You will bootstrap a Certificate Authority (CA) and generate TLS certificates for all Kubernetes components.

These tasks should be performed on the `master-1` node.

## Install cfssl

Download and install `cfssl` and `cfssljson`:

```bash
wget -q --show-progress --https-only --timestamping 
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssl 
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssljson
chmod +x cfssl cfssljson
sudo mv cfssl cfssljson /usr/local/bin/
```

## Certificate Authority

Create the CA configuration file, certificate signing request (CSR), and generate the CA certificate and private key:

```bash
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca
```

This will produce `ca.pem` (the CA certificate) and `ca-key.pem` (the CA private key).

## Client and Server Certificates

Generate certificates for all Kubernetes components.

### Admin Client Certificate

```bash
cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert 
  -ca=ca.pem 
  -ca-key=ca-key.pem 
  -config=ca-config.json 
  -profile=kubernetes 
  admin-csr.json | cfssljson -bare admin
```

### Kubelet Client Certificates

Certificates for the worker nodes will be generated later during the worker node bootstrapping process.

### Controller Manager Client Certificate

```bash
cat > kube-controller-manager-csr.json <<EOF
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert 
  -ca=ca.pem 
  -ca-key=ca-key.pem 
  -config=ca-config.json 
  -profile=kubernetes 
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager
```

### Kube Proxy Client Certificate

```bash
cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert 
  -ca=ca.pem 
  -ca-key=ca-key.pem 
  -config=ca-config.json 
  -profile=kubernetes 
  kube-proxy-csr.json | cfssljson -bare kube-proxy
```

### Scheduler Client Certificate

```bash
cat > kube-scheduler-csr.json <<EOF
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert 
  -ca=ca.pem 
  -ca-key=ca-key.pem 
  -config=ca-config.json 
  -profile=kubernetes 
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler
```

### Kubernetes API Server Certificate

The API server certificate requires Subject Alternative Names (SANs) for all addresses that clients might use to reach it.

```bash
cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ],
  "hosts": [
    "master-1",
    "master-2",
    "loadbalancer",
    "192.168.5.11",
    "192.168.5.12",
    "192.168.5.30",
    "10.96.0.1",
    "127.0.0.1",
    "kubernetes.default"
  ]
}
EOF

cfssl gencert 
  -ca=ca.pem 
  -ca-key=ca-key.pem 
  -config=ca-config.json 
  -profile=kubernetes 
  kubernetes-csr.json | cfssljson -bare kubernetes
```

### ETCD Server Certificate

The etcd server certificate requires SANs for all etcd cluster members.

```bash
cat > etcd-server-csr.json <<EOF
{
  "CN": "etcd-server",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ],
  "hosts": [
    "master-1",
    "master-2",
    "192.168.5.11",
    "192.168.5.12",
    "127.0.0.1"
  ]
}
EOF

cfssl gencert 
  -ca=ca.pem 
  -ca-key=ca-key.pem 
  -config=ca-config.json 
  -profile=kubernetes 
  etcd-server-csr.json | cfssljson -bare etcd-server
```

### Service Account Key Pair

The Kubernetes Controller Manager uses a key pair to sign service account tokens.

```bash
openssl genrsa -out service-account-key.pem 2048
openssl rsa -in service-account-key.pem -pubout -out service-account.pem
```

## Distribute the Certificates

Copy the appropriate certificates and private keys to each master node:

```bash
for instance in master-1 master-2; do
  scp ca.pem ca-key.pem kubernetes.pem kubernetes-key.pem 
    service-account.pem service-account-key.pem 
    etcd-server.pem etcd-server-key.pem 
    vagrant@${instance}:~
 done
```

Next: [Generating Kubernetes Configuration Files for Authentication](05-kubernetes-configuration-files.md)
