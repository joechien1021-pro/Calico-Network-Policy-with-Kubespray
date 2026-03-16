#!/usr/bin/env bash
set -euo pipefail

# Validates Calico policy behavior:
# - same-namespace pod-to-pod traffic is allowed
# - cross-namespace pod-to-pod traffic is denied

POLICY_FILE="${POLICY_FILE:-globalnetworkpolicy/deny-alpha-beta-gamma-communication.yaml}"
TEST_NS_ALPHA="${TEST_NS_ALPHA:-ns-alpha}"
TEST_NS_BETA="${TEST_NS_BETA:-ns-beta}"
TEST_NS_GAMMA="${TEST_NS_GAMMA:-ns-gamma}"
ALPHA_POD_1="${ALPHA_POD_1:-gnp-alpha-1}"
ALPHA_POD_2="${ALPHA_POD_2:-gnp-alpha-2}"
BETA_POD_1="${BETA_POD_1:-gnp-beta-1}"
GAMMA_POD_1="${GAMMA_POD_1:-gnp-gamma-1}"
TIMEOUT="${TIMEOUT:-180s}"
CLEANUP="${CLEANUP:-false}"

declare -a TEST_TITLES=()
declare -a TEST_RESULTS=()

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  log "FAIL: $*"
  exit 1
}

pass() {
  log "PASS: $*"
}

record_test_result() {
  local title="$1"
  local result="$2"
  TEST_TITLES+=("$title")
  TEST_RESULTS+=("$result")
}

