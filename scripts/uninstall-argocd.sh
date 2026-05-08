#!/usr/bin/env bash
set -euo pipefail

# AGW Federated GitOps -- ArgoCD Uninstall Script
# Tears down everything created by install-argocd.sh:
#   - ArgoCD Applications, ApplicationSets, AppProjects
#   - ArgoCD helm release and namespace on the hub cluster
#   - Leaf cluster RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding, token secret)
#   - Istio CA certs (cacerts in istio-system)
#   - LLM and license secrets in agentgateway-system
#
# Supported platforms: Colima, EKS, GKE (same as install script)
#
# Usage:
#   ./scripts/uninstall-argocd.sh
#
# Options:
#   --skip-app-deletion   Skip deleting ArgoCD Applications (leaves managed
#                         resources in place on leaf clusters)
#   --force               Skip confirmation prompt

HUB_CTX="${HUB_CTX:-hub-1}"
LEAF1_CTX="${LEAF1_CTX:-leaf-1}"
LEAF2_CTX="${LEAF2_CTX:-leaf-2}"

SKIP_APP_DELETION=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --skip-app-deletion) SKIP_APP_DELETION=true ;;
    --force) FORCE=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# =============================================================================
# Confirmation
# =============================================================================
if [ "$FORCE" = false ]; then
  echo "This will uninstall ArgoCD and ALL managed resources from:"
  echo "  Hub:   $HUB_CTX"
  echo "  Leaf1: $LEAF1_CTX"
  echo "  Leaf2: $LEAF2_CTX"
  echo ""
  read -r -p "Continue? (y/N) " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# =============================================================================
