# Provisioning a CA and Generating TLS Certificates (Modernized 2025)

## Why Update?
- Move to 4096-bit RSA (or optional ECDSA) for CA longevity (original used 2048)
- Reduce manual duplication via small helper functions
- Include SANs for future expansion (API, etcd, service IP) and clarify rotation strategy
- Provide alternative using `cfssl` (optional) but stick to OpenSSL for transparency

## Where To Run
Perform on `master-1` (acting as CA) or a separate offline workstation, then securely copy only the required public certs and component key pairs. Keep `ca.key` restricted.

## Directory Layout
```bash
mkdir -p ~/pki/{ca,apiserver,etcd,sa,admin,controller,scheduler,proxy,workers}
cd ~/pki
chmod 700 ca
```

## 1. Certificate Authority (RSA 4096)
```bash
cd ~/pki/ca
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -subj "/CN=KUBERNETES-CA" -days 3650 -out ca.crt -sha256
chmod 600 ca.key
```
Why: 10-year CA validity for lab; in prod use shorter + rotation process.

(Alternative ECDSA):
```bash
# openssl ecparam -genkey -name prime256v1 -out ca.key
# openssl req -x509 -new -key ca.key -subj "/CN=KUBERNETES-CA" -days 1825 -out ca.crt -sha256
```

## Helper Variables
```bash
K8S_SERVICE_IP=10.96.0.1
LOAD_BALANCER_IP=192.168.5.30
MASTER_1=192.168.5.11
MASTER_2=192.168.5.12
ETCD_HOSTS="IP:${MASTER_1},IP:${MASTER_2},IP:127.0.0.1"
APISERVER_SANS="DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,IP:${K8S_SERVICE_IP},IP:${MASTER_1},IP:${MASTER_2},IP:${LOAD_BALANCER_IP},IP:127.0.0.1"
```

## 2. Admin Client Cert
```bash
cd ~/pki/admin
openssl genrsa -out admin.key 2048
openssl req -new -key admin.key -subj "/CN=admin/O=system:masters" -out admin.csr
openssl x509 -req -in admin.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out admin.crt -days 1000 -sha256
```

## 3. Controller Manager
```bash
cd ~/pki/controller
openssl genrsa -out kube-controller-manager.key 2048
openssl req -new -key kube-controller-manager.key -subj "/CN=system:kube-controller-manager" -out kube-controller-manager.csr
openssl x509 -req -in kube-controller-manager.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out kube-controller-manager.crt -days 1000 -sha256
```

## 4. Kube Proxy
```bash
cd ~/pki/proxy
openssl genrsa -out kube-proxy.key 2048
openssl req -new -key kube-proxy.key -subj "/CN=system:kube-proxy" -out kube-proxy.csr
openssl x509 -req -in kube-proxy.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out kube-proxy.crt -days 1000 -sha256
```

## 5. Scheduler
```bash
cd ~/pki/scheduler
openssl genrsa -out kube-scheduler.key 2048
openssl req -new -key kube-scheduler.key -subj "/CN=system:kube-scheduler" -out kube-scheduler.csr
openssl x509 -req -in kube-scheduler.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out kube-scheduler.crt -days 1000 -sha256
```

## 6. API Server
```bash
cd ~/pki/apiserver
openssl genrsa -out kube-apiserver.key 2048
cat > apiserver-openssl.cnf <<EOF
[ req ]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
[ v3_req ]
subjectAltName = ${APISERVER_SANS}
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
basicConstraints = CA:FALSE
EOF
openssl req -new -key kube-apiserver.key -subj "/CN=kube-apiserver" -out kube-apiserver.csr -config apiserver-openssl.cnf
openssl x509 -req -in kube-apiserver.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out kube-apiserver.crt -days 1000 -sha256 -extensions v3_req -extfile apiserver-openssl.cnf
```

## 7. etcd Server (shared cert for both members in small lab)
```bash
cd ~/pki/etcd
openssl genrsa -out etcd-server.key 2048
cat > etcd-openssl.cnf <<EOF
[ req ]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
[ v3_req ]
subjectAltName = IP:192.168.5.11,IP:192.168.5.12,IP:127.0.0.1
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
basicConstraints = CA:FALSE
EOF
openssl req -new -key etcd-server.key -subj "/CN=etcd-server" -out etcd-server.csr -config etcd-openssl.cnf
openssl x509 -req -in etcd-server.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out etcd-server.crt -days 1000 -sha256 -extensions v3_req -extfile etcd-openssl.cnf
```

## 8. Service Account Key Pair (RSA 2048 ok)
```bash
cd ~/pki/sa
openssl genrsa -out service-account.key 2048
openssl req -new -key service-account.key -subj "/CN=service-accounts" -out service-account.csr
openssl x509 -req -in service-account.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key -CAcreateserial -out service-account.crt -days 1000 -sha256
```

## 9. Distribute Artifacts
Copy to each master:
```bash
for m in master-1 master-2; do
  scp ../ca/ca.crt apiserver/kube-apiserver.{crt,key} \
      etcd/etcd-server.{crt,key} sa/service-account.{crt,key} \
      $m:~/
  scp controller/kube-controller-manager.{crt,key} scheduler/kube-scheduler.{crt,key} proxy/kube-proxy.{crt,key} admin/admin.{crt,key} $m:~/
 done
```

Keep `ca.key` local only (do not copy). Reason: protects CA signing key from compromise.

## Next
Generate kubeconfigs (`05-kubernetes-configuration-files-modern.md`).
