---
name: feedback-apiserver-vip
description: Don't add a dedicated VIP/LB mechanism (kube-vip, etc.) for apiserver bootstrap or resilience
metadata:
  type: feedback
---

Don't introduce automated VIP/failover infrastructure (e.g. kube-vip) to solve apiserver reachability during cluster bootstrap or Cilium outages. The established pattern: provision/join against a literal control-plane node IP (with the VIP hostname added as an extra apiserver cert SAN so it validates later), then manually swap the kubeconfig `server:` line to the BGP-advertised VIP hostname (`k8s.${SECRET_DOMAIN}`, via Cilium's `CiliumBGPAdvertisement` + LB IPAM in `kubernetes/apps/kube-system/cilium/app/networking.yaml`) once the cluster and Cilium BGP are up.

**Why:** When the apiserver has had issues in practice, this manual swap has always been sufficient — it's not an actual pain point. Running a second BGP speaker (kube-vip) alongside Cilium's BGP agent on the same nodes also causes real session collisions with the upstream router (one BGP neighbor/connection object per node IP — see `rb5009-bgp.rsc`), not just redundant config.

**How to apply:** Don't propose kube-vip-style VIP ownership as a fix for bootstrap chicken-and-egg problems or for Cilium-outage resilience, in either the Talos flow or the ansible/kubeadm FCOS flow. Was floated and rejected 2026-10-13.
