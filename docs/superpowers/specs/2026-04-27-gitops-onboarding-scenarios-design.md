# GitOps Onboarding Scenarios: Streaming Services Demo

## Overview

A live demo script for Solo.io field engineers / SAs that walks prospects through onboarding a second AI application ("Hooli Entertainment Concierge") onto an existing agentgateway platform managed via federated GitOps. The demo proves that global policies (guardrails, rate limits) are automatically applied by the platform team and that developers have self-service within guardrails enforced by Kyverno admission policies.

## Audience

Solo.io field engineers and SAs performing live demos for prospects.

## Narrative

The platform is already running with the WGU enrollment chatbot (first tenant). The SA onboards the streaming-services app as a second tenant by merging pre-staged PRs one at a time. ArgoCD auto-syncs after each merge. The demo culminates in two "failure moments" where Kyverno blocks the developer from creating backends or overriding policies.

## Design Decisions

- **Second tenant onboarding** (not from-scratch) to showcase multi-tenant governance
- **PR-by-PR flow** — each step is a real GitHub PR the SA merges live
- **`team-streaming/` added to `agw-federated-cluster-1` only** — multi-cluster already proven by WGU
- **Policy inheritance by convention** — platform team explicitly extends guardrail/rate-limit targetRefs to cover the new route (deliberate handshake, not automatic)
- **Mesh policies out of scope** — demo stays focused on agentgateway routing and policy
- **Single reset PR** to return to baseline after the demo

## Repo Structure

### Infra repo (`agw-federated-infra`) — platform team changes

```
base/
  backends/
    analytics-mcp.yaml          # NEW: MCP backend for streaming team
    kustomization.yaml          # UPDATED: add analytics-mcp.yaml
  global-policies/
    guardrails.yaml             # UPDATED: add targetRef for subscriber route
    route-level-rate-limit.yaml # UPDATED: add targetRef + RateLimitConfig for subscriber route
argocd/
  projects/
    developers.yaml             # UPDATED: add streaming-backend/streaming-frontend namespaces
```

### Cluster-1 repo (`agw-federated-cluster-1`) — developer team changes

```
team-streaming/
  kustomization.yaml
  services/
    kustomization.yaml
    namespaces.yaml              # streaming-backend, streaming-frontend (ambient-labeled)
    graph-db-mock.yaml           # SA, Deployment, Service (port 8081)
    data-product-api.yaml        # SA, Deployment, Service (port 8080)
    analytics-mcp.yaml           # SA, Deployment, Service (port 8082)
    streaming-chatbot.yaml       # SA, ClusterRole, ClusterRoleBinding, Deployment, Service (port 8501)
  routes/
    kustomization.yaml
    httproute-openai.yaml        # /openai route referencing shared openai backend
    httproute-mcp.yaml           # /analytics-mcp route referencing platform-provisioned MCP backend
    ingress-routes.yaml          # subscriber.glootest.com -> chatbot
    reference-grant.yaml         # cross-namespace references (agw <-> streaming namespaces)
  policies/
    kustomization.yaml
    chatbot-rbac.yaml            # ClusterRole + binding for demo UI mesh/policy reads
kustomization.yaml               # UPDATED: add team-streaming alongside team-enrollment
```

## PR Sequence

### PR 1 (infra repo): "Allow streaming team namespaces"

**Changes:** Add `streaming-backend` and `streaming-frontend` to the `developers` AppProject destinations in `argocd/projects/developers.yaml`.

**Demo moment:** "Before a developer can deploy anything, the platform team grants access to specific namespaces. This is the only thing the dev team needs to request -- everything else they do self-service."

**ArgoCD effect:** AppProject updates immediately. No workloads yet.

### PR 2 (infra repo): "Add analytics MCP backend for streaming team"

**Changes:** New `base/backends/analytics-mcp.yaml` containing an AgentgatewayBackend pointing to `analytics-mcp.streaming-backend.svc.cluster.local:8082` with StreamableHTTP protocol. Update `base/backends/kustomization.yaml` to include it.

**Demo moment:** "Backends are the AI model registry -- only the platform team can create them. The streaming team requested an MCP backend for their analytics service. The platform team reviews and provisions it centrally."

