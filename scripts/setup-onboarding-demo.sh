#!/usr/bin/env bash
set -euo pipefail

# AGW Federated GitOps -- Onboarding Demo Setup
# Creates PRs from pre-staged branches for the live demo.
#
# Prerequisites:
#   - gh CLI authenticated
#   - Pre-staged branches pushed to both repos
#
# Usage: ./scripts/setup-onboarding-demo.sh

INFRA_REPO="ably77/agw-federated-infra"
CLUSTER1_REPO="ably77/agw-federated-cluster-1"

echo "=== Setting up onboarding demo PRs ==="

# Tag baseline commits for reset
echo ""
echo "--- Tagging baseline state ---"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER1_DIR="$(cd "$INFRA_DIR/../agw-federated-cluster-1" && pwd)"

pushd "$INFRA_DIR" > /dev/null
INFRA_BASELINE=$(git rev-parse main)
git tag -f onboarding-baseline "$INFRA_BASELINE"
git push origin onboarding-baseline -f
popd > /dev/null

pushd "$CLUSTER1_DIR" > /dev/null
CLUSTER1_BASELINE=$(git rev-parse main)
git tag -f onboarding-baseline "$CLUSTER1_BASELINE"
git push origin onboarding-baseline -f
popd > /dev/null

echo "  Infra baseline:    $INFRA_BASELINE"
echo "  Cluster-1 baseline: $CLUSTER1_BASELINE"

# Create infra PRs
echo ""
echo "--- Creating infra repo PRs ---"

PR1=$(gh pr create --repo "$INFRA_REPO" \
  --base main \
  --head onboarding/01-allow-streaming-namespaces \
  --title "Onboarding: Allow streaming team namespaces" \
  --body "$(cat <<'BODY'
## Platform Team PR 1/2

Grant the streaming team access to deploy into `streaming-backend` and `streaming-frontend` namespaces.

**What this does:** Adds the streaming namespace manifests to the platform base. ArgoCD syncs these to the leaf clusters, creating the namespaces with ambient mesh labels.

**Demo talking point:** Before a developer can deploy anything, the platform team provisions their namespaces. This is the only thing the dev team needs to request -- everything else they do self-service.
BODY
)")
echo "  PR 1: $PR1"

PR2=$(gh pr create --repo "$INFRA_REPO" \
  --base main \
  --head onboarding/02-add-mcp-backend \
  --title "Onboarding: Add analytics MCP backend for streaming team" \
  --body "$(cat <<'BODY'
## Platform Team PR 2/2

Provision a new MCP backend (`analytics-mcp-backend`) that points to the streaming team's analytics service.

**What this does:** Creates an AgentgatewayBackend resource for the MCP (Model Context Protocol) analytics server. This backend is centrally managed -- developers cannot create their own backends (enforced by Kyverno).

The streaming team will use the existing platform-provided `/openai` route for LLM access -- guardrails and rate limits are already active on that route. No additional policy configuration needed.

**Demo talking point:** Backends are the AI model registry -- only the platform team can create them. The streaming team requested an MCP backend for their analytics service. The platform team reviews and provisions it centrally. The shared /openai route already has guardrails -- new teams get them for free.
BODY
)")
echo "  PR 2: $PR2"

# Create cluster-1 PRs
echo ""
echo "--- Creating cluster-1 repo PRs ---"

PR3=$(gh pr create --repo "$CLUSTER1_REPO" \
  --base main \
  --head onboarding/04-deploy-services \
  --title "Streaming team: Deploy application services" \
  --body "$(cat <<'BODY'
## Developer Team PR 1/2

Deploy the Hooli Entertainment Concierge application services.

**Services deployed:**
- `graph-db-mock` -- Mock subscriber data store (streaming-backend, port 8081)
- `data-product-api` -- Subscriber data API (streaming-backend, port 8080)
- `analytics-mcp` -- MCP analytics server (streaming-backend, port 8082)
- `streaming-backend-chatbot` -- Streamlit chatbot UI (streaming-frontend, port 8501)

**Demo talking point:** The developer deploys their application services. This is standard Kubernetes -- nothing agentgateway-specific yet. ArgoCD picks it up, syncs to the cluster, pods come up. But the chatbot can't reach the MCP tools yet because no routes exist.
BODY
)")
echo "  PR 3: $PR3"

PR4=$(gh pr create --repo "$CLUSTER1_REPO" \
  --base main \
  --head onboarding/05-add-routes \
  --title "Streaming team: Add MCP route and ingress" \
  --body "$(cat <<'BODY'
## Developer Team PR 2/2

Wire up the MCP route and ingress for the streaming team.

**Routes added:**
- HTTPRoute `analytics-mcp` -- /analytics-mcp path to platform-provisioned MCP backend
- HTTPRoute `streaming-chatbot-ingress-route` -- subscriber.glootest.com to chatbot
- ReferenceGrants for cross-namespace access

The chatbot uses the platform-provided `/openai` route for LLM access (guardrails already active). The developer only needs to add the MCP route for their analytics tools and the ingress route for user access.

**Demo talking point:** The developer wires up their MCP tools and ingress. They reference the platform-provisioned MCP backend. The LLM route is already provided by the platform with guardrails active. At this point the app is fully functional. Try sending a credit card number -- it gets blocked with zero config from the developer.

**Live test after merge:**
1. Open subscriber.glootest.com (or port-forward to streaming-backend-chatbot:8501)
2. Ask the chatbot a question -- works
3. Try: "My credit card is 4111-1111-1111-1111" -- blocked by guardrails
4. Point out: zero guardrail config from the developer
BODY
)")
echo "  PR 4: $PR4"

echo ""
echo "=== Demo PRs created ==="
echo ""
echo "Merge order:"
echo "  1. $PR1  (infra: namespaces)"
echo "  2. $PR2  (infra: MCP backend)"
echo "  3. $PR3  (dev: services)"
echo "  4. $PR4  (dev: MCP route + ingress)"
echo ""
echo "After merging all PRs, demonstrate Kyverno enforcement with kubectl:"
echo ""
echo "  # Failure Demo 1: Rogue backend"
echo "  kubectl apply --context leaf-1 -f - <<'EOF'"
echo "  apiVersion: agentgateway.dev/v1alpha1"
echo "  kind: AgentgatewayBackend"
echo "  metadata:"
echo "    name: rogue-backend"
echo "    namespace: agentgateway-system"
echo "  spec:"
echo "    ai:"
echo "      provider:"
echo "        anthropic: {}"
echo "  EOF"
echo ""
echo "  # Failure Demo 2: Rogue policy override"
echo "  kubectl apply --context leaf-1 -f - <<'EOF'"
echo "  apiVersion: enterpriseagentgateway.solo.io/v1alpha1"
echo "  kind: EnterpriseAgentgatewayPolicy"
echo "  metadata:"
echo "    name: rogue-policy"
echo "    namespace: agentgateway-system"
echo "  spec:"
echo "    targetRefs:"
echo "    - group: gateway.networking.k8s.io"
echo "      kind: HTTPRoute"
echo "      name: subscriber"
echo "    backend:"
echo "      ai:"
echo "        promptGuard:"
echo "          request:"
echo "          - regex:"
echo "              action: Reject"
echo "              matches:"
echo '              - ".*"'
echo "  EOF"
echo ""
echo "After demo, run: ./scripts/reset-onboarding-demo.sh"
