# Onboarding Demo Runbook

A step-by-step guide for SAs to demo onboarding a second AI application onto the federated agentgateway platform using GitOps.

## Story

The platform is already running with a WGU enrollment chatbot (first tenant). You walk the prospect through onboarding the **Hooli Entertainment Concierge** (streaming-services) as a second tenant. The demo proves:

1. **Platform team controls backends, namespaces, and policies** via the infra git repo
2. **Developers self-service** within guardrails — they deploy services and wire up routes
3. **Global policies automatically apply** — the shared `/openai` route already has guardrails; new teams get them for free
4. **Kyverno enforces boundaries** — developers cannot create backends or override policies

## Prerequisites

- 3 clusters running: hub-1 (ArgoCD), leaf-1, leaf-2
- WGU enrollment app healthy on both leaf clusters
- `gh` CLI authenticated (`gh auth status`)
- `kubectl` access to all 3 clusters
- Onboarding branches pushed to both repos (one-time setup, already done)

## Before the Demo

```bash
cd agw-federated-infra
./scripts/setup-onboarding-demo.sh
```

This creates 4 open PRs and prints them in merge order. Keep the output handy — it has the PR URLs and kubectl commands.

Open three surfaces:
- **GitHub** — the PR list for both repos
- **ArgoCD UI** — `https://<hub-1-argocd>/applications`
- **Terminal** — for kubectl spot-checks

---

## Demo Flow

### Act 1: Platform Team Onboarding (PRs 1-2)

> **Narrative:** "Before a developer touches anything, the platform team prepares the environment. This is a one-time onboarding step."

#### PR 1: Allow streaming team namespaces

Merge the first PR in the **infra repo**.

**What to show:** The diff — streaming namespaces added to `base/namespaces.yaml` with ambient mesh labels.

**Talk track:** "The platform team provisions the streaming team's namespaces. This is the only thing the developer needs to request. Everything else is self-service."

**ArgoCD:** After sync, the `agw-infra-config-leaf-1` app shows the new namespaces created on the cluster. Verify:
```bash
kubectl get ns streaming-backend streaming-frontend --context leaf-1
```

#### PR 2: Add analytics MCP backend

Merge the second PR in the **infra repo**.

**What to show:** The diff — a new `AgentgatewayBackend` resource for the MCP analytics server.

**Talk track:** "Backends are the AI model registry — only the platform team can create them. The streaming team requested an MCP backend for their analytics service. The platform team reviews it, approves it, and provisions it centrally. The shared `/openai` route already has guardrails and rate limits — new teams get them for free."

**ArgoCD:** After sync, run:
```bash
kubectl get agentgatewaybackends -n agentgateway-system --context leaf-1
```
Show the new `analytics-mcp-backend` alongside the existing `openai` and `financial-aid-mcp-backend`.

---

### Act 2: Developer Self-Service (PRs 3-4)

> **Narrative:** "Now the developer takes over. They deploy their app and wire up routing — all through their own git repo, no tickets, no waiting."

#### PR 3: Deploy application services

Merge the first PR in the **cluster-1 repo**.

**What to show:** The diff — four microservices (graph-db-mock, data-product-api, analytics-mcp, streaming-chatbot) with standard Kubernetes manifests.

**Talk track:** "The developer deploys their application services. This is standard Kubernetes — nothing agentgateway-specific yet. ArgoCD picks it up, syncs to the cluster, pods come up."

**ArgoCD:** After sync, show `agw-cluster-leaf-1` synced. Run:
```bash
kubectl get pods -n streaming-backend --context leaf-1
kubectl get pods -n streaming-frontend --context leaf-1
```
All 4 pods running. Point out: "The chatbot is up, but it can't reach the MCP analytics tools yet — no MCP route exists."

#### PR 4: Add MCP route and ingress

Merge the second PR in the **cluster-1 repo**.

**What to show:** The diff — MCP HTTPRoute referencing the platform-provisioned backend, ingress route for user access, ReferenceGrants for cross-namespace routing.