**ArgoCD effect:** New AgentgatewayBackend synced to leaf clusters.

### PR 3 (infra repo): "Extend guardrails and rate limits to streaming route"

**Changes:**
- `base/global-policies/guardrails.yaml`: Add a second targetRef entry `name: subscriber` alongside existing `name: wgu-enrollment`
- `base/global-policies/route-level-rate-limit.yaml`: Add a new RateLimitConfig (`subscriber-token-limit`) and a new EnterpriseAgentgatewayPolicy (`subscriber-rate-limit`) targeting the `subscriber` HTTPRoute

**Demo moment:** "The platform team extends the same guardrails -- PII detection, prompt injection, credential scanning, token rate limits -- to the new team's route. The developer never has to think about compliance. This is the handshake: the platform team says 'you're covered.'"

**ArgoCD effect:** Policies now target both `wgu-enrollment` and `subscriber` routes.

### PR 4 (cluster-1 repo): "Deploy streaming services"

**Changes:** `team-streaming/services/` with namespaces, four deployments (graph-db-mock, data-product-api, analytics-mcp, streaming-chatbot), services, and service accounts. Root `kustomization.yaml` updated to include `team-streaming`.

**Demo moment:** "The developer deploys their application services. This is standard Kubernetes -- nothing agentgateway-specific yet. ArgoCD picks it up, syncs to the cluster, pods come up."

**ArgoCD effect:** Namespaces created, pods running, but chatbot can't reach the LLM yet (no routes).

### PR 5 (cluster-1 repo): "Add routes and ingress"

**Changes:** `team-streaming/routes/` with HTTPRoutes for OpenAI (`/openai` -> openai backend) and MCP (`/analytics-mcp` -> analytics-mcp-backend), ingress route (`subscriber.glootest.com` -> chatbot:8501), and ReferenceGrants for cross-namespace access.

**Demo moment:** "Now the developer wires up routing. They reference the shared OpenAI backend and their MCP backend -- both provisioned by the platform team. The ReferenceGrant allows cross-namespace references. At this point the app is fully functional and guardrails are already active."

**ArgoCD effect:** Routes attach to the gateway. Chatbot can call the LLM. Guardrails and rate limits are enforced automatically because PR 3 already targeted this route name.

**Live test:** SA opens the chatbot, asks a question (works). Then tries a PII prompt with a credit card number (blocked by guardrails). Points out this protection was zero effort for the developer.

### PR 6 (cluster-1 repo): "Attempt to create a backend -- DENIED"

**Changes:** Developer adds an AgentgatewayBackend resource to their repo (e.g., `team-streaming/routes/rogue-backend.yaml`).

**Demo moment:** "Watch what happens when a developer tries to bring their own LLM backend. Kyverno blocks it at admission -- only ArgoCD's service account from the infra repo can create backends. The developer sees a clear error message telling them to contact the platform team."

**ArgoCD effect:** Sync fails. ArgoCD UI shows the Kyverno denial message: "Backend resources can only be managed via the infra git repo."

### PR 7 (cluster-1 repo): "Attempt to override guardrails -- DENIED"

**Changes:** Developer adds an EnterpriseAgentgatewayPolicy in the `agentgateway-system` namespace to their repo (e.g., `team-streaming/routes/rogue-policy.yaml`).

**Demo moment:** "Same story for policies. A developer can't bypass the guardrails the platform team set. They can create policies in their own namespaces for app-specific behavior, but they can't touch the platform namespace."

**ArgoCD effect:** Sync fails. Kyverno denial: "Policy resources in the agentgateway-system namespace can only be managed via the infra git repo."

### Reset PR (cluster-1 repo): "Reset: remove streaming team resources"

**Changes:** Single PR that reverts all cluster-1 changes (removes `team-streaming/` directory, restores original `kustomization.yaml`). A corresponding reset PR in the infra repo reverts PRs 1-3 (removes analytics-mcp backend, removes streaming targetRefs from policies, removes streaming namespaces from AppProject).

