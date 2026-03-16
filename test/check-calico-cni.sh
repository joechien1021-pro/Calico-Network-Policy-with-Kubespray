#!/usr/bin/env bash
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
  echo "== Test Results Summary =="
  printf "%-3s | %-35s | %-6s | %s\n" "No" "Test" "Status" "Details"
  printf -- "----+-------------------------------------+--------+-----------------------------\n"
  for i in "${!TEST_NAMES[@]}"; do
    printf "%-3s | %-35s | %-6s | %s\n" \
      "$((i+1))" "${TEST_NAMES[$i]}" "${TEST_STATUS[$i]}" "${TEST_DETAILS[$i]}"
  done
}

echo "== Calico CNI diagnostics =="
echo "Host: $(hostname)"
echo "Date: $(date)"
echo

echo "1) CNI config directory"
CNI_DIR="/etc/cni/net.d"
if [[ -d "$CNI_DIR" ]]; then
  ls -la "$CNI_DIR"
  echo
  ACTIVE_CFG="$(find "$CNI_DIR" -maxdepth 1 -type f \( -name '*.conflist' -o -name '*.conf' \) | sort | head -n1 || true)"
  if [[ -n "${ACTIVE_CFG:-}" ]]; then
    echo "Active candidate config: $ACTIVE_CFG"
    echo "---- file content ----"
    cat "$ACTIVE_CFG"
    echo "----------------------"
    if grep -q '"type"[[:space:]]*:[[:space:]]*"calico"' "$ACTIVE_CFG"; then
      echo "[OK] Active CNI config contains type=calico"
      add_result "Active CNI config is Calico" "PASS" "$ACTIVE_CFG"
    else
      echo "[WARN] Active CNI config does not show type=calico"
      add_result "Active CNI config is Calico" "WARN" "$ACTIVE_CFG missing type=calico"
    fi
  else
    echo "[WARN] No CNI .conf/.conflist files found in $CNI_DIR"
    add_result "CNI config file exists" "FAIL" "No .conf/.conflist in $CNI_DIR"
  fi
else
  echo "[FAIL] $CNI_DIR not found"
  add_result "CNI config directory exists" "FAIL" "$CNI_DIR not found"
fi
echo

echo "2) CNI binaries"
CNI_BIN="/opt/cni/bin"
if [[ -d "$CNI_BIN" ]]; then
  ls -la "$CNI_BIN" | grep -E 'calico|calico-ipam|portmap' || true
  if [[ -x "$CNI_BIN/calico" ]]; then
    echo "[OK] calico binary present"
    add_result "calico binary present" "PASS" "$CNI_BIN/calico"
  else
    echo "[WARN] calico binary missing"
    add_result "calico binary present" "FAIL" "$CNI_BIN/calico missing"
  fi

  if [[ -x "$CNI_BIN/calico-ipam" ]]; then
    echo "[OK] calico-ipam binary present"
    add_result "calico-ipam binary present" "PASS" "$CNI_BIN/calico-ipam"
  else
    echo "[WARN] calico-ipam binary missing"
    add_result "calico-ipam binary present" "FAIL" "$CNI_BIN/calico-ipam missing"
  fi
else
  echo "[WARN] $CNI_BIN not found"
  add_result "CNI bin directory exists" "FAIL" "$CNI_BIN not found"
fi
echo

echo "3) Kubelet CNI flags"
if pgrep -x kubelet >/dev/null 2>&1; then
  KUBELET_LINE="$(ps -ef | grep '[k]ubelet' | head -n1 || true)"
  echo "$KUBELET_LINE" | grep -E -- '--cni-conf-dir|--cni-bin-dir|--network-plugin' || true
  if echo "$KUBELET_LINE" | grep -q -- '--cni-conf-dir'; then
    add_result "kubelet has --cni-conf-dir" "PASS" "flag found"
  else
    add_result "kubelet has --cni-conf-dir" "WARN" "flag not explicit (may use defaults)"
  fi
  if echo "$KUBELET_LINE" | grep -q -- '--cni-bin-dir'; then
    add_result "kubelet has --cni-bin-dir" "PASS" "flag found"
  else
    add_result "kubelet has --cni-bin-dir" "WARN" "flag not explicit (may use defaults)"
  fi
else
  echo "[WARN] kubelet process not found"
  add_result "kubelet process running" "FAIL" "kubelet not found"
fi
echo

echo "4) Node-level Calico interfaces/routes"
if ip link show | grep -Eq 'cali|vxlan.calico|tunl0'; then
  ip link show | grep -E 'cali|vxlan.calico|tunl0'
  add_result "Calico interfaces present" "PASS" "cali/vxlan/tunl detected"
else
  echo "[WARN] No calico-related interfaces detected"
  add_result "Calico interfaces present" "WARN" "none detected"
fi

if ip route | grep -Eq 'proto bird|cali|blackhole'; then
  ip route | grep -E 'proto bird|cali|blackhole'
  add_result "Calico routes present" "PASS" "bird/cali routes detected"
else
  echo "[INFO] No obvious calico routes found"
  add_result "Calico routes present" "WARN" "none detected"
fi
echo

if command -v kubectl >/dev/null 2>&1; then
  echo "5) Kubernetes-level checks (kubectl)"
  NODE="$(hostname)"
  CALICO_PODS="$(kubectl -n kube-system get pods -o wide | grep calico-node || true)"
  if [[ -n "$CALICO_PODS" ]]; then
    echo "$CALICO_PODS"
    add_result "calico-node pod exists" "PASS" "found in kube-system"
  else
    add_result "calico-node pod exists" "FAIL" "not found in kube-system output"
  fi

  echo
  echo "Calico node pod on this node:"
  kubectl -n kube-system get pod -l k8s-app=calico-node -o wide --field-selector spec.nodeName="$NODE" || true

  echo
  echo "Recent calico-node logs:"
  if kubectl -n kube-system logs -l k8s-app=calico-node --tail=80 >/tmp/calico_logs.$$ 2>/dev/null; then
    cat /tmp/calico_logs.$$
    add_result "calico-node logs readable" "PASS" "logs fetched"
  else
    echo "[WARN] Unable to fetch calico-node logs"
    add_result "calico-node logs readable" "WARN" "kubectl logs failed"
  fi
  rm -f /tmp/calico_logs.$$ || true
else
  echo "5) kubectl not found; skipping cluster-level checks"
  add_result "kubectl available" "WARN" "kubectl not installed on node"
fi

print_results_table
echo
echo "== Done =="
