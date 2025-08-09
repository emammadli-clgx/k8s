# Data Encryption Configuration (Modernized 2025)

## Why Update?
- Use AES-GCM (if supported) prioritized over AES-CBC for performance (K8s supports aescbc, secretbox, aesgcm depending on version; aesgcm still alpha historically—stick to aescbc for stability but order providers clearly)
- Clear rotation strategy notes
- File path moved to `/var/lib/kubernetes/` during control-plane setup

## Generate Key
```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
```

## Create Config
```bash
cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: apiserver.config.k8s.io/v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
```
Reason: Keep `identity` last so already-encrypted data is read; new writes encrypted.

## Copy to Masters
```bash
for m in master-1 master-2; do
  scp encryption-config.yaml $m:~/
 done
```

## Deploy During API Server Setup
In the kube-apiserver systemd unit ensure flag:
```
--encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml
```

## (Optional) Rotate Procedure Summary
1. Add new key as key2 (top of list) leaving key1.
2. Restart apiservers sequentially.
3. Run `kubectl get secrets --all-namespaces -o json | kubectl replace -f -` to re-encrypt with newest key.
4. Remove older key after validation.

## Next
Bootstrap etcd: `07-bootstrapping-etcd-modern.md`.
