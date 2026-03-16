set -euo pipefail

declare -a TEST_NAMES=()
declare -a TEST_STATUS=()
declare -a TEST_DETAILS=()

add_result() {
  TEST_NAMES+=("$1")
  TEST_STATUS+=("$2")
  TEST_DETAILS+=("$3")
}

print_results_table() {
  echo
  echo "== Calico CRD Validation Results =="
  printf "%-3s | %-45s | %-6s | %s\n" "No" "Test" "Status" "Details"
  printf -- "----+-----------------------------------------------+--------+-----------------------------\n"
  for i in "${!TEST_NAMES[@]}"; do
    printf "%-3s | %-45s | %-6s | %s\n" \
      "$((i+1))" "${TEST_NAMES[$i]}" "${TEST_STATUS[$i]}" "${TEST_DETAILS[$i]}"
  done
}

overall_status() {
  local s
  for s in "${TEST_STATUS[@]}"; do
    if [[ "$s" == "FAIL" ]]; then
      echo "OVERALL: FAIL"
      return 1
    fi
  done
  echo "OVERALL: PASS"
  return 0
}

REQUIRED_CRDS=(
  "ippools.crd.projectcalico.org"
  "felixconfigurations.crd.projectcalico.org"
  "bgppeers.crd.projectcalico.org"
  "bgpconfigurations.crd.projectcalico.org"
  "kubecontrollersconfigurations.crd.projectcalico.org"
  "networkpolicies.crd.projectcalico.org"
  "globalnetworkpolicies.crd.projectcalico.org"
  "globalnetworksets.crd.projectcalico.org"
  "hostendpoints.crd.projectcalico.org"
)

echo "== Validate Calico CRDs =="
echo "Date: $(date)"
echo

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found"
  add_result "kubectl available" "FAIL" "kubectl not installed"
  print_results_table
  overall_status
  exit 1
fi
add_result "kubectl available" "PASS" "kubectl found"

if kubectl version --request-timeout=5s >/dev/null 2>&1; then
  add_result "Kubernetes API reachable" "PASS" "API reachable"
else
  add_result "Kubernetes API reachable" "FAIL" "cannot reach API"
  print_results_table
  overall_status
  exit 1
fi

echo "Checking required CRDs..."
for crd in "${REQUIRED_CRDS[@]}"; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    established="$(kubectl get crd "$crd" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || true)"
    names_accepted="$(kubectl get crd "$crd" -o jsonpath='{.status.conditions[?(@.type=="NamesAccepted")].status}' 2>/dev/null || true)"

    if [[ "$established" == "True" ]]; then
      add_result "CRD present: $crd" "PASS" "Established=True NamesAccepted=${names_accepted:-N/A}"
    else
      add_result "CRD present: $crd" "FAIL" "Established=${established:-Unknown}"
    fi
  else
    add_result "CRD present: $crd" "FAIL" "missing"
  fi
done

echo "Checking sample CR list APIs..."
check_api() {
  local resource="$1"
  if kubectl get "$resource" --request-timeout=8s >/dev/null 2>&1; then
    add_result "List API: $resource" "PASS" "query ok"
  else
    add_result "List API: $resource" "FAIL" "query failed"
  fi
}

check_api "ippools.crd.projectcalico.org"
check_api "felixconfigurations.crd.projectcalico.org"
check_api "bgpconfigurations.crd.projectcalico.org"

print_results_table() {
  echo
  echo "== Calico CRD Validation Results =="

  if command -v column >/dev/null 2>&1; then
    {
      printf "No\tTest\tStatus\tDetails\n"
      for i in "${!TEST_NAMES[@]}"; do
        printf "%s\t%s\t%s\t%s\n" \
          "$((i+1))" "${TEST_NAMES[$i]}" "${TEST_STATUS[$i]}" "${TEST_DETAILS[$i]}"
      done
    } | column -t -s $'\t'
  else
    # Fallback if 'column' is unavailable
    local name_w=20 status_w=6
    local i
    for i in "${!TEST_NAMES[@]}"; do
      ((${#TEST_NAMES[$i]} > name_w)) && name_w=${#TEST_NAMES[$i]}
      ((${#TEST_STATUS[$i]} > status_w)) && status_w=${#TEST_STATUS[$i]}
    done

    printf "%-3s | %-*s | %-*s | %s\n" "No" "$name_w" "Test" "$status_w" "Status" "Details"
    for i in "${!TEST_NAMES[@]}"; do
      printf "%-3s | %-*s | %-*s | %s\n" \
        "$((i+1))" "$name_w" "${TEST_NAMES[$i]}" "$status_w" "${TEST_STATUS[$i]}" "${TEST_DETAILS[$i]}"
    done
  fi
}


print_results_table
overall_status
