# Dynamic Kubelet Configuration (Status 2025)

## Summary
Dynamic Kubelet Configuration (DKC) was an alpha/experimental feature allowing live reconfiguration of kubelets by pointing them to a centralized ConfigMap. This feature has been removed/deprecated due to complexity and security concerns. Modern clusters rely on:
- Declarative config files shipped via provisioning (cloud-init, ignition, config management)
- Kubelet flags + config file on disk
- Rolling updates / node replacement for config changes

## What To Do Instead
1. Maintain a versioned kubelet config template in infrastructure repo.
2. For changes (e.g., eviction thresholds, image GC):
   - Update template
   - Replace nodes one-by-one (cordon + drain + reprovision)
3. For small lab: edit /var/lib/kubelet/kubelet-config.yaml then restart kubelet.

Example safe manual change (adjust image GC thresholds):
```bash
sudo sed -i 's/^$/imageGCHighThresholdPercent: 85\nimageGCLowThresholdPercent: 70/' /var/lib/kubelet/kubelet-config.yaml
sudo systemctl restart kubelet
```

## Observability
Validate config effect:
```bash
kubectl describe node worker-1 | grep -i image\ gc || true
```
(Not all fields surface; check kubelet logs if needed.)

## Security Note
Avoid enabling experimental dynamic features without clear security posture; static, reviewable config tied to node lifecycle is simpler and auditable.

## Conclusion
Dynamic kubelet configuration is no longer part of the recommended path. Treat kubelet settings as immutable per node image; modify through rebuild + rolling replacement.
