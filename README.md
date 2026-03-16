# Calico Network Policy with Kubespray

A reference implementation of Calico `GlobalNetworkPolicy` zero-trust network segmentation on Kubernetes, with automated cluster provisioning via Kubespray and Minikube-based CRD installation for local development.

---

## Overview

This repository provides:

- **GlobalNetworkPolicy templates** — ready-to-apply Calico policy YAMLs covering allow-all, deny-all, alpha/beta/gamma-communication-only, and a full tiered zero-trust stack.
- **Kubespray installer** — a single-host bash script that provisions a Kubernetes cluster (control-plane + worker) with Calico as the CNI.
- **Minikube helper** — installs Calico CRDs into a Minikube cluster for local policy testing without a full Calico deployment.
- **Test suite** — scripts to deploy test pods across multiple namespaces and validate that zero-trust policies are correctly enforced.

---

## Repository Structure

```
.
├── globalnetworkpolicy/
│   ├── allow-only-alpha-beta-communication.yaml  # Namespace-scoped: allow traffic only among ns-alpha/ns-beta/ns-gamma
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
  ├── validate-globalnetworkpolicy.sh   # Automated test with PASS/FAIL summary table for global policy behavior
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

### 3. Alpha/Beta/Gamma Only (`allow-only-alpha-beta-communication.yaml`)

Restricts selected pods to communicating only with peers in `ns-alpha`, `ns-beta`, or `ns-gamma`.

```bash
kubectl apply -f globalnetworkpolicy/allow-only-alpha-beta-communication.yaml
```

### 4. Deny Cross-Namespace Pod Communication (`deny-alpha-beta-gamma-communication.yaml`)

Denies pod-to-pod communication across namespaces `ns-alpha`, `ns-beta`, and `ns-gamma`, while keeping same-namespace pod communication allowed.

```bash
kubectl apply -f globalnetworkpolicy/deny-alpha-beta-gamma-communication.yaml
```

### 5. Tiered Zero-Trust Stack (`calico-tiered-zero-trust.yaml`)

A complete zero-trust policy set is applied in priority order:

| Order | Policy | Purpose |
|---|---|---|
| 100 | `allow-dns-egress` | Allow DNS (UDP/TCP 53) to node-local-dns and kube-dns |
| 110 | `allow-kube-api-egress` | Allow egress to the Kubernetes API server (`10.233.0.1:6443`) |
| 200 | `allow-same-namespace-only` | Allow traffic among `ns-alpha`, `ns-beta`, `ns-gamma` |
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

### Validate global network policy with PASS/FAIL table

Runs an automated test for `globalnetworkpolicy/deny-alpha-beta-gamma-communication.yaml` and prints a summary table of checks.

Expected behavior:
1. Same-namespace traffic is allowed.
2. Cross-namespace traffic is denied.

```bash
./test/validate-globalnetworkpolicy.sh
```

Optional cleanup after tests:

```bash
CLEANUP=true ./test/validate-globalnetworkpolicy.sh
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
  ├── Ingress/Egress order 200 ──► Allow peers in ns-alpha/ns-beta/ns-gamma only
  └── Ingress/Egress order 1000 ──► Deny everything else
```

Traffic to or from namespaces outside ns-alpha/ns-beta/ns-gamma is silently dropped. Traffic among ns-alpha/ns-beta/ns-gamma is permitted. DNS resolution and Kubernetes API access are always preserved.

---

## Command Reference

### Query GlobalNetworkPolicy order and allow/deny actions

```bash
kubectl get globalnetworkpolicy.crd.projectcalico.org \
  -o custom-columns=NAME:.metadata.name,ORDER:.spec.order,INGRESS:.spec.ingress[*].action,EGRESS:.spec.egress[*].action \
  --sort-by=.spec.order
```

Description:
- Lists all Calico `GlobalNetworkPolicy` objects.
- Shows policy name, `order`, ingress actions, and egress actions.
- Sorts by `order` so evaluation priority is easy to read.

### Query NetworkPolicy order and allow/deny actions (all namespaces)

```bash
kubectl get networkpolicy.crd.projectcalico.org -A \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,ORDER:.spec.order,INGRESS:.spec.ingress[*].action,EGRESS:.spec.egress[*].action \
  --sort-by=.spec.order
```

Description:
- Lists all Calico namespace-scoped `NetworkPolicy` objects across namespaces.
- Shows namespace, policy name, `order`, ingress actions, and egress actions.
- Sorts by `order` to help detect overlaps and rule precedence.

### Use this command to verify Calico namespace-scoped policies across the whole cluster.

```bash
kubectl get networkpolicy.crd.projectcalico.org -A -o wide
```

- `kubectl get`: Lists Kubernetes resources.
- `networkpolicy.crd.projectcalico.org`: Targets Calico CRD `NetworkPolicy` objects (not the built-in Kubernetes NetworkPolicy API).
- `-A`: Shows policies from all namespaces.
- `-o wide`: Prints a wider output table with additional columns when available.

This is useful for checking whether old or overlapping Calico policies are still applied.

### Use this command to verify Calico cluster-wide global policies.

```bash
kubectl get globalnetworkpolicy.crd.projectcalico.org -A -o wide
```

- `kubectl get`: Lists Kubernetes resources.
- `globalnetworkpolicy.crd.projectcalico.org`: Targets Calico CRD `GlobalNetworkPolicy` objects.
- `-A`: Included for consistency with other get commands (GlobalNetworkPolicy is cluster-scoped, so namespace does not change results).
- `-o wide`: Prints a wider output table with additional columns when available.

This is useful for confirming that baseline global rules (for example, DNS allow, kube-api allow, and default deny) are applied.

---

## License

MIT

