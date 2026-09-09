#!/usr/bin/env bash
# Regenerates kubernetes/apps/games/agones/app/crds.yaml from the agones Helm chart,
# stripping the invalid x-kubernetes-patch-strategy / x-kubernetes-patch-merge-key
# keys that break server-side apply (see the header this script writes for why).
# Invoked by Renovate's postUpgradeTask on every agones chart bump — see .renovaterc.json5.
set -euo pipefail

VERSION="${1:?usage: regen-agones-crds.sh <agones-chart-version>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO_ROOT/kubernetes/apps/games/agones/app/crds.yaml"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

YQ_VERSION="v4.44.3"
HELM_VERSION="v3.16.2"

yq_bin="$(command -v yq || true)"
if [[ -z "$yq_bin" ]]; then
  curl -fsSL -o "$WORKDIR/yq" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
  chmod +x "$WORKDIR/yq"
  yq_bin="$WORKDIR/yq"
fi

helm_bin="$(command -v helm || true)"
if [[ -z "$helm_bin" ]]; then
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C "$WORKDIR"
  helm_bin="$WORKDIR/linux-amd64/helm"
fi

"$helm_bin" repo add agones https://agones.dev/chart/stable >/dev/null 2>&1 || true
"$helm_bin" repo update agones >/dev/null

rendered="$WORKDIR/rendered.yaml"
"$helm_bin" template agones agones/agones --version "$VERSION" >"$rendered"

cleaned="$WORKDIR/cleaned.yaml"
"$yq_bin" eval 'select(.kind == "CustomResourceDefinition")' "$rendered" \
  | "$yq_bin" eval 'del(.. | select(has("x-kubernetes-patch-strategy")).x-kubernetes-patch-strategy)' - \
  | "$yq_bin" eval 'del(.. | select(has("x-kubernetes-patch-merge-key")).x-kubernetes-patch-merge-key)' - \
  >"$cleaned"

if ! grep -q "^kind: CustomResourceDefinition" "$cleaned"; then
  echo "ERROR: no CustomResourceDefinition objects found in rendered chart output" >&2
  exit 1
fi

if grep -q "x-kubernetes-patch" "$cleaned"; then
  echo "ERROR: cleaned CRDs still contain x-kubernetes-patch-* keys" >&2
  exit 1
fi

cat >"$OUT" <<HEADER
# Vendored from \`helm template agones/agones --version ${VERSION}\` with
# x-kubernetes-patch-strategy / x-kubernetes-patch-merge-key stripped from every
# CRD schema. Those keys are strategic-merge-patch markers leaked from the
# vendored corev1.PodTemplateSpec type into the generated CRD schema — they
# aren't valid JSONSchemaProps fields, and the apiserver's server-side-apply
# rejects the CRD outright with "field not declared in schema" because of
# them (fleets/gameservers/gameserversets). Regenerated automatically by
# Scripts/Renovate/regen-agones-crds.sh via a Renovate postUpgradeTask on
# every agones chart bump. HelmRelease has crds set to Skip so Helm doesn't
# fight over these.
HEADER
cat "$cleaned" >>"$OUT"

echo "Wrote $(wc -l <"$OUT") lines to $OUT for agones $VERSION"