**ArgoCD effect:** Auto-sync with `prune: true` removes all streaming resources from the cluster. Platform returns to baseline with only WGU enrollment running.

## Demo Surfaces

The SA shows three surfaces during the demo:

1. **GitHub** -- merge each PR, show the diff and PR description (which serves as talk track)
2. **ArgoCD UI** -- show the sync status after each merge; highlight new resources appearing or sync failures
3. **The app** -- after PR 5, open the streaming chatbot and demonstrate it working with guardrails active

## Setup and Reset

### Pre-demo setup script (`scripts/setup-onboarding-demo.sh`)

1. Verify the cluster is in baseline state (WGU running, no streaming resources)
2. Create 7 PRs from pre-staged branches in both repos using `gh` CLI
3. Output the PR URLs in merge order for the SA to follow

### Pre-staged branches

Each PR corresponds to a branch containing the incremental changes:

**Infra repo branches:**
- `onboarding/01-allow-streaming-namespaces`
- `onboarding/02-add-mcp-backend`
- `onboarding/03-extend-policies`

**Cluster-1 repo branches:**
- `onboarding/04-deploy-services`
- `onboarding/05-add-routes`
- `onboarding/06-rogue-backend`
- `onboarding/07-rogue-policy`
- `onboarding/reset-cluster`

**Reset branches (both repos):**
- Infra repo: `onboarding/reset-infra`
- Cluster-1 repo: `onboarding/reset-cluster` (listed above)

### Reset script (`scripts/reset-onboarding-demo.sh`)

1. Merge the cluster-1 reset PR first (removes `team-streaming/`, restores `kustomization.yaml`)
2. Wait for ArgoCD to sync and prune streaming workloads
3. Merge the infra reset PR second (removes analytics-mcp backend, reverts policy targetRefs, removes streaming namespaces from AppProject)
4. Wait for ArgoCD to sync and prune platform-level resources
5. Close any remaining open PRs from the demo
6. Verify baseline state restored (only WGU enrollment running)

Order matters: cluster-1 first so workloads referencing the backend/policies are removed before the backend/policies themselves are removed.

### Infra repo reset branch and PR (`onboarding/reset-infra`)

A single PR that reverts all three infra repo changes:
- Remove `streaming-backend` / `streaming-frontend` from `developers` AppProject
- Remove `base/backends/analytics-mcp.yaml` and revert `base/backends/kustomization.yaml`
- Remove `subscriber` targetRef from guardrails and remove streaming rate-limit resources

## Key Resources (source material)

The streaming-services app manifests live at `/Users/alexly-solo/Desktop/solo/solo-github/vertical-agent-demos/streaming-services/k8s/` and serve as the source for the `team-streaming/` directory structure. Key adaptations needed:

- **Backend (`k8s/gateway/backend.yaml`):** NOT copied to cluster repo -- backends are platform-team owned. The `openai` backend already exists in the infra repo; the `analytics-mcp-backend` is added via PR 2.
- **Guardrails (`k8s/gateway/guardrails.yaml`):** NOT copied -- platform team extends existing guardrails via PR 3.
- **Rate limit (`k8s/gateway/rate-limit.yaml`):** NOT copied -- platform team extends existing rate limits via PR 3.
- **Route (`k8s/gateway/route.yaml`):** Adapted into `httproute-openai.yaml` -- references the shared `openai` backend.
- **MCP backend + route (`k8s/gateway/mcp-backend.yaml`):** Route portion adapted into `httproute-mcp.yaml` -- references the platform-provisioned `analytics-mcp-backend`.
- **Services (`k8s/services/*.yaml`):** Copied into `team-streaming/services/` with minor adjustments.
- **Ingress routes (`k8s/gateway/ingress-routes.yaml`):** Adapted into `ingress-routes.yaml` with `subscriber.glootest.com` hostname.
- **Ext-authz (`k8s/gateway/ext-authz.yaml`):** Not included -- out of scope for this demo.
- **Mesh policies (`k8s/mesh/*.yaml`):** Not included -- mesh is out of scope for this demo.
- **Observability (`k8s/observability/`):** Not included -- monitoring is already provided by the platform.
