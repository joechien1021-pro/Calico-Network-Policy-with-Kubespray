# GlobalNetworkPolicy — Policy Reference

This folder contains four Calico network policy YAML files. They can be applied independently or together as a tiered zero-trust stack.

---

## 1. `calico-global-default-allow.yaml`

**Purpose:** Allow all traffic cluster-wide (open posture).

```yaml
kind: GlobalNetworkPolicy
name: global-default-allow
selector: all()        # applies to every pod in every namespace
types: [Ingress, Egress]
ingress: Allow
egress:  Allow
```

**When to use:**
- Initial cluster bring-up before policies are defined.
- Temporarily disabling restrictions for debugging.
- Verifying that an application works before layering deny rules.

**Apply:**
```bash
kubectl apply -f calico-global-default-allow.yaml
```

> ⚠️ Do not leave this policy active in production — it overrides all other deny rules at the same or higher order.

---

## 2. `calico-global-default-deny.yaml`

**Purpose:** Deny all traffic cluster-wide (closed/zero-trust base).

```yaml
kind: GlobalNetworkPolicy
name: global-default-deny
selector: all()        # applies to every pod in every namespace
types: [Ingress, Egress]
ingress: Deny
egress:  Deny
```

**When to use:**
- As the **lowest-priority catch-all** at the bottom of a tiered policy stack (highest `order` number).
- Enforcing an implicit-deny posture so only explicitly allowed traffic passes.

**Apply:**
```bash
kubectl apply -f calico-global-default-deny.yaml
```

> This policy has **no `order` field**, so Calico assigns it the default order. In a tiered stack, use `calico-tiered-zero-trust.yaml` instead, which sets `order: 1000` on the deny rule so it is evaluated last.

---

## 3. `allow-only-alpha-beta-gamma-communication.yaml`

**Purpose:** Restrict pods to communicating only with other pods in `ns-alpha`, `ns-beta`, or `ns-gamma`.

```yaml
kind: NetworkPolicy           # namespace-scoped (not cluster-wide)
name: allow-alpha-beta-gamma-only
namespaces: ns-alpha, ns-beta, ns-gamma

selector: all()               # applies to every pod in the namespace
types: [Ingress, Egress]

ingress: Allow from source in ns-alpha/ns-beta/ns-gamma
egress:  Allow to destination in ns-alpha/ns-beta/ns-gamma
```

**Key detail — scope:** This uses `kind: NetworkPolicy` (namespace-scoped), not `GlobalNetworkPolicy`. It is applied independently to `ns-alpha`, `ns-beta`, and `ns-gamma`, and each rule explicitly allows peers only from those three namespaces via `namespaceSelector`.

**When to use:**
- Pair with `calico-global-default-deny.yaml` to block all traffic outside this namespace set.
- Use as a building block before adding finer-grained per-service rules.

**Apply:**
```bash
kubectl apply -f allow-only-alpha-beta-gamma-communication.yaml
```

> Note: This file currently allows traffic among ns-alpha/ns-beta/ns-gamma (not only alpha-beta). If you need alpha-beta only, remove `ns-gamma` from each `namespaceSelector` and remove the `ns-gamma` policy object.

---

## 4. `calico-tiered-zero-trust.yaml`

**Purpose:** A complete, ordered zero-trust policy stack. Apply this single file to enforce DNS access, Kubernetes API access, same-namespace isolation, and a final default deny — all in priority order.

This file contains **five policy objects** evaluated in `order` sequence (lowest number = highest priority):

### Policy 1 — `allow-dns-egress` (order: 100)

Allows all pods to reach DNS on port 53 (UDP and TCP).

Targets two DNS backends:
| Destination | Description |
|---|---|
| `169.254.25.10/32` | NodeLocal DNSCache (link-local) |
| `10.233.0.3/32` | kube-dns ClusterIP |
| `kube-system` pods with `k8s-app=kube-dns` or `k8s-app=node-local-dns` | Label-based fallback |

Without this rule, pods behind a default-deny policy cannot resolve service names at all.

---

### Policy 2 — `allow-kube-api-egress` (order: 110)

Allows all pods to reach the Kubernetes API server.

```
Destination: 10.233.0.1:6443 (TCP)
```

Required for pods that call the Kubernetes API (e.g. controllers, operators, service accounts using in-cluster config). Without this, `kubectl` inside pods and API-driven workloads fail.

---

### Policy 3 — `allow-alpha-beta-gamma-only` for `ns-alpha` (order: 200)

Namespace-scoped `NetworkPolicy` on `ns-alpha`.

Allows ingress/egress only when the peer pod is in `ns-alpha`, `ns-beta`, or `ns-gamma` (enforced via `namespaceSelector`).

---

### Policy 4 — `allow-alpha-beta-gamma-only` for `ns-beta` and `ns-gamma` (order: 200)

Identical rules applied independently to `ns-beta` and `ns-gamma`. Pods in these namespaces can communicate with pods in `ns-alpha`, `ns-beta`, and `ns-gamma`, but not with other namespaces.

---

### Policy 5 — `global-default-deny` (order: 1000)

The catch-all deny. Any traffic not explicitly permitted by policies at order < 1000 is dropped here.

```yaml
kind: GlobalNetworkPolicy
selector: all()
order: 1000
ingress: Deny
egress:  Deny
```

---

### Full evaluation flow

```
Any pod makes a connection attempt
         │
   order 100 ──► DNS (port 53)?          → ALLOW
   order 110 ──► Kube API (port 6443)?   → ALLOW
      order 200 ──► Peer in ns-alpha/ns-beta/ns-gamma? → ALLOW
   order 1000 ──► Everything else        → DENY
```

**Apply the full stack:**
```bash
kubectl apply -f calico-tiered-zero-trust.yaml
```

**Remove the full stack:**
```bash
kubectl delete -f calico-tiered-zero-trust.yaml
```

---

## Command Reference

### `kubectl get networkpolicy.crd.projectcalico.org -A -o wide`

Use this command to verify Calico namespace-scoped policies across the whole cluster.

- `kubectl get`: Lists Kubernetes resources.
- `networkpolicy.crd.projectcalico.org`: Targets Calico CRD `NetworkPolicy` objects (not the built-in Kubernetes NetworkPolicy API).
- `-A`: Shows policies from all namespaces.
- `-o wide`: Prints a wider output table with additional columns when available.

This is useful for checking whether old or overlapping Calico policies are still applied.

### `kubectl get globalnetworkpolicy.crd.projectcalico.org -A -o wide`

Use this command to verify Calico cluster-wide global policies.

- `kubectl get`: Lists Kubernetes resources.
- `globalnetworkpolicy.crd.projectcalico.org`: Targets Calico CRD `GlobalNetworkPolicy` objects.
- `-A`: Included for consistency with other get commands (GlobalNetworkPolicy is cluster-scoped, so namespace does not change results).
- `-o wide`: Prints a wider output table with additional columns when available.

This is useful for confirming that baseline global rules (for example DNS allow, kube-api allow, and default deny) are applied.
