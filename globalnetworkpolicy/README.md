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

## 3. `allow-same-namespace-only.yaml`

**Purpose:** Restrict pods to communicating only with other pods in the **same namespace**.

```yaml
kind: NetworkPolicy           # namespace-scoped (not cluster-wide)
name: allow-same-namespace-only
namespaces: ns-alpha, ns-beta

selector: all()               # applies to every pod in the namespace
types: [Ingress, Egress]

ingress: Allow from source selector all()         # any pod in this namespace
egress:  Allow to destination selector all()      # any pod in this namespace
```

**Key detail — scope:** This uses `kind: NetworkPolicy` (namespace-scoped), not `GlobalNetworkPolicy`. It is applied independently to `ns-alpha` and `ns-beta`. Any pod outside those namespaces initiating a connection will be denied by the accompanying default-deny rule.

**When to use:**
- Pair with `calico-global-default-deny.yaml` to isolate namespaces from each other.
- Use as a building block before adding finer-grained per-service rules.

**Apply:**
```bash
kubectl apply -f allow-same-namespace-only.yaml
```

> Note: The `selector: all()` in the ingress/egress rules **does not** include a `namespaceSelector`, so in this standalone file any pod (even from another namespace) that passes higher-priority rules could still reach these pods. In `calico-tiered-zero-trust.yaml` this is tightened with an explicit `namespaceSelector`.

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

### Policy 3 — `allow-same-namespace-only` for `ns-alpha` (order: 200)

Namespace-scoped `NetworkPolicy` on `ns-alpha`.

Allows ingress/egress **only** to/from pods in `ns-alpha` (enforced via `namespaceSelector: kubernetes.io/metadata.name == 'ns-alpha'`). This is stricter than the standalone version in file #3 above because the `namespaceSelector` explicitly pins traffic to the namespace.

---

### Policy 4 — `allow-same-namespace-only` for `ns-beta` and `ns-gamma` (order: 200)

Identical rules applied independently to `ns-beta` and `ns-gamma`. Each namespace only allows communication within itself.

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
   order 200 ──► Same namespace peer?    → ALLOW
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
