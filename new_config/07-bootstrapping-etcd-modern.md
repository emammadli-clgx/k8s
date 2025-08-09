# Bootstrapping etcd (Modernized 2025)

## Why Update?
- Use current stable etcd (3.5.x) instead of 3.3.9
- Explicit systemd hardening options
- Separate data dir & dedicated user
- Enable auto compaction & defrag timer

## Run On Each Control Plane: master-1 & master-2

Variables:
```bash
ETCD_VERSION=v3.5.13
MASTER_1=192.168.5.11
MASTER_2=192.168.5.12
THIS_IP=$(ip -4 addr show enp0s8 | awk '/inet /{print $2}' | cut -d/ -f1)
ETCD_NAME=$(hostname -s)
```

## Install Binaries
```bash
curl -L https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz -o /tmp/etcd.tgz
sudo tar -C /usr/local/bin -xzf /tmp/etcd.tgz --strip-components=1 etcd-${ETCD_VERSION}-linux-amd64/etcd{,ctl}
rm /tmp/etcd.tgz
etcd --version
```

## User & Directories
```bash
sudo useradd --system --home /var/lib/etcd --shell /sbin/nologin etcd || true
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo chown etcd:etcd /var/lib/etcd
sudo cp ~/etcd-server.crt ~/etcd-server.key ~/ca.crt /etc/etcd/
```

## Systemd Unit
```bash
cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd key-value store
Documentation=https://etcd.io/docs
After=network-online.target
Wants=network-online.target

[Service]
User=etcd
Type=notify
ExecStart=/usr/local/bin/etcd \
  --name ${ETCD_NAME} \
  --data-dir /var/lib/etcd \
  --initial-advertise-peer-urls https://${THIS_IP}:2380 \
  --listen-peer-urls https://${THIS_IP}:2380 \
  --listen-client-urls https://${THIS_IP}:2379,https://127.0.0.1:2379 \
  --advertise-client-urls https://${THIS_IP}:2379 \
  --initial-cluster master-1=https://${MASTER_1}:2380,master-2=https://${MASTER_2}:2380 \
  --initial-cluster-token etcd-kthw \
  --initial-cluster-state new \
  --cert-file=/etc/etcd/etcd-server.crt \
  --key-file=/etc/etcd/etcd-server.key \
  --client-cert-auth --trusted-ca-file=/etc/etcd/ca.crt \
  --peer-cert-file=/etc/etcd/etcd-server.crt \
  --peer-key-file=/etc/etcd/etcd-server.key \
  --peer-client-cert-auth --peer-trusted-ca-file=/etc/etcd/ca.crt \
  --logger=zap \
  --quota-backend-bytes=8589934592 \
  --auto-compaction-retention=1 \
  --max-txn-ops=1024 \
  --max-request-bytes=33554432
LimitNOFILE=100000
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/etcd /etc/etcd

[Install]
WantedBy=multi-user.target
EOF
```

## Start
```bash
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
```

## Verification
```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key member list
```

## Optional Periodic Defrag (cron)
```bash
echo '0 */6 * * * root ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/etcd/ca.crt --cert=/etc/etcd/etcd-server.crt --key=/etc/etcd/etcd-server.key defrag' | sudo tee /etc/cron.d/etcd-defrag
```

## Next
Control plane bootstrap: `08-bootstrapping-kubernetes-controllers-modern.md`.
