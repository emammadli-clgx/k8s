# Run End-to-End Tests

## Install Go

```bash
wget -q --show-progress --https-only --timestamping 
  https://go.dev/dl/go1.22.4.linux-amd64.tar.gz

sudo tar -C /usr/local -xzf go1.22.4.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
```

## Install kubetest

```bash
go install k8s.io/test-infra/kubetest@latest
```

> Note: This may take a few minutes depending on your network speed.

## Run Conformance Tests

```bash
kubetest --extract=v1.29.2

cd kubernetes

kubetest --test --provider=skeleton --test_args="--ginkgo.focus=\[Conformance\]" | tee test.out
```

This could take about 1.5 to 2 hours. The number of tests run and passed will be displayed at the end.