**Talk track:** "The developer wires up their MCP tools and ingress. They reference the platform-provisioned MCP backend — they don't create backends, they just point to them. The LLM route is already provided by the platform with guardrails active. At this point the app is fully functional."

**ArgoCD:** After sync, run:
```bash
kubectl get httproutes.gateway.networking.k8s.io -A --context leaf-1
```
Show the new `analytics-mcp` route alongside the existing routes.

**Live test:** Port-forward to the chatbot (or use ingress):
```bash
kubectl port-forward svc/streaming-backend-chatbot -n streaming-frontend 18502:8501 --context leaf-1
```
Open `http://localhost:18502`:
1. Ask the chatbot a question — it works
2. Try: *"My credit card is 4111-1111-1111-1111"* — **blocked by guardrails**
3. Point out: "Zero guardrail configuration from the developer. The platform team's policies on the shared LLM route applied automatically."

---

### Act 3: Enforcement (Live kubectl)

> **Narrative:** "So what happens if a developer tries to go around the platform team?"

#### Failure 1: Rogue backend

Run in the terminal:
```bash
kubectl apply --context leaf-1 -f - <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: rogue-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      anthropic: {}
EOF
```

**Expected output:**
```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource AgentgatewayBackend/agentgateway-system/rogue-backend was blocked due to the following policies

deny-local-agentgateway-backends:
  deny-manual-backend-creation: Backend resources can only be managed via the infra
    git repo. Contact the platform team to add a new AI backend.
```

**Talk track:** "Kyverno blocks it. Only the platform team's ArgoCD can create backends. The developer gets a clear error message telling them to contact the platform team."

#### Failure 2: Rogue policy override

Run in the terminal:
```bash
kubectl apply --context leaf-1 -f - <<'EOF'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: rogue-policy
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: subscriber
  backend:
    ai:
      promptGuard:
        request:
        - regex:
            action: Reject
            matches:
            - ".*"
EOF
```

**Expected output:**
```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource EnterpriseAgentgatewayPolicy/agentgateway-system/rogue-policy was blocked due to the following policies

deny-agentgateway-policy-override:
  deny-local-policy-in-platform-ns: Policy resources in the agentgateway-system namespace
    can only be managed via the infra git repo.
```

**Talk track:** "Same story for policies. A developer can't bypass the guardrails the platform team set. They can create policies in their own namespaces for app-specific behavior, but they can't touch the platform namespace."

---

### Wrap-Up

> **Key points to land:**
> - Platform team controls the "what" (backends, policies, namespaces) — developers control the "how" (routes, services, deployments)
> - Global policies apply automatically — the shared LLM route has guardrails that cover every team
> - Kyverno enforces the boundary at admission time — not just convention, actual enforcement
> - Everything is GitOps — auditable, reviewable, reversible

---

## After the Demo

```bash
cd agw-federated-infra
./scripts/reset-onboarding-demo.sh
```

This force-resets both repos to baseline, closes any open PRs, cleans up tags, and waits for ArgoCD to prune. Takes about 60 seconds.

Verify with:
```bash
./scripts/validate.sh
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `gh` auth fails | Run `gh auth login` (if GITHUB_TOKEN is set, unset it first) |
| ArgoCD slow to sync | Force refresh: `kubectl -n argocd --context hub-1 patch application <app-name> --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'` |
| PR has merge conflicts | PRs must be merged in order. If out of order, reset and start over. |
| Pods stuck in ImagePullBackOff | Images are on Docker Hub (`ably7/*`). Check internet connectivity. |
| Reset script fails | If tags are missing, manually reset: `cd <repo> && git reset --hard <baseline-sha> && git push origin main --force` |
| AppProject permission error | Ensure the developers AppProject has `namespace: '*'` in destinations (wildcard). Apply from infra repo: `kubectl apply -f argocd/projects/developers.yaml --context hub-1` |
