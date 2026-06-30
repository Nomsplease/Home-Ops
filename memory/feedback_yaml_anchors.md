---
name: feedback-yaml-anchors
description: User dislikes YAML anchors/aliases in Kubernetes manifests in this repo
metadata:
  type: feedback
---

Avoid YAML anchors (`&name`) and aliases (`*name`) in this repo's manifests (HelmRelease values, etc.) — write repeated values out literally instead, even if it costs extra lines.

**Why:** User stated plainly "I really dont like Yaml anchors." Requested removal from a generated `kubernetes/apps/llm/openclaw/app/helmrelease.yaml` that used anchors for shared `env`, `securityContext`, `probes`, `envFrom`, and port/path values across multiple containers.

**How to apply:** When drafting new HelmRelease/manifest YAML for this cluster, default to literal repetition over anchors, even when upstream source manifests (e.g. things copied from other home-ops repos) use anchors heavily. Only fall back to an anchor if avoiding it would make the file genuinely unreadable (e.g. a huge multi-field block repeated many times) — ask first rather than assuming that's fine.
