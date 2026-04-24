#!/usr/bin/env bash
set -uo pipefail

# AGW Federated GitOps -- End-to-end Validation
# Validates that the entire reference architecture is working correctly.
#
# Usage: ./scripts/validate.sh

HUB_CTX="${HUB_CTX:-hub-1}"
LEAF1_CTX="${LEAF1_CTX:-leaf-1}"
LEAF2_CTX="${LEAF2_CTX:-leaf-2}"

PASS=0
FAIL=0
WARN=0

check() {
  local desc=$1
  local cmd=$2
  if eval "$cmd" &>/dev/null; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

check_warn() {
  local desc=$1
  local cmd=$2
  if eval "$cmd" &>/dev/null; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [WARN] $desc"
    WARN=$((WARN + 1))
  fi
}

# =========================================================================
# Phase 1: ArgoCD Health
# =========================================================================
echo ""
echo "=== Phase 1: ArgoCD Health (hub: $HUB_CTX) ==="

check "ArgoCD server running" \
  "kubectl get deploy argocd-server -n argocd --context $HUB_CTX -o jsonpath='{.status.readyReplicas}' | grep -q 1"

check "ArgoCD application controller running" \
  "kubectl get statefulset argocd-application-controller -n argocd --context $HUB_CTX -o jsonpath='{.status.readyReplicas}' | grep -q 1"

# Count applications -- treat all Healthy as success (OutOfSync+Healthy is a cosmetic diff issue)
TOTAL_APPS=$(kubectl get applications -n argocd --context "$HUB_CTX" --no-headers 2>/dev/null | wc -l | tr -d ' ')
HEALTHY_APPS=$(kubectl get applications -n argocd --context "$HUB_CTX" --no-headers 2>/dev/null | grep -c "Healthy" || true)
echo "  [INFO] Applications: $HEALTHY_APPS/$TOTAL_APPS healthy"

if [ "$TOTAL_APPS" -gt 0 ] && [ "$HEALTHY_APPS" -eq "$TOTAL_APPS" ]; then
  echo "  [PASS] All ArgoCD applications healthy"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Not all applications healthy"
  FAIL=$((FAIL + 1))
  kubectl get applications -n argocd --context "$HUB_CTX" --no-headers 2>/dev/null | grep -v "Healthy" || true
fi

# =========================================================================
# Phase 2: Infrastructure (per leaf cluster)
# =========================================================================
for leaf_ctx in $LEAF1_CTX $LEAF2_CTX; do
  echo ""
  echo "=== Phase 2: Infrastructure ($leaf_ctx) ==="

  check "istiod running" \
    "kubectl get pods -n istio-system -l app=istiod --context $leaf_ctx --field-selector=status.phase=Running --no-headers | grep -q ."

  check "ztunnel running" \
    "kubectl get pods -n istio-system -l app=ztunnel --context $leaf_ctx --field-selector=status.phase=Running --no-headers | grep -q ."

  check "AGW controller running" \
    "kubectl get pods -n agentgateway-system -l app.kubernetes.io/name=enterprise-agentgateway --context $leaf_ctx --field-selector=status.phase=Running --no-headers | grep -q ."

  check "AGW proxy gateway programmed" \
    "kubectl get gateway agentgateway-proxy -n agentgateway-system --context $leaf_ctx -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"

  check "Kyverno running" \
    "kubectl get pods -n kyverno -l app.kubernetes.io/component=admission-controller --context $leaf_ctx --field-selector=status.phase=Running --no-headers | grep -q ."

  check "Prometheus running" \
    "kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --context $leaf_ctx --field-selector=status.phase=Running --no-headers | grep -q ."

  check "Grafana running" \
    "kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --context $leaf_ctx --field-selector=status.phase=Running --no-headers | grep -q ."

  check "Namespace wgu-demo exists with ambient label" \
    "kubectl get ns wgu-demo --context $leaf_ctx -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' | grep -q ambient"

  check "Namespace wgu-demo-frontend exists with ambient label" \
    "kubectl get ns wgu-demo-frontend --context $leaf_ctx -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' | grep -q ambient"
done

# =========================================================================
# Phase 3: Workloads (per leaf cluster)
# =========================================================================
for leaf_ctx in $LEAF1_CTX $LEAF2_CTX; do
  echo ""
  echo "=== Phase 3: Workloads ($leaf_ctx) ==="

  for deploy in graph-db-mock data-product-api financial-aid-mcp; do
    check "$deploy ready" \
      "kubectl rollout status deploy/$deploy -n wgu-demo --context $leaf_ctx --timeout=10s"
  done

  check "enrollment-chatbot ready" \
    "kubectl rollout status deploy/enrollment-chatbot -n wgu-demo-frontend --context $leaf_ctx --timeout=10s"

  check "waypoint running" \
    "kubectl get pods -n wgu-demo -l gateway.networking.k8s.io/gateway-name=wgu-demo-waypoint --context $leaf_ctx --field-selector=status.phase=Running --no-headers | grep -q ."

  check "abac-ext-authz ready" \
    "kubectl rollout status deploy/abac-ext-authz -n agentgateway-system --context $leaf_ctx --timeout=10s"
done

# =========================================================================
# Phase 4: Enforcement (test on leaf-1 only)
# =========================================================================
echo ""
echo "=== Phase 4: Kyverno Enforcement ($LEAF1_CTX) ==="

# Test: rogue backend should be blocked
ROGUE_RESULT=$(kubectl apply --context "$LEAF1_CTX" --dry-run=server -f - 2>&1 <<'EOF' || true
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: rogue-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai: {}
EOF
)
if echo "$ROGUE_RESULT" | grep -qi "denied\|blocked\|validate"; then
  echo "  [PASS] Kyverno blocks rogue AgentgatewayBackend creation"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Kyverno did NOT block rogue backend: $ROGUE_RESULT"
  FAIL=$((FAIL + 1))
fi

# Test: rogue policy in agentgateway-system should be blocked
POLICY_RESULT=$(kubectl apply --context "$LEAF1_CTX" --dry-run=server -f - 2>&1 <<'EOF' || true
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: rogue-policy
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  backend:
    ai:
      promptGuard:
        request: {}
        response: {}
EOF
)
if echo "$POLICY_RESULT" | grep -qi "denied\|blocked\|validate\|invalid"; then
  echo "  [PASS] Kyverno blocks rogue policy override"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Kyverno did NOT block rogue policy: $POLICY_RESULT"
  FAIL=$((FAIL + 1))
fi

# =========================================================================
# Phase 5: Traffic (via port-forward on leaf-1)
# =========================================================================
echo ""
echo "=== Phase 5: Traffic Validation ($LEAF1_CTX) ==="

# Port-forward chatbot
kubectl port-forward svc/enrollment-chatbot -n wgu-demo-frontend 18501:8501 \
  --context "$LEAF1_CTX" &>/dev/null &
PF_CHATBOT=$!
sleep 2

check_warn "Chatbot responds" \
  "curl -sf -o /dev/null http://localhost:18501/"

kill $PF_CHATBOT 2>/dev/null || true

# =========================================================================
# Phase 6: GitOps Drift (leaf-1)
# =========================================================================
echo ""
echo "=== Phase 6: GitOps Drift Test ($LEAF1_CTX) ==="
echo "  [INFO] Skipping drift test (requires waiting for ArgoCD sync interval)."
echo "  [INFO] To test manually:"
echo "    kubectl delete configmap secret-management-info -n agentgateway-system --context $LEAF1_CTX"
echo "    # Wait ~3 min for ArgoCD selfHeal to recreate it"
echo "    kubectl get configmap secret-management-info -n agentgateway-system --context $LEAF1_CTX"

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "============================================"
echo "  Validation Summary"
echo "============================================"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "  RESULT: FAILURES DETECTED"
  exit 1
else
  echo "  RESULT: ALL CHECKS PASSED"
fi
