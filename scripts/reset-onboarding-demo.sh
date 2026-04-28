#!/usr/bin/env bash
set -euo pipefail

# AGW Federated GitOps -- Onboarding Demo Reset
# Reverts all onboarding demo changes and restores baseline state.
#
# Prerequisites:
#   - gh CLI authenticated
#   - onboarding-baseline tag exists (created by setup script)
#
# Usage: ./scripts/reset-onboarding-demo.sh

INFRA_REPO="ably77/agw-federated-infra"
CLUSTER1_REPO="ably77/agw-federated-cluster-1"

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER1_DIR="$(cd "$INFRA_DIR/../agw-federated-cluster-1" && pwd)"

HUB_CTX="${HUB_CTX:-hub-1}"
LEAF1_CTX="${LEAF1_CTX:-leaf-1}"

echo "=== Resetting onboarding demo ==="

# Step 1: Reset cluster-1 repo first (remove workloads before removing backends/policies)
echo ""
echo "--- Resetting cluster-1 repo ---"
pushd "$CLUSTER1_DIR" > /dev/null
git checkout main
git pull origin main

CLUSTER1_BASELINE=$(git rev-parse onboarding-baseline)
CLUSTER1_HEAD=$(git rev-parse HEAD)

if [ "$CLUSTER1_HEAD" != "$CLUSTER1_BASELINE" ]; then
  git reset --hard "$CLUSTER1_BASELINE"
  git push origin main --force
  echo "  Cluster-1 reset to baseline ($CLUSTER1_BASELINE)"
else
  echo "  Cluster-1 already at baseline"
fi
popd > /dev/null

# Step 2: Wait for ArgoCD to prune streaming workloads
echo ""
echo "--- Waiting for ArgoCD to sync cluster-1 (30s) ---"
sleep 30

# Step 3: Reset infra repo (remove backends, policies, namespace grants)
echo ""
echo "--- Resetting infra repo ---"
pushd "$INFRA_DIR" > /dev/null
git checkout main
git pull origin main

INFRA_BASELINE=$(git rev-parse onboarding-baseline)
INFRA_HEAD=$(git rev-parse HEAD)

if [ "$INFRA_HEAD" != "$INFRA_BASELINE" ]; then
  git reset --hard "$INFRA_BASELINE"
  git push origin main --force
  echo "  Infra reset to baseline ($INFRA_BASELINE)"
else
  echo "  Infra already at baseline"
fi
popd > /dev/null

# Step 4: Close any remaining open onboarding PRs
echo ""
echo "--- Closing leftover onboarding PRs ---"
for repo in "$INFRA_REPO" "$CLUSTER1_REPO"; do
  OPEN_PRS=$(gh pr list --repo "$repo" --search "head:onboarding/" --json number --jq '.[].number' 2>/dev/null || true)
  for pr in $OPEN_PRS; do
    gh pr close "$pr" --repo "$repo" --comment "Closed by reset script." 2>/dev/null || true
    echo "  Closed $repo#$pr"
  done
done

# Step 5: Clean up tags
echo ""
echo "--- Cleaning up baseline tags ---"
pushd "$INFRA_DIR" > /dev/null
git tag -d onboarding-baseline 2>/dev/null || true
git push origin :refs/tags/onboarding-baseline 2>/dev/null || true
popd > /dev/null

pushd "$CLUSTER1_DIR" > /dev/null
git tag -d onboarding-baseline 2>/dev/null || true
git push origin :refs/tags/onboarding-baseline 2>/dev/null || true
popd > /dev/null

# Step 6: Verify
echo ""
echo "--- Verifying baseline state ---"
echo "  Checking streaming namespaces are gone..."
if kubectl get ns streaming-backend --context "$LEAF1_CTX" &>/dev/null; then
  echo "  [WARN] streaming-backend namespace still exists (ArgoCD may need more time to prune)"
else
  echo "  [OK] streaming-backend namespace removed"
fi

if kubectl get ns streaming-frontend --context "$LEAF1_CTX" &>/dev/null; then
  echo "  [WARN] streaming-frontend namespace still exists (ArgoCD may need more time to prune)"
else
  echo "  [OK] streaming-frontend namespace removed"
fi

echo ""
echo "=== Reset complete ==="
echo "Run ./scripts/validate.sh to confirm full baseline health."
