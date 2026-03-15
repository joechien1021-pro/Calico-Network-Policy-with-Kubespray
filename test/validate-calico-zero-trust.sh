#!/usr/bin/env bash
set -euo pipefail

TEST_NS_A="${TEST_NS_A:-zt-a}"
TEST_NS_B="${TEST_NS_B:-zt-b}"
POD_A1="${POD_A1:-zt-a-1}"
POD_A2="${POD_A2:-zt-a-2}"
POD_B1="${POD_B1:-zt-b-1}"
CALICO_API_VERSION="${CALICO_API_VERSION:-crd.projectcalico.org/v1}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

pass() {
  log "PASS: $*"
}

fail() {
  log "FAIL: $*"
  exit 1
}

run_expect_success() {
  local title="$1"
  shift

  log "TEST: ${title}"
  set +e
  local output
  output=$("$@" 2>&1)
  local rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    pass "${title}"
    printf '%s\n' "$output"
  else
    printf '%s\n' "$output"
    fail "${title} (expected success, got exit ${rc})"
  fi
}

run_expect_failure() {
  local title="$1"
  shift

  log "TEST: ${title}"
  set +e
  local output
  output=$("$@" 2>&1)
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    pass "${title}"
    printf '%s\n' "$output"
  else
    printf '%s\n' "$output"
    fail "${title} (expected failure, but command succeeded)"
  fi
}

ensure_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: ${cmd}"
}

print_diagnostics() {
  local calico_node_pod

  log "Diagnostics: running extended cluster checks"
  set +e

  log "Diagnostics: Calico control-plane pods"
  kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cni' || true

  log "Diagnostics: Calico daemonset"
  kubectl get ds -n kube-system calico-node -o wide || true

  log "Diagnostics: GlobalNetworkPolicy list"
  kubectl get globalnetworkpolicy.crd.projectcalico.org \
    -o custom-columns=NAME:.metadata.name,ORDER:.spec.order,SELECTOR:.spec.selector || true

  log "Diagnostics: test pod labels"
  kubectl get pod "$POD_A1" -n "$TEST_NS_A" --show-labels || true
  kubectl get pod "$POD_A2" -n "$TEST_NS_A" --show-labels || true
  kubectl get pod "$POD_B1" -n "$TEST_NS_B" --show-labels || true

  calico_node_pod=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "${calico_node_pod}" ]; then
    log "Diagnostics: recent calico-node logs (${calico_node_pod})"
    kubectl logs -n kube-system "$calico_node_pod" --tail=80 || true
  else
    log "Diagnostics: no calico-node pod found via label k8s-app=calico-node"
  fi

  set -e
}

log "Step 0: Pre-checks"
ensure_cmd kubectl
kubectl version --client >/dev/null
pass "kubectl command is available"

log "Step 1: Validate Calico CRDs are installed before applying GlobalNetworkPolicy"
required_crds=(
  globalnetworkpolicies.crd.projectcalico.org
  networkpolicies.crd.projectcalico.org
  ippools.crd.projectcalico.org
  felixconfigurations.crd.projectcalico.org
)

for crd in "${required_crds[@]}"; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    pass "CRD found: ${crd}"
  else
    fail "CRD missing: ${crd}. Install Calico CRDs first."
  fi
done

log "Step 2: Prepare validation namespaces and pods"
kubectl create namespace "$TEST_NS_A" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace "$TEST_NS_B" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
pass "Namespaces ready: ${TEST_NS_A}, ${TEST_NS_B}"

kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_A1}
  namespace: ${TEST_NS_A}
  labels:
    app: zero-trust-test
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_A2}
  namespace: ${TEST_NS_A}
  labels:
    app: zero-trust-test
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_B1}
  namespace: ${TEST_NS_B}
  labels:
    app: zero-trust-test
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
EOF
pass "Test pods applied"

log "Waiting for test pods to become Ready"
kubectl wait --for=condition=Ready pod/${POD_A1} -n ${TEST_NS_A} --timeout=180s >/dev/null
kubectl wait --for=condition=Ready pod/${POD_A2} -n ${TEST_NS_A} --timeout=180s >/dev/null
kubectl wait --for=condition=Ready pod/${POD_B1} -n ${TEST_NS_B} --timeout=180s >/dev/null
pass "All test pods are Ready"

