#!/usr/bin/env bash
set -euo pipefail

# Kubespray single-host installer (control-plane + worker) with Calico.
# Designed for Ubuntu 20.04/22.04 as requested.

KUBESPRAY_REPO_URL="${KUBESPRAY_REPO_URL:-https://github.com/kubernetes-sigs/kubespray.git}"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$HOME/kubespray}"
INVENTORY_NAME="${INVENTORY_NAME:-mycluster}"
KUBE_VERSION="${KUBE_VERSION:-1.35.1}"
NODE_NAME="${NODE_NAME:-node1}"
INVENTORY_FILE="${INVENTORY_FILE:-inventory/${INVENTORY_NAME}/inventory.ini}"
RUN_RESET_FIRST="${RUN_RESET_FIRST:-false}"
SKIP_UPGRADE="${SKIP_UPGRADE:-false}"
NORMALIZED_KUBE_VERSION="${KUBE_VERSION#v}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

step() {
  log "===== $* ====="
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    log "ERROR: Missing required command: ${cmd}"
    exit 1
  }
}

replace_or_append_yaml_key() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -Eq "^${key}:" "$file"; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
  else
    printf '\n%s: %s\n' "$key" "$value" >> "$file"
  fi
}

step "Step 1: System requirements check"
require_cmd nproc
require_cmd free
require_cmd awk
require_cmd grep
require_cmd sudo

CPU_COUNT=$(nproc)
MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
DISTRO_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
UBUNTU_VERSION="$(. /etc/os-release && echo "${VERSION_ID:-unknown}")"
UBUNTU_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"

log "Detected OS: ${UBUNTU_NAME}"
log "Detected CPUs: ${CPU_COUNT}"
log "Detected RAM MB: ${MEM_TOTAL_MB}"

if [ "$CPU_COUNT" -lt 2 ]; then
  log "ERROR: Need at least 2 CPUs."
  exit 1
fi

if [ "$MEM_TOTAL_MB" -lt 2048 ]; then
  log "ERROR: Need at least 2GB RAM."
  exit 1
fi

if [ "$UBUNTU_VERSION" != "20.04" ] && [ "$UBUNTU_VERSION" != "22.04" ]; then
  log "WARNING: This script targets Ubuntu 20.04/22.04. Continuing anyway."
fi

step "Step 2: Install dependencies"
sudo apt update
if [ "$SKIP_UPGRADE" != "true" ]; then
  sudo apt upgrade -y
else
  log "Skipping apt upgrade because SKIP_UPGRADE=true"
fi
sudo apt install -y python3 python3-pip python3-venv git openssh-client

step "Step 3: Clone Kubespray"
if [ -d "$KUBESPRAY_DIR/.git" ]; then
  log "Kubespray directory already exists. Pulling latest changes."
  git -C "$KUBESPRAY_DIR" fetch --all --tags
  git -C "$KUBESPRAY_DIR" pull --ff-only || true
else
  git clone "$KUBESPRAY_REPO_URL" "$KUBESPRAY_DIR"
fi

cd "$KUBESPRAY_DIR"

step "Step 4: Setup Python virtual environment"
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
python3 -m pip install --upgrade pip
pip install -r requirements.txt

step "Step 5: Create inventory"
cp -rfp inventory/sample "inventory/${INVENTORY_NAME}"
HOST_IP="$(hostname -I | awk '{print $1}')"
if [ -z "$HOST_IP" ]; then
  log "ERROR: Could not determine HOST_IP from hostname -I"
  exit 1
fi
log "Using HOST_IP=${HOST_IP}"

step "Step 6: Configure single-node roles (controller + worker + etcd)"
cat > "$INVENTORY_FILE" <<EOF
[kube_control_plane]
${NODE_NAME} ansible_host=${HOST_IP} ip=${HOST_IP} access_ip=${HOST_IP} etcd_member_name=etcd1

[etcd:children]
kube_control_plane

[kube_node]
${NODE_NAME} ansible_host=${HOST_IP} ip=${HOST_IP} access_ip=${HOST_IP}

[calico_rr]

[k8s_cluster:children]
kube_control_plane
kube_node
EOF

log "Generated ${INVENTORY_FILE}:"
cat "$INVENTORY_FILE"

step "Step 7: Configure key settings"
K8S_CLUSTER_YML="inventory/${INVENTORY_NAME}/group_vars/k8s_cluster/k8s-cluster.yml"
replace_or_append_yaml_key "$K8S_CLUSTER_YML" "kube_network_plugin" "calico"
replace_or_append_yaml_key "$K8S_CLUSTER_YML" "node_taints" "[]"
replace_or_append_yaml_key "$K8S_CLUSTER_YML" "kube_version" '"'"${NORMALIZED_KUBE_VERSION}"'"'

log "Configured ${K8S_CLUSTER_YML}:"
grep -E '^(kube_network_plugin|node_taints|kube_version):' "$K8S_CLUSTER_YML" || true

step "Step 8: Setup SSH key for localhost"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
else
  log "SSH key already exists at $HOME/.ssh/id_rsa"
fi

if [ ! -f "$HOME/.ssh/authorized_keys" ]; then
  touch "$HOME/.ssh/authorized_keys"
fi

if ! grep -q -F "$(cat "$HOME/.ssh/id_rsa.pub")" "$HOME/.ssh/authorized_keys"; then
  cat "$HOME/.ssh/id_rsa.pub" >> "$HOME/.ssh/authorized_keys"
fi

chmod 600 "$HOME/.ssh/authorized_keys"
ssh -o StrictHostKeyChecking=no localhost echo "SSH OK"

ANSIBLE_BECOME_ARGS=(--become --become-user=root)
if sudo -n true >/dev/null 2>&1; then
  log "Passwordless sudo detected."
else
  log "sudo requires a password. Ansible will prompt for become password."
  ANSIBLE_BECOME_ARGS+=(--ask-become-pass)
fi

ANSIBLE_EXTRA_ARGS=()
if [ "$DISTRO_ID" = "kali" ]; then
  log "Kali detected. Enabling Kubespray unsupported OS override."
  ANSIBLE_EXTRA_ARGS+=( -e allow_unsupported_distribution_setup=true )
fi

step "Optional: reset existing cluster"
if [ "$RUN_RESET_FIRST" = "true" ]; then
  ansible-playbook -i "$INVENTORY_FILE" "${ANSIBLE_BECOME_ARGS[@]}" "${ANSIBLE_EXTRA_ARGS[@]}" reset.yml
else
  log "Skipping reset.yml (set RUN_RESET_FIRST=true to run it)."
fi

step "Step 9: Run Kubespray cluster deployment"
ansible-playbook -i "$INVENTORY_FILE" \
  "${ANSIBLE_BECOME_ARGS[@]}" \
  "${ANSIBLE_EXTRA_ARGS[@]}" \
  cluster.yml

step "Step 10: Configure kubectl"
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

log "Cluster status:"
kubectl get nodes -o wide
kubectl get pods -A

step "After install: Verify Calico"
kubectl get pods -n kube-system | grep calico || true

log "Completed Kubespray single-host deployment with Calico."
