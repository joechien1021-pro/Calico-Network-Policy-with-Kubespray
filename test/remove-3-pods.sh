# ns-alpha — delete pod-alpha-1 pod-alpha-2 and pod-alpha-3
kubectl delete pod pod-alpha-1 -n ns-alpha
kubectl delete pod pod-alpha-2 -n ns-alpha
kubectl delete pod pod-alpha-3 -n ns-alpha

# ns-beta — delete pod-beta-1 pod-beta-2 and pod-beta-3
kubectl delete pod pod-beta-1 -n ns-beta
kubectl delete pod pod-beta-2 -n ns-beta
kubectl delete pod pod-beta-3 -n ns-beta

# ns-gamma — delete pod-gamma-1 pod-gamma-2 and pod-gamma-3
kubectl delete pod pod-gamma-1 -n ns-gamma
kubectl delete pod pod-gamma-2 -n ns-gamma
kubectl delete pod pod-gamma-3 -n ns-gamma

kubectl delete namespace ns-alpha
kubectl delete namespace ns-beta
kubectl delete namespace ns-gamma


