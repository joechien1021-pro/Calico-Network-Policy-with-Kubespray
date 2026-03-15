# Calico Network Policy with Kubespray

A reference implementation of Calico `GlobalNetworkPolicy` zero-trust network segmentation on Kubernetes, with automated cluster provisioning via Kubespray and Minikube-based CRD installation for local development.

---

## Overview

This repository provides:

- **GlobalNetworkPolicy templates** — ready-to-apply Calico policy YAMLs covering allow-all, deny-all, same-namespace-only, and a full tiered zero-trust stack.
- **Kubespray installer** — a single-host bash script that provisions a Kubernetes cluster (control-plane + worker) with Calico as the CNI.
- **Minikube helper** — installs Calico CRDs into a Minikube cluster for local policy testing without a full Calico deployment.
- **Test suite** — scripts to deploy test pods across multiple namespaces and validate that zero-trust policies are correctly enforced.

---

## Repository Structure

```
.
├── globalnetworkpolicy/
│   ├── allow-same-namespace-only.yaml    # Namespace-scoped: allow intra-namespace traffic only
│   ├── calico-global-default-allow.yaml  # GlobalNetworkPolicy: allow all ingress + egress
│   ├── calico-global-default-deny.yaml   # GlobalNetworkPolicy: deny all ingress + egress
│   └── calico-tiered-zero-trust.yaml     # Full zero-trust stack (DNS, kube-api, namespace isolation, default deny)
├── kubespray/
│   └── deploy-kubespray-single-calico.sh # Provision a single-node k8s cluster with Calico via Kubespray
├── minikube/
│   └── install-calico-crds.sh            # Install Calico CRDs into a Minikube cluster
└── test/
    ├── deploy-3-pods.sh                  # Create ns-alpha/ns-beta/ns-gamma with 3 pods each
    ├── validate-calico-zero-trust.sh     # Automated zero-trust policy validation
    └── remove-3-pods.sh                  # Tear down test pods and namespaces
```

---

## Prerequisites

| Requirement | Version |
|---|---|
| Kubernetes | 1.20+ |
| Calico | v3.27+ |
| `kubectl` | Matching cluster version |
| Calico CRDs | Installed (see below) |

For Kubespray deployment:
- Ubuntu 20.04 or 22.04 (Kali Linux also supported)
- Minimum 2 CPUs, 2 GB RAM
- Python 3, pip, git, openssh-client

---

## Quick Start

### Option A — Minikube (local testing)

Install Calico CRDs into an existing Minikube cluster:

```bash
# Default: Calico v3.29.2
bash minikube/install-calico-crds.sh

# Custom version:
CALICO_VERSION=v3.28.0 bash minikube/install-calico-crds.sh
```

### Option B — Full cluster with Kubespray

Provision a single-node Kubernetes cluster with Calico on Ubuntu:

```bash
bash kubespray/deploy-kubespray-single-calico.sh
```

Environment variable overrides (all optional):

| Variable | Default | Description |
|---|---|---|
| `KUBE_VERSION` | `1.35.1` | Kubernetes version to deploy |
| `NODE_NAME` | `node1` | Node hostname in the inventory |
| `INVENTORY_NAME` | `mycluster` | Kubespray inventory name |
| `RUN_RESET_FIRST` | `false` | Set `true` to reset an existing cluster first |
| `SKIP_UPGRADE` | `false` | Set `true` to skip `apt upgrade` |

---

## GlobalNetworkPolicy Templates

### 1. Default Allow (`calico-global-default-allow.yaml`)

Allows all ingress and egress traffic cluster-wide. Use as a baseline or to temporarily disable restrictions.

```bash
kubectl apply -f globalnetworkpolicy/calico-global-default-allow.yaml
```

### 2. Default Deny (`calico-global-default-deny.yaml`)

Denies all ingress and egress traffic cluster-wide. Apply as the base of a zero-trust posture.

```bash
kubectl apply -f globalnetworkpolicy/calico-global-default-deny.yaml
```

### 3. Same-Namespace Only (`allow-same-namespace-only.yaml`)

Restricts pods to communicating only within their own namespace (`ns-alpha`, `ns-beta`).

```bash
kubectl apply -f globalnetworkpolicy/allow-same-namespace-only.yaml
```

### 4. Tiered Zero-Trust Stack (`calico-tiered-zero-trust.yaml`)

A complete zero-trust policy set applied in priority order:

| Order | Policy | Purpose |
|---|---|---|
| 100 | `allow-dns-egress` | Allow DNS (UDP/TCP 53) to node-local-dns and kube-dns |
| 110 | `allow-kube-api-egress` | Allow egress to the Kubernetes API server (`10.233.0.1:6443`) |
| 200 | `allow-same-namespace-only` | Allow intra-namespace traffic for `ns-alpha`, `ns-beta`, `ns-gamma` |
| 1000 | `global-default-deny` | Deny all remaining ingress and egress traffic |

```bash
kubectl apply -f globalnetworkpolicy/calico-tiered-zero-trust.yaml
```

---

## Testing Zero-Trust Enforcement

### Deploy test pods

Creates namespaces `ns-alpha`, `ns-beta`, `ns-gamma` with 3 pods each (nginx for alpha/beta, busybox for gamma):

```bash
bash test/deploy-3-pods.sh
```

### Validate policies (automated)

Runs an end-to-end validation that:
1. Verifies Calico CRDs are installed
2. Creates isolated test namespaces (`zt-a`, `zt-b`) with BusyBox pods
3. Checks pods are Calico-managed via CNI annotation
4. Applies zero-trust `GlobalNetworkPolicy`
5. **Asserts** same-namespace ping **succeeds**
6. **Asserts** cross-namespace ping **fails**

```bash
bash test/validate-calico-zero-trust.sh
```

Environment variable overrides:

| Variable | Default | Description |
|---|---|---|
| `TEST_NS_A` | `zt-a` | First test namespace |
| `TEST_NS_B` | `zt-b` | Second test namespace |
| `POD_A1` | `zt-a-1` | Pod 1 in namespace A |
| `POD_A2` | `zt-a-2` | Pod 2 in namespace A |
| `POD_B1` | `zt-b-1` | Pod 1 in namespace B |

### Remove test pods

```bash
bash test/remove-3-pods.sh
```

---

## Policy Enforcement Model

```
Pod (any namespace)
  │
  ├── Egress order 100 ──► Allow DNS (kube-dns / node-local-dns)
  ├── Egress order 110 ──► Allow Kubernetes API server
  ├── Ingress/Egress order 200 ──► Allow same-namespace peers only
  └── Ingress/Egress order 1000 ──► Deny everything else
```

Cross-namespace traffic is silently dropped. Intra-namespace traffic is permitted. DNS resolution and Kubernetes API access are always preserved.

---

## License

MIT

