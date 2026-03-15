kubectl create namespace ns-alpha
kubectl create namespace ns-beta
kubectl create namespace ns-gamma

### Deploy 3 pods to each namespace ###

# ns-alpha — add pod-alpha-1 pod-alpha-2 and pod-alpha-3
kubectl run pod-alpha-1 --image=nginx -n ns-alpha
kubectl run pod-alpha-2 --image=nginx -n ns-alpha
kubectl run pod-alpha-3 --image=nginx -n ns-alpha

# ns-beta — add pod-beta-1 pod-beta-2 and pod-beta-3
kubectl run pod-beta-1 --image=nginx -n ns-beta
kubectl run pod-beta-2 --image=nginx -n ns-beta
kubectl run pod-beta-3 --image=nginx -n ns-beta

# ns-gamma — add pod-gamma-1 pod-gamma-2 and pod-gamma-3
kubectl run pod-gamma-1 --image=busybox -n ns-gamma --command -- sleep 3600
kubectl run pod-gamma-2 --image=busybox -n ns-gamma --command -- sleep 3600
kubectl run pod-gamma-3 --image=busybox -n ns-gamma --command -- sleep 3600

echo "Waiting for pods to become Ready..."
kubectl wait --for=condition=Ready pod/pod-alpha-1 pod/pod-alpha-2 pod/pod-alpha-3 -n ns-alpha --timeout=180s
kubectl wait --for=condition=Ready pod/pod-beta-1 pod/pod-beta-2 pod/pod-beta-3 -n ns-beta --timeout=180s
kubectl wait --for=condition=Ready pod/pod-gamma-1 pod/pod-gamma-2 pod/pod-gamma-3 -n ns-gamma --timeout=180s


ALPHA_IP_1=$(kubectl get pod pod-alpha-1 -n ns-alpha -o jsonpath='{.status.podIP}')
ALPHA_IP_2=$(kubectl get pod pod-alpha-2 -n ns-alpha -o jsonpath='{.status.podIP}')
ALPHA_IP_3=$(kubectl get pod pod-alpha-3 -n ns-alpha -o jsonpath='{.status.podIP}')

BETA_IP_1=$(kubectl get pod pod-beta-1 -n ns-beta -o jsonpath='{.status.podIP}')
BETA_IP_2=$(kubectl get pod pod-beta-2 -n ns-beta -o jsonpath='{.status.podIP}')
BETA_IP_3=$(kubectl get pod pod-beta-3 -n ns-beta -o jsonpath='{.status.podIP}')

GAMMA_IP_1=$(kubectl get pod pod-gamma-1 -n ns-gamma -o jsonpath='{.status.podIP}')
GAMMA_IP_2=$(kubectl get pod pod-gamma-2 -n ns-gamma -o jsonpath='{.status.podIP}')
GAMMA_IP_3=$(kubectl get pod pod-gamma-3 -n ns-gamma -o jsonpath='{.status.podIP}')

# Install in all 3 pods
kubectl exec -n ns-alpha pod-alpha-1 -- apt-get update -qq && \
kubectl exec -n ns-alpha pod-alpha-1 -- apt-get install -y iputils-ping

kubectl exec -n ns-alpha pod-alpha-2 -- apt-get update -qq && \
kubectl exec -n ns-alpha pod-alpha-2 -- apt-get install -y iputils-ping

kubectl exec -n ns-alpha pod-alpha-3 -- apt-get update -qq && \
kubectl exec -n ns-alpha pod-alpha-3 -- apt-get install -y iputils-ping

kubectl exec -n ns-beta pod-beta-1 -- apt-get update -qq && \
kubectl exec -n ns-beta pod-beta-1 -- apt-get install -y iputils-ping

kubectl exec -n ns-beta pod-beta-2 -- apt-get update -qq && \
kubectl exec -n ns-beta pod-beta-2 -- apt-get install -y iputils-ping

kubectl exec -n ns-beta pod-beta-3 -- apt-get update -qq && \
kubectl exec -n ns-beta pod-beta-3 -- apt-get install -y iputils-ping

# pod-gamma (busybox) already has ping — skip it

echo "=== Alpha-1 -> Beta-1 ===" && kubectl exec -n ns-alpha pod-alpha-1 -- ping -c 2 "$BETA_IP_1"
echo "=== Alpha-2 -> Gamma-2 ===" && kubectl exec -n ns-alpha pod-alpha-2 -- ping -c 2 "$GAMMA_IP_2"
echo "=== Alpha-3 -> Gamma-3 ===" && kubectl exec -n ns-alpha pod-alpha-3 -- ping -c 2 "$GAMMA_IP_3"

echo "=== Beta-1 -> Alpha-1 ===" && kubectl exec -n ns-beta pod-beta-1 -- ping -c 2 "$ALPHA_IP_1"
echo "=== Beta-2 -> Gamma-2 ===" && kubectl exec -n ns-beta pod-beta-2 -- ping -c 2 "$GAMMA_IP_2"
echo "=== Beta-3 -> Gamma-3 ===" && kubectl exec -n ns-beta pod-beta-3 -- ping -c 2 "$GAMMA_IP_3"

echo "=== Gamma-1 -> Alpha-1 ===" && kubectl exec -n ns-gamma pod-gamma-1 -- ping -c 2 "$ALPHA_IP_1"
echo "=== Gamma-2 -> Beta-2 ===" && kubectl exec -n ns-gamma pod-gamma-2 -- ping -c 2 "$BETA_IP_2"
echo "=== Gamma-3 -> Beta-3 ===" && kubectl exec -n ns-gamma pod-gamma-3 -- ping -c 2 "$BETA_IP_3"