print_test_summary_table() {
  local i
  local total="${#TEST_TITLES[@]}"
  local failed=0

  for i in "${!TEST_RESULTS[@]}"; do
    if [ "${TEST_RESULTS[$i]}" = "FAIL" ]; then
      failed=$((failed + 1))
    fi
  done

  printf '\n%s\n' "================ Test Summary ================"
  printf '%-4s | %-6s | %s\n' "No." "Result" "Test"
  printf '%-4s-+-%-6s-+-%s\n' "----" "------" "----------------------------------------------"
  for i in "${!TEST_TITLES[@]}"; do
    printf '%-4d | %-6s | %s\n' "$((i + 1))" "${TEST_RESULTS[$i]}" "${TEST_TITLES[$i]}"
  done
  printf '%-4s-+-%-6s-+-%s\n' "----" "------" "----------------------------------------------"
  printf 'Total: %d, Passed: %d, Failed: %d\n' "$total" "$((total - failed))" "$failed"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

run_expect_success() {
  local title="$1"
  shift

  set +e
  local output
  output=$("$@" 2>&1)
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    record_test_result "$title" "FAIL"
    printf '%s\n' "$output"
    log "FAIL: ${title} (expected success, got exit ${rc})"
    return 1
  fi

  record_test_result "$title" "PASS"
  pass "$title"
  printf '%s\n' "$output"
  return 0
}

run_expect_failure() {
  local title="$1"
  shift

  set +e
  local output
  output=$("$@" 2>&1)
  local rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    record_test_result "$title" "FAIL"
    printf '%s\n' "$output"
    log "FAIL: ${title} (expected failure, but command succeeded)"
    return 1
  fi

  record_test_result "$title" "PASS"
  pass "$title"
  printf '%s\n' "$output"
  return 0
}

cleanup_resources() {
  log "Cleanup: deleting test pods"
  kubectl delete pod "$ALPHA_POD_1" "$ALPHA_POD_2" -n "$TEST_NS_ALPHA" --ignore-not-found >/dev/null || true
  kubectl delete pod "$BETA_POD_1" -n "$TEST_NS_BETA" --ignore-not-found >/dev/null || true
  kubectl delete pod "$GAMMA_POD_1" -n "$TEST_NS_GAMMA" --ignore-not-found >/dev/null || true
}

main() {
  require_cmd kubectl

  if [ ! -f "$POLICY_FILE" ]; then
    fail "Policy file not found: ${POLICY_FILE}"
  fi

  log "Step 1: Verify required Calico CRDs"
  for crd in \
    globalnetworkpolicies.crd.projectcalico.org \
    networkpolicies.crd.projectcalico.org \
    ippools.crd.projectcalico.org; do
    kubectl get crd "$crd" >/dev/null 2>&1 || fail "Missing CRD: ${crd}"
  done
  pass "Calico CRDs exist"

  log "Step 2: Ensure namespaces exist"
  kubectl create namespace "$TEST_NS_ALPHA" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create namespace "$TEST_NS_BETA" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create namespace "$TEST_NS_GAMMA" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  pass "Namespaces ready"

  log "Step 3: Apply policy file ${POLICY_FILE}"
  kubectl apply -f "$POLICY_FILE" >/dev/null
  pass "Policy applied"

  log "Step 4: Create test pods"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${ALPHA_POD_1}
  namespace: ${TEST_NS_ALPHA}
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: ${ALPHA_POD_2}
  namespace: ${TEST_NS_ALPHA}
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: ${BETA_POD_1}
  namespace: ${TEST_NS_BETA}
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: ${GAMMA_POD_1}
  namespace: ${TEST_NS_GAMMA}
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
EOF

  kubectl wait --for=condition=Ready pod/"$ALPHA_POD_1" -n "$TEST_NS_ALPHA" --timeout="$TIMEOUT" >/dev/null
  kubectl wait --for=condition=Ready pod/"$ALPHA_POD_2" -n "$TEST_NS_ALPHA" --timeout="$TIMEOUT" >/dev/null
  kubectl wait --for=condition=Ready pod/"$BETA_POD_1" -n "$TEST_NS_BETA" --timeout="$TIMEOUT" >/dev/null
  kubectl wait --for=condition=Ready pod/"$GAMMA_POD_1" -n "$TEST_NS_GAMMA" --timeout="$TIMEOUT" >/dev/null
  pass "Test pods are Ready"

  local alpha2_ip beta1_ip gamma1_ip
  alpha2_ip=$(kubectl get pod "$ALPHA_POD_2" -n "$TEST_NS_ALPHA" -o jsonpath='{.status.podIP}')
  beta1_ip=$(kubectl get pod "$BETA_POD_1" -n "$TEST_NS_BETA" -o jsonpath='{.status.podIP}')
  gamma1_ip=$(kubectl get pod "$GAMMA_POD_1" -n "$TEST_NS_GAMMA" -o jsonpath='{.status.podIP}')

  log "Step 5: Validate expected traffic behavior"
  local overall_rc=0

  run_expect_success \
    "Same namespace should be allowed (${TEST_NS_ALPHA}: ${ALPHA_POD_1} -> ${ALPHA_POD_2})" \
    kubectl exec -n "$TEST_NS_ALPHA" "$ALPHA_POD_1" -- ping -c 2 -W 1 "$alpha2_ip" || overall_rc=1

  run_expect_failure \
    "Cross namespace should be denied (${TEST_NS_ALPHA}: ${ALPHA_POD_1} -> ${TEST_NS_BETA}: ${BETA_POD_1})" \
    kubectl exec -n "$TEST_NS_ALPHA" "$ALPHA_POD_1" -- ping -c 2 -W 1 "$beta1_ip" || overall_rc=1

  run_expect_failure \
    "Cross namespace should be denied (${TEST_NS_BETA}: ${BETA_POD_1} -> ${TEST_NS_GAMMA}: ${GAMMA_POD_1})" \
    kubectl exec -n "$TEST_NS_BETA" "$BETA_POD_1" -- ping -c 2 -W 1 "$gamma1_ip" || overall_rc=1

  print_test_summary_table

  if [ "$overall_rc" -eq 0 ]; then
    pass "Global policy behavior validated"
  else
    log "FAIL: One or more validation checks failed"
  fi

  if [ "$CLEANUP" = "true" ]; then
    cleanup_resources
    pass "Cleanup complete"
  else
    log "Cleanup skipped (set CLEANUP=true to delete test pods)"
  fi

  if [ "$overall_rc" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
