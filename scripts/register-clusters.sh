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

HUB_CTX="${HUB_CTX:-hub-1}"
LEAF1_CTX="${LEAF1_CTX:-leaf-1}"
LEAF2_CTX="${LEAF2_CTX:-leaf-2}"

# Detect platform from hub context
detect_platform() {
  local ctx=$1
  local server
  server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}")\")].cluster.server}" 2>/dev/null)
  case "$server" in
    *.eks.amazonaws.com*) echo "eks" ;;
    *.gke.goog*|*.googleapis.com*) echo "gke" ;;
    *127.0.0.1*|*localhost*) echo "colima" ;;
    *) echo "unknown" ;;
  esac
}

# Resolve Colima profile name from kubectl context
get_colima_profile() {
  local ctx=$1
  local cluster_name
  cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null)
  echo "${cluster_name#colima-}"
}

PLATFORM=$(detect_platform "$HUB_CTX")
echo "=== Re-registering leaf clusters (platform: $PLATFORM) ==="

if [ "$PLATFORM" = "colima" ]; then
  # Colima: update cluster secrets with current VM IPs
  for pair in "leaf-1:$LEAF1_CTX" "leaf-2:$LEAF2_CTX"; do
    leaf_name="${pair%%:*}"
    leaf_ctx="${pair##*:}"
    leaf_num="${leaf_name##leaf-}"
    cluster_repo="https://github.com/ably77/agw-federated-cluster-${leaf_num}.git"

    echo "Registering $leaf_name ($leaf_ctx)..."

    # Get current VM IP and k3s API port (from kubeconfig)
    colima_profile=$(get_colima_profile "$leaf_ctx")
    vm_ip=$(colima ssh --profile "$colima_profile" -- hostname -I 2>/dev/null | awk '{print $1}')
    cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$leaf_ctx\")].context.cluster}" 2>/dev/null)
    kube_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster_name\")].cluster.server}" 2>/dev/null)
    api_port=$(echo "$kube_server" | sed 's|.*:\([0-9]*\)$|\1|')
    server_url="https://${vm_ip}:${api_port}"
    echo "  Server URL: $server_url"

    # Get bearer token (SA already exists from initial install)
    token=$(kubectl get secret argocd-manager-token -n kube-system \
      --context "$leaf_ctx" -o jsonpath='{.data.token}' | base64 -d)

    # Update the cluster secret
    kubectl apply --context "$HUB_CTX" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${leaf_name}-cluster-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    agw-role: leaf
    agw-leaf-name: ${leaf_name}
  annotations:
    agw-cluster-repo: ${cluster_repo}
type: Opaque
stringData:
  name: ${leaf_name}
  server: ${server_url}
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF

    echo "  $leaf_name registered."
  done

else
  # EKS/GKE: use argocd CLI
  PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd \
    --context "$HUB_CTX" -o jsonpath='{.data.password}' | base64 -d)

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
      --annotation "agw-cluster-repo=${cluster_repo}" \
      --yes
  done

  kill $PF_PID 2>/dev/null || true
fi

echo "Done. ArgoCD will re-sync automatically."
