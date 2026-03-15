#!/usr/bin/env bash
set -euo pipefail

CALICO_VERSION="${CALICO_VERSION:-v3.29.2}"
CRDS_URL="${CRDS_URL:-https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/crds.yaml}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl is not installed or not in PATH." >&2
  exit 1
fi

echo "Applying Calico CRDs from: ${CRDS_URL}"
kubectl apply -f "${CRDS_URL}"

required_crds=(
  globalnetworkpolicies.crd.projectcalico.org
  networkpolicies.crd.projectcalico.org
  ippools.crd.projectcalico.org
  felixconfigurations.crd.projectcalico.org
)

echo "Verifying required Calico CRDs..."
for crd in "${required_crds[@]}"; do
  kubectl get crd "${crd}" >/dev/null
  echo "  - Found ${crd}"
done

echo "Calico CRD installation complete."