# Delete ArgoCD Applications (triggers cascade deletion of managed resources)
# =============================================================================
delete_applications() {
  if [ "$SKIP_APP_DELETION" = true ]; then
    echo "=== Skipping Application deletion (--skip-app-deletion) ==="
    return
  fi

  echo "=== Deleting ArgoCD Applications ==="

  # Remove finalizers and delete all Applications so ArgoCD cascades the
  # deletion to managed resources on leaf clusters.
  local apps
  apps=$(kubectl get applications -n argocd --context "$HUB_CTX" -o name 2>/dev/null || true)

  if [ -z "$apps" ]; then
    echo "  No Applications found."
    return
  fi

  for app in $apps; do
    echo "  Deleting $app..."
    kubectl delete "$app" -n argocd --context "$HUB_CTX" --timeout=60s 2>/dev/null || true
  done

  # Wait for Applications to be cleaned up
  echo "  Waiting for Applications to be removed (up to 120s)..."
  local elapsed=0
  while [ $elapsed -lt 120 ]; do
    local remaining
    remaining=$(kubectl get applications -n argocd --context "$HUB_CTX" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$remaining" -eq 0 ]; then
      echo "  All Applications deleted."
      return
    fi
    echo "  $remaining Applications remaining..."
    sleep 10
    elapsed=$((elapsed + 10))
  done

  echo "  WARNING: Some Applications may still be deleting. Proceeding anyway."
}

# =============================================================================
# Delete ApplicationSets and AppProjects
# =============================================================================
delete_applicationsets() {
  echo "=== Deleting ApplicationSets ==="
  kubectl delete applicationsets --all -n argocd --context "$HUB_CTX" --timeout=60s 2>/dev/null || true
  echo "  ApplicationSets deleted."
}

delete_appprojects() {
  echo "=== Deleting AppProjects ==="
  # Delete non-default projects only
  local projects
  projects=$(kubectl get appprojects -n argocd --context "$HUB_CTX" -o name 2>/dev/null | grep -v "appproject/default" || true)
  for proj in $projects; do
    kubectl delete "$proj" -n argocd --context "$HUB_CTX" --timeout=30s 2>/dev/null || true
  done
  echo "  AppProjects deleted."
}

# =============================================================================
# Delete leaf cluster secrets from ArgoCD
# =============================================================================
delete_cluster_secrets() {
  echo "=== Deleting ArgoCD cluster secrets ==="
  for name in leaf-1-cluster-secret leaf-2-cluster-secret; do
    kubectl delete secret "$name" -n argocd --context "$HUB_CTX" 2>/dev/null || true
  done
  echo "  Cluster secrets deleted."
}

# =============================================================================
# Uninstall ArgoCD helm release
# =============================================================================
uninstall_argocd() {
  echo "=== Uninstalling ArgoCD helm release ==="
  helm uninstall argocd --namespace argocd --kube-context "$HUB_CTX" 2>/dev/null || true
  echo "  Helm release removed."

  echo "  Deleting argocd namespace..."
  kubectl delete namespace argocd --context "$HUB_CTX" --timeout=120s 2>/dev/null || true
  echo "  argocd namespace deleted."
}

# =============================================================================
# Clean up leaf cluster RBAC and token secrets
# =============================================================================
cleanup_leaf_rbac() {
  echo "=== Cleaning up leaf cluster RBAC ==="
  for ctx in $LEAF1_CTX $LEAF2_CTX; do
    echo "  Cleaning $ctx..."
    kubectl delete clusterrolebinding argocd-manager-role-binding --context "$ctx" 2>/dev/null || true
    kubectl delete clusterrole argocd-manager-role --context "$ctx" 2>/dev/null || true
    kubectl delete secret argocd-manager-token -n kube-system --context "$ctx" 2>/dev/null || true
    kubectl delete sa argocd-manager -n kube-system --context "$ctx" 2>/dev/null || true
  done
  echo "  Leaf RBAC cleaned up."
}

# =============================================================================
# Clean up Istio CA certs
# =============================================================================
cleanup_istio_certs() {
  echo "=== Cleaning up Istio CA certs ==="
  for ctx in $LEAF1_CTX $LEAF2_CTX; do
    kubectl delete secret cacerts -n istio-system --context "$ctx" 2>/dev/null || true
  done
  echo "  Istio CA certs removed."
}

# =============================================================================
# Clean up secrets on leaf clusters
# =============================================================================
cleanup_leaf_secrets() {
  echo "=== Cleaning up secrets on leaf clusters ==="
  for ctx in $LEAF1_CTX $LEAF2_CTX; do
    echo "  Cleaning $ctx..."
    kubectl delete secret enrollment-openai-secret -n agentgateway-system --context "$ctx" 2>/dev/null || true
    kubectl delete secret solo-license -n agentgateway-system --context "$ctx" 2>/dev/null || true
  done
  echo "  Leaf secrets removed."
}

# =============================================================================
# Remove global service labels
# =============================================================================
cleanup_global_labels() {
  echo "=== Removing global service labels ==="
  for svc in solo-enterprise-ui solo-enterprise-telemetry-gateway; do
    kubectl label svc "$svc" -n kagent --context "$LEAF1_CTX" \
      solo.io/service-scope- 2>/dev/null || true
  done
  echo "  Global labels removed."
}

# =============================================================================
# Main
# =============================================================================
echo "============================================"
echo "  AGW Federated GitOps -- Uninstall"
echo "============================================"
echo ""

delete_applicationsets
delete_applications
delete_appprojects
delete_cluster_secrets
uninstall_argocd
cleanup_leaf_rbac
cleanup_istio_certs
cleanup_leaf_secrets
cleanup_global_labels

echo ""
echo "============================================"
echo "  Uninstall complete"
echo "============================================"
echo ""
echo "The following were removed:"
echo "  - ArgoCD (helm release + namespace) on $HUB_CTX"
echo "  - All ArgoCD Applications, ApplicationSets, AppProjects"
echo "  - Leaf cluster secrets (argocd-manager SA, RBAC, tokens)"
echo "  - Istio CA certs (cacerts in istio-system)"
echo "  - LLM/license secrets in agentgateway-system"
if [ "$SKIP_APP_DELETION" = true ]; then
  echo ""
  echo "NOTE: --skip-app-deletion was set. Resources managed by ArgoCD"
  echo "      Applications (workloads, namespaces, etc.) were NOT deleted."
fi