log "Step 2b: Validate pods are attached to Calico CNI"
for p in "$POD_A1" "$POD_A2"; do
  cali_pod_ip=$(kubectl get pod "$p" -n "$TEST_NS_A" -o jsonpath='{.metadata.annotations.cni\.projectcalico\.org/podIP}')
  if [ -z "$cali_pod_ip" ]; then
    fail "Pod ${TEST_NS_A}/${p} is not Calico-managed (missing cni.projectcalico.org/podIP). Check active CNI order/config."
  fi
done

cali_pod_ip=$(kubectl get pod "$POD_B1" -n "$TEST_NS_B" -o jsonpath='{.metadata.annotations.cni\.projectcalico\.org/podIP}')
if [ -z "$cali_pod_ip" ]; then
  fail "Pod ${TEST_NS_B}/${POD_B1} is not Calico-managed (missing cni.projectcalico.org/podIP). Check active CNI order/config."
fi
pass "Pods are Calico-managed"

A2_IP=$(kubectl get pod "$POD_A2" -n "$TEST_NS_A" -o jsonpath='{.status.podIP}')
B1_IP=$(kubectl get pod "$POD_B1" -n "$TEST_NS_B" -o jsonpath='{.status.podIP}')
pass "Discovered pod IPs: ${POD_A2}=${A2_IP}, ${POD_B1}=${B1_IP}"

log "Step 3: Apply Calico zero-trust policies"
kubectl apply -f - <<EOF
apiVersion: ${CALICO_API_VERSION}
kind: GlobalNetworkPolicy
metadata:
  name: zero-trust-allow-same-namespace-${TEST_NS_A}
spec:
  order: 1000
  selector: projectcalico.org/namespace == '${TEST_NS_A}'
  types:
    - Ingress
    - Egress
  ingress:
    - action: Allow
      source:
        selector: projectcalico.org/namespace == '${TEST_NS_A}'
  egress:
    - action: Allow
      destination:
        selector: projectcalico.org/namespace == '${TEST_NS_A}'
---
apiVersion: ${CALICO_API_VERSION}
kind: GlobalNetworkPolicy
metadata:
  name: zero-trust-allow-same-namespace-${TEST_NS_B}
spec:
  order: 1000
  selector: projectcalico.org/namespace == '${TEST_NS_B}'
  types:
    - Ingress
    - Egress
  ingress:
    - action: Allow
      source:
        selector: projectcalico.org/namespace == '${TEST_NS_B}'
  egress:
    - action: Allow
      destination:
        selector: projectcalico.org/namespace == '${TEST_NS_B}'
---
apiVersion: ${CALICO_API_VERSION}
kind: GlobalNetworkPolicy
metadata:
  name: zero-trust-default-deny-all
spec:
  order: 2000
  selector: all()
  types:
    - Ingress
    - Egress
  ingress:
    - action: Deny
  egress:
    - action: Deny
EOF
pass "Calico global policies applied"

log "Step 4: Validate traffic behavior"
run_expect_success \
  "Same namespace traffic should be allowed (${TEST_NS_A}: ${POD_A1} -> ${POD_A2})" \
  kubectl exec -n "$TEST_NS_A" "$POD_A1" -- ping -c 2 -W 1 "$A2_IP"

log "TEST: Inter-namespace traffic should be denied (${TEST_NS_A}: ${POD_A1} -> ${TEST_NS_B}: ${POD_B1})"
set +e
INTER_NS_OUTPUT=$(kubectl exec -n "$TEST_NS_A" "$POD_A1" -- ping -c 2 -W 1 "$B1_IP" 2>&1)
INTER_NS_RC=$?
set -e

if [ "$INTER_NS_RC" -ne 0 ]; then
  pass "Inter-namespace traffic should be denied (${TEST_NS_A}: ${POD_A1} -> ${TEST_NS_B}: ${POD_B1})"
  printf '%s\n' "$INTER_NS_OUTPUT"
else
  printf '%s\n' "$INTER_NS_OUTPUT"
  log "Inter-namespace traffic was allowed unexpectedly."
  print_diagnostics
  fail "Inter-namespace traffic should be denied (${TEST_NS_A}: ${POD_A1} -> ${TEST_NS_B}: ${POD_B1}) (expected failure, but command succeeded)"
fi

log "Validation complete"
pass "Zero-trust policy is enforced: same-namespace allowed, inter-namespace denied"
log "Optional cleanup command: kubectl delete ns ${TEST_NS_A} ${TEST_NS_B}"
