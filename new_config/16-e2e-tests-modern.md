# End-to-End Conformance Tests (Modernized 2025)

## Why Update?
- Use Kubernetes upstream e2e.test binary instead of legacy kubetest where practical
- Go toolchain updated (1.22+)
- Conformance subset reduces runtime on small lab hardware

## Option A: Download Prebuilt e2e.test
Pick the same Kubernetes version you deployed:
```bash
K8S_VERSION=v1.30.4
ARCH=amd64
mkdir -p ~/k8s-e2e && cd ~/k8s-e2e
curl -L https://dl.k8s.io/${K8S_VERSION}/kubernetes-test-linux-${ARCH}.tar.gz -o test.tar.gz
tar -xzf test.tar.gz --strip-components=3 kubernetes/test/bin/e2e.test kubernetes/test/bin/ginkgo
```

## Kubeconfig Export
```bash
export KUBECONFIG=~/kubeconfigs/admin.kubeconfig
```

## Focus Conformance (Short Run)
```bash
./ginkgo --nodes=2 --label-filter='Conformance && !Slow && !Serial' --timeout=2h -- \
  ./e2e.test --provider=local --ginkgo.no-color --ginkgo.v --report-dir=./_report \
  --disable-log-dump=true
```

Expect many tests skipped due to feature gates not enabled. Adjust filters for deeper testing.

## Option B: Full kubetest2 (Longer)
Install Go 1.22+ and use kubetest2 (omitted for brevity). Provides artifact collection & cloud provider integrations.

## Interpreting Failures
- Networking related: verify CNI pods Running
- Storage tests may fail (no default StorageClass); create a hostPath-provisioner or skip these tests
- Load balancer / Service type=LoadBalancer tests will fail (no cloud integration) – filter them out.

## Cleanup
```bash
rm -rf ~/k8s-e2e/_report
```

## Next
(Extra) Dynamic kubelet config note: `17-extra-dynamic-kubelet-configuration-modern.md`.
