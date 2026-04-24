#!/usr/bin/env bash
set -euo pipefail

# Re-register leaf clusters with ArgoCD
# Use after Colima restart when VM IPs change, or when switching
# between platforms (Colima, EKS, GKE).
#
# Supported platforms: Colima, EKS, GKE (auto-detected from kubeconfig)
#
# Usage: ./scripts/register-clusters.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HUB_CTX="${HUB_CTX:-cluster1}"
LEAF1_CTX="${LEAF1_CTX:-cluster2}"
LEAF2_CTX="${LEAF2_CTX:-cluster3}"

echo "=== Re-registering leaf clusters ==="

# Get ArgoCD password
PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd \
  --context "$HUB_CTX" -o jsonpath='{.data.password}' | base64 -d)

# Port-forward ArgoCD (port 80 since server runs --insecure)
kubectl port-forward svc/argocd-server -n argocd 8443:80 \
  --context "$HUB_CTX" &>/dev/null &
PF_PID=$!
sleep 5

argocd login localhost:8443 \
  --username admin \
  --password "$PASSWORD" \
  --plaintext

# Remove old registrations
for name in leaf-1 leaf-2; do
  argocd cluster rm "$name" 2>/dev/null || true
done

# Re-register
for pair in "leaf-1:$LEAF1_CTX" "leaf-2:$LEAF2_CTX"; do
  leaf_name="${pair%%:*}"
  leaf_ctx="${pair##*:}"
  cluster_repo="https://github.com/ably77/agw-federated-cluster-${leaf_name##leaf-}.git"

  echo "Registering $leaf_name ($leaf_ctx)..."
  argocd cluster add "$leaf_ctx" \
    --name "$leaf_name" \
    --label "agw-role=leaf" \
    --label "agw-leaf-name=${leaf_name}" \
    --label "agw-cluster-repo=${cluster_repo}" \
    --yes
done

kill $PF_PID 2>/dev/null || true
echo "Done. ArgoCD will re-sync automatically."
