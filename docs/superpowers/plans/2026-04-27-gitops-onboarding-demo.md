# GitOps Onboarding Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a PR-by-PR live demo that onboards the streaming-services app as a second tenant onto the federated agentgateway platform, showcasing self-service within platform guardrails.

**Architecture:** Two repos are modified: the infra repo (platform team, 3 PRs) and the cluster-1 repo (developer team, 4 PRs + 2 failure PRs). Each PR lives on a pre-staged branch. A setup script creates the PRs and a reset script reverts everything.

**Tech Stack:** Kustomize, ArgoCD ApplicationSets, Kubernetes Gateway API, Enterprise Agentgateway CRDs, Kyverno ClusterPolicies, GitHub CLI (`gh`)

---

## File Map

### Infra repo (`agw-federated-infra`)

| Action | File | Purpose |
|--------|------|---------|
| Modify | `argocd/projects/developers.yaml` | Add streaming namespaces to destinations |
| Create | `base/backends/analytics-mcp.yaml` | MCP backend for streaming team |
| Modify | `base/backends/kustomization.yaml` | Include analytics-mcp.yaml |
| Modify | `base/global-policies/guardrails.yaml` | Add subscriber targetRef |
| Modify | `base/global-policies/route-level-rate-limit.yaml` | Add subscriber rate limit resources |
| Create | `scripts/setup-onboarding-demo.sh` | Create PRs from pre-staged branches |
| Create | `scripts/reset-onboarding-demo.sh` | Revert demo to baseline |

### Cluster-1 repo (`agw-federated-cluster-1`)

| Action | File | Purpose |
|--------|------|---------|
| Modify | `kustomization.yaml` | Add team-streaming |
| Create | `team-streaming/kustomization.yaml` | Top-level kustomization |
| Create | `team-streaming/services/kustomization.yaml` | Service resources list |
| Create | `team-streaming/services/namespaces.yaml` | streaming-backend, streaming-frontend |
| Create | `team-streaming/services/graph-db-mock.yaml` | SA, Deployment, Service |
| Create | `team-streaming/services/data-product-api.yaml` | SA, Deployment, Service |
| Create | `team-streaming/services/analytics-mcp.yaml` | SA, Deployment, Service |
| Create | `team-streaming/services/streaming-chatbot.yaml` | SA, ClusterRole, Binding, Deployment, Service |
| Create | `team-streaming/routes/kustomization.yaml` | Route resources list |
| Create | `team-streaming/routes/httproute-openai.yaml` | /openai -> shared openai backend |
| Create | `team-streaming/routes/httproute-mcp.yaml` | /analytics-mcp -> platform MCP backend |
| Create | `team-streaming/routes/ingress-routes.yaml` | subscriber.glootest.com -> chatbot |
| Create | `team-streaming/routes/reference-grant.yaml` | Cross-namespace grants |
| Create | `team-streaming/policies/kustomization.yaml` | Policy resources list |
| Create | `team-streaming/policies/chatbot-rbac.yaml` | ClusterRole + binding for demo UI |
| Create | `team-streaming/routes/rogue-backend.yaml` | Kyverno denial demo (PR 6 only) |
| Create | `team-streaming/routes/rogue-policy.yaml` | Kyverno denial demo (PR 7 only) |

---

## Task 1: Create platform PR branches in infra repo

**Repo:** `agw-federated-infra`

All three platform PRs are built as branches off the current `main`.

- [ ] **Step 1: Create branch `onboarding/01-allow-streaming-namespaces`**

```bash
cd /Users/alexly-solo/Desktop/solo/solo-github/agentgateway-gitops/agw-federated-infra
git checkout main
git checkout -b onboarding/01-allow-streaming-namespaces
```

- [ ] **Step 2: Modify `argocd/projects/developers.yaml`**

Add `streaming-backend` and `streaming-frontend` to the destinations list. The full file should be:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: developers
  namespace: argocd
spec:
  description: Developer teams -- workloads and routes
  sourceRepos:
    - https://github.com/ably77/agw-federated-cluster-1.git
    - https://github.com/ably77/agw-federated-cluster-2.git
  destinations:
    - namespace: wgu-demo
      server: '*'
    - namespace: wgu-demo-frontend
      server: '*'
    - namespace: streaming-backend
      server: '*'
    - namespace: streaming-frontend
      server: '*'
    - namespace: agentgateway-system
      server: '*'
    - namespace: monitoring
      server: '*'
  clusterResourceWhitelist:
    - group: rbac.authorization.k8s.io
      kind: ClusterRole
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```

- [ ] **Step 3: Commit and return to main**

```bash
git add argocd/projects/developers.yaml
git commit -m "Allow streaming team namespaces in developers AppProject"
git checkout main
```

- [ ] **Step 4: Create branch `onboarding/02-add-mcp-backend`**

```bash
git checkout -b onboarding/02-add-mcp-backend
```

- [ ] **Step 5: Cherry-pick the namespace change so this branch builds on PR 1**

```bash
git cherry-pick onboarding/01-allow-streaming-namespaces
```

- [ ] **Step 6: Create `base/backends/analytics-mcp.yaml`**

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: analytics-mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: analytics-mcp-target
      static:
        host: analytics-mcp.streaming-backend.svc.cluster.local
        port: 8082
        protocol: StreamableHTTP
```

- [ ] **Step 7: Update `base/backends/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - openai.yaml
  - mcp-backend.yaml
  - analytics-mcp.yaml
```

- [ ] **Step 8: Commit and return to main**

```bash
git add base/backends/analytics-mcp.yaml base/backends/kustomization.yaml
git commit -m "Add analytics MCP backend for streaming team"
git checkout main
```

- [ ] **Step 9: Create branch `onboarding/03-extend-policies`**

```bash
git checkout -b onboarding/03-extend-policies
```

- [ ] **Step 10: Cherry-pick both prior commits**

```bash
git cherry-pick onboarding/01-allow-streaming-namespaces
git cherry-pick onboarding/02-add-mcp-backend
```

- [ ] **Step 11: Update `base/global-policies/guardrails.yaml`**

Add a second `targetRefs` entry. The `spec.targetRefs` section should be:

```yaml
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: wgu-enrollment
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: subscriber
```

Leave the rest of the file unchanged.

- [ ] **Step 12: Update `base/global-policies/route-level-rate-limit.yaml`**

Append the streaming team's rate limit resources after the existing content. The full file should be:

```yaml
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: wgu-enrollment-token-limit
  namespace: agentgateway-system
spec:
  raw:
    descriptors:
    - key: generic_key
      value: wgu-enrollment
      rateLimit:
        requestsPerUnit: 100000
        unit: HOUR
    rateLimits:
    - actions:
      - genericKey:
          descriptorValue: wgu-enrollment
      type: TOKEN
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: wgu-enrollment-rate-limit
  namespace: agentgateway-system
spec:
  targetRefs:
  - name: wgu-enrollment
    group: gateway.networking.k8s.io
    kind: HTTPRoute
  traffic:
    entRateLimit:
      global:
        rateLimitConfigRefs:
        - name: wgu-enrollment-token-limit
---
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: subscriber-token-limit
  namespace: agentgateway-system
spec:
  raw:
    descriptors:
    - key: generic_key
      value: subscriber
      rateLimit:
        requestsPerUnit: 100000
        unit: HOUR
    rateLimits:
    - actions:
      - genericKey:
          descriptorValue: subscriber
      type: TOKEN
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: subscriber-rate-limit
  namespace: agentgateway-system
spec:
  targetRefs:
  - name: subscriber
    group: gateway.networking.k8s.io
    kind: HTTPRoute
  traffic:
    entRateLimit:
      global:
        rateLimitConfigRefs:
        - name: subscriber-token-limit
```

- [ ] **Step 13: Commit and return to main**

```bash
git add base/global-policies/guardrails.yaml base/global-policies/route-level-rate-limit.yaml
git commit -m "Extend guardrails and rate limits to streaming route"
git checkout main
```

- [ ] **Step 14: Create infra reset branch `onboarding/reset-infra`**

This branch is based on the current `main` (before any onboarding changes) and stays identical to `main`. When merged after the demo, it effectively reverts all changes because ArgoCD syncs from `main`.

```bash
git checkout -b onboarding/reset-infra
git checkout main
```

Note: The reset branch for the infra repo is just `main` itself. The reset script will revert the merged PRs by reverting the merge commits on `main`, then force-pushing. Alternatively, the setup script can tag the baseline commit for easy revert.

- [ ] **Step 15: Push all infra branches**

```bash
git push origin onboarding/01-allow-streaming-namespaces
git push origin onboarding/02-add-mcp-backend
git push origin onboarding/03-extend-policies
```

- [ ] **Step 16: Commit**

No files changed on `main` — the branches are the deliverables.

---

## Task 2: Create developer PR branches in cluster-1 repo

**Repo:** `agw-federated-cluster-1`

- [ ] **Step 1: Create branch `onboarding/04-deploy-services`**

```bash
cd /Users/alexly-solo/Desktop/solo/solo-github/agentgateway-gitops/agw-federated-cluster-1
git checkout main
git checkout -b onboarding/04-deploy-services
```

- [ ] **Step 2: Create `team-streaming/services/namespaces.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: streaming-backend
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: Namespace
metadata:
  name: streaming-frontend
  labels:
    istio.io/dataplane-mode: ambient
```

- [ ] **Step 3: Create `team-streaming/services/graph-db-mock.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: graph-db-mock
  namespace: streaming-backend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: graph-db-mock
  namespace: streaming-backend
  labels:
    app: graph-db-mock
spec:
  replicas: 1
  selector:
    matchLabels:
      app: graph-db-mock
  template:
    metadata:
      labels:
        app: graph-db-mock
    spec:
      serviceAccountName: graph-db-mock
      containers:
      - name: graph-db-mock
        image: ably7/streaming-backend-graph-db-mock:0.0.1
        imagePullPolicy: Always
        ports:
        - containerPort: 8081
          name: http
        readinessProbe:
          httpGet:
            path: /health
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: graph-db-mock
  namespace: streaming-backend
  labels:
    app: graph-db-mock
spec:
  selector:
    app: graph-db-mock
  ports:
  - name: http
    port: 8081
    targetPort: 8081
```

- [ ] **Step 4: Create `team-streaming/services/data-product-api.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: data-product-api
  namespace: streaming-backend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: data-product-api
  namespace: streaming-backend
  labels:
    app: data-product-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: data-product-api
  template:
    metadata:
      labels:
        app: data-product-api
    spec:
      serviceAccountName: data-product-api
      containers:
      - name: data-product-api
        image: ably7/streaming-backend-data-product-api:0.0.1
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: GRAPH_DB_URL
          value: "http://graph-db-mock.streaming-backend.svc.cluster.local:8081"
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: data-product-api
  namespace: streaming-backend
  labels:
    app: data-product-api
    solo.io/service-scope: global
  annotations:
    networking.istio.io/traffic-distribution: PreferNetwork
spec:
  selector:
    app: data-product-api
  ports:
  - name: http
    port: 8080
    targetPort: 8080
```

- [ ] **Step 5: Create `team-streaming/services/analytics-mcp.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: analytics-mcp
  namespace: streaming-backend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: analytics-mcp
  namespace: streaming-backend
  labels:
    app: analytics-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: analytics-mcp
  template:
    metadata:
      labels:
        app: analytics-mcp
    spec:
      serviceAccountName: analytics-mcp
      containers:
      - name: analytics-mcp
        image: ably7/streaming-backend-analytics-mcp:0.0.1
        imagePullPolicy: Always
        ports:
        - containerPort: 8082
          name: http
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: analytics-mcp
  namespace: streaming-backend
  labels:
    app: analytics-mcp
spec:
  selector:
    app: analytics-mcp
  ports:
  - name: http
    port: 8082
    targetPort: 8082
```

- [ ] **Step 6: Create `team-streaming/services/streaming-chatbot.yaml`**

Note: RBAC (ClusterRole + ClusterRoleBinding) lives in `team-streaming/policies/chatbot-rbac.yaml` (added in PR 5), matching the `team-enrollment` pattern. This file contains only the ServiceAccount, Deployment, and Service.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: streaming-backend-chatbot
  namespace: streaming-frontend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: streaming-backend-chatbot
  namespace: streaming-frontend
  labels:
    app: streaming-backend-chatbot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: streaming-backend-chatbot
  template:
    metadata:
      labels:
        app: streaming-backend-chatbot
    spec:
      serviceAccountName: streaming-backend-chatbot
      containers:
      - name: streaming-backend-chatbot
        image: ably7/streaming-backend-chatbot:0.0.2
        imagePullPolicy: Always
        ports:
        - containerPort: 8501
          name: http
        env:
        - name: GATEWAY_IP
          value: "agentgateway-proxy.agentgateway-system.svc.cluster.local"
        - name: GATEWAY_PORT
          value: "8080"
        - name: GATEWAY_PROTOCOL
          value: "http"
        - name: ORG_NAME
          value: "Hooli"
        - name: ORG_SHORT
          value: "Hooli"
        - name: APP_TITLE
          value: "Hooli Entertainment Concierge"
        - name: DATA_PRODUCT_URL
          value: "http://data-product-api.streaming-backend.mesh.internal:8080"
        - name: GRAPH_DB_URL
          value: "http://graph-db-mock.streaming-backend.svc.cluster.local:8081"
        - name: NS_BACKEND
          value: "streaming-backend"
        - name: NS_FRONTEND
          value: "streaming-frontend"
        - name: MCP_URL
          value: "http://agentgateway-proxy.agentgateway-system.svc.cluster.local:8080/analytics-mcp"
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: streaming-backend-chatbot
  namespace: streaming-frontend
  labels:
    app: streaming-backend-chatbot
spec:
  type: ClusterIP
  selector:
    app: streaming-backend-chatbot
  ports:
  - name: http
    port: 8501
    targetPort: 8501
```

- [ ] **Step 7: Create `team-streaming/services/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespaces.yaml
  - graph-db-mock.yaml
  - data-product-api.yaml
  - analytics-mcp.yaml
  - streaming-chatbot.yaml
```

- [ ] **Step 8: Create `team-streaming/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - services
```

Note: `routes` and `policies` are NOT included yet — they come in PR 5.

- [ ] **Step 9: Update root `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - team-enrollment
  - team-streaming
```

- [ ] **Step 10: Commit and return to main**

```bash
git add team-streaming/ kustomization.yaml
git commit -m "Deploy streaming services (namespaces, deployments, services)"
git checkout main
```

---

## Task 3: Create route and ingress branch in cluster-1 repo

**Repo:** `agw-federated-cluster-1`

- [ ] **Step 1: Create branch `onboarding/05-add-routes` from `onboarding/04-deploy-services`**

```bash
git checkout onboarding/04-deploy-services
git checkout -b onboarding/05-add-routes
```

- [ ] **Step 2: Create `team-streaming/routes/httproute-openai.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: subscriber
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /openai
    backendRefs:
    - name: openai
      group: agentgateway.dev
      kind: AgentgatewayBackend
    timeouts:
      request: "120s"
```

- [ ] **Step 3: Create `team-streaming/routes/httproute-mcp.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: analytics-mcp
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /analytics-mcp
    backendRefs:
    - name: analytics-mcp-backend
      group: agentgateway.dev
      kind: AgentgatewayBackend
    timeouts:
      request: "0s"
```

- [ ] **Step 4: Create `team-streaming/routes/ingress-routes.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: streaming-chatbot-ingress-route
  namespace: streaming-frontend
spec:
  hostnames:
  - "subscriber.glootest.com"
  parentRefs:
  - name: ingress
    namespace: agentgateway-system
  rules:
  - backendRefs:
    - name: streaming-backend-chatbot
      port: 8501
    matches:
    - path:
        type: PathPrefix
        value: /
```

- [ ] **Step 5: Create `team-streaming/routes/reference-grant.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-agw-to-streaming-backend
  namespace: streaming-backend
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: agentgateway-system
  to:
  - group: ""
    kind: Service
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-streaming-frontend-to-agw
  namespace: agentgateway-system
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: streaming-frontend
  to:
  - group: gateway.networking.k8s.io
    kind: Gateway
```

- [ ] **Step 6: Create `team-streaming/routes/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - httproute-openai.yaml
  - httproute-mcp.yaml
  - ingress-routes.yaml
  - reference-grant.yaml
```

- [ ] **Step 7: Create `team-streaming/policies/chatbot-rbac.yaml`**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: streaming-chatbot-mesh-demo
rules:
- apiGroups: ["security.istio.io"]
  resources: ["authorizationpolicies"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  verbs: ["get", "update", "patch"]
- apiGroups: ["networking.istio.io"]
  resources: ["serviceentries"]
  verbs: ["get", "list"]
- apiGroups: ["enterpriseagentgateway.solo.io"]
  resources: ["enterpriseagentgatewaypolicies"]
  verbs: ["get", "list", "create", "apply", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: streaming-chatbot-mesh-demo
subjects:
- kind: ServiceAccount
  name: streaming-backend-chatbot
  namespace: streaming-frontend
roleRef:
  kind: ClusterRole
  name: streaming-chatbot-mesh-demo
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 8: Create `team-streaming/policies/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - chatbot-rbac.yaml
```

- [ ] **Step 9: Update `team-streaming/kustomization.yaml` to include routes and policies**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - services
  - routes
  - policies
```

- [ ] **Step 10: Commit and return to main**

```bash
git add team-streaming/routes/ team-streaming/policies/ team-streaming/kustomization.yaml
git commit -m "Add routes, ingress, and RBAC for streaming team"
git checkout main
```

---

## Task 4: Create Kyverno denial branches in cluster-1 repo

**Repo:** `agw-federated-cluster-1`

- [ ] **Step 1: Create branch `onboarding/06-rogue-backend` from `onboarding/05-add-routes`**

```bash
git checkout onboarding/05-add-routes
git checkout -b onboarding/06-rogue-backend
```

- [ ] **Step 2: Create `team-streaming/routes/rogue-backend.yaml`**

```yaml
# A developer attempts to bring their own LLM backend.
# This will be DENIED by the deny-local-agentgateway-backends Kyverno policy.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: streaming-team-anthropic
  namespace: agentgateway-system
spec:
  ai:
    provider:
      anthropic: {}
  policies:
    auth:
      secretRef:
        name: streaming-anthropic-secret
```

- [ ] **Step 3: Update `team-streaming/routes/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - httproute-openai.yaml
  - httproute-mcp.yaml
  - ingress-routes.yaml
  - reference-grant.yaml
  - rogue-backend.yaml
```

- [ ] **Step 4: Commit and return to main**

```bash
git add team-streaming/routes/rogue-backend.yaml team-streaming/routes/kustomization.yaml
git commit -m "Add Anthropic backend for streaming team"
git checkout main
```

- [ ] **Step 5: Create branch `onboarding/07-rogue-policy` from `onboarding/05-add-routes`**

Note: This branches from `05-add-routes`, NOT from `06-rogue-backend`. In the demo, the SA reverts PR 6 before merging PR 7. But for simplicity, these can also be built as independent branches from `05-add-routes`.

```bash
git checkout onboarding/05-add-routes
git checkout -b onboarding/07-rogue-policy
```

- [ ] **Step 6: Create `team-streaming/routes/rogue-policy.yaml`**

```yaml
# A developer attempts to weaken guardrails on the platform gateway.
# This will be DENIED by the deny-agentgateway-policy-override Kyverno policy.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: streaming-disable-guardrails
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: subscriber
  backend:
    ai:
      promptGuard:
        request: []
        response: []
```

- [ ] **Step 7: Update `team-streaming/routes/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - httproute-openai.yaml
  - httproute-mcp.yaml
  - ingress-routes.yaml
  - reference-grant.yaml
  - rogue-policy.yaml
```

- [ ] **Step 8: Commit and return to main**

```bash
git add team-streaming/routes/rogue-policy.yaml team-streaming/routes/kustomization.yaml
git commit -m "Override guardrails for streaming route"
git checkout main
```

---

## Task 5: Create reset branch in cluster-1 repo

**Repo:** `agw-federated-cluster-1`

The reset branch is based on the current `main` (no streaming resources). When merged, ArgoCD prunes everything.

- [ ] **Step 1: Create branch `onboarding/reset-cluster`**

This is a no-op branch — it matches `main` exactly. The purpose is to have a PR ready that, when merged after the demo, reverts `main` to its original state.

Actually, the reset needs to be a bit more nuanced. After PRs 4 and 5 are merged, `main` contains the streaming resources. The reset PR should revert those changes. The simplest approach: create the reset branch from current `main` (before any onboarding merges), so it serves as the "known good" state.

```bash
git checkout main
git checkout -b onboarding/reset-cluster
```

The setup script will create the reset PR *after* all onboarding PRs are merged during the demo. Alternatively, the reset script simply reverts the merge commits.

- [ ] **Step 2: Push all cluster-1 branches**

```bash
git push origin onboarding/04-deploy-services
git push origin onboarding/05-add-routes
git push origin onboarding/06-rogue-backend
git push origin onboarding/07-rogue-policy
git push origin onboarding/reset-cluster
```

---

## Task 6: Create setup script

**Repo:** `agw-federated-infra`
**File:** `scripts/setup-onboarding-demo.sh`

- [ ] **Step 1: Create the script**

```bash
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
## Platform Team PR 1/3

Grant the streaming team access to deploy into `streaming-backend` and `streaming-frontend` namespaces.

**What this does:** Adds two new namespace destinations to the `developers` AppProject. Without this, ArgoCD will refuse to sync any resources the streaming team deploys to these namespaces.

**Demo talking point:** Before a developer can deploy anything, the platform team grants access to specific namespaces. This is the only thing the dev team needs to request -- everything else they do self-service.
BODY
)")
echo "  PR 1: $PR1"

PR2=$(gh pr create --repo "$INFRA_REPO" \
  --base main \
  --head onboarding/02-add-mcp-backend \
  --title "Onboarding: Add analytics MCP backend for streaming team" \
  --body "$(cat <<'BODY'
## Platform Team PR 2/3

Provision a new MCP backend (`analytics-mcp-backend`) that points to the streaming team's analytics service.

**What this does:** Creates an AgentgatewayBackend resource for the MCP (Model Context Protocol) analytics server. This backend is centrally managed -- developers cannot create their own backends (enforced by Kyverno).

**Demo talking point:** Backends are the AI model registry -- only the platform team can create them. The streaming team requested an MCP backend for their analytics service. The platform team reviews and provisions it centrally.
BODY
)")
echo "  PR 2: $PR2"

PR3=$(gh pr create --repo "$INFRA_REPO" \
  --base main \
  --head onboarding/03-extend-policies \
  --title "Onboarding: Extend guardrails and rate limits to streaming route" \
  --body "$(cat <<'BODY'
## Platform Team PR 3/3

Extend the existing PII/injection guardrails and token rate limits to cover the streaming team's `subscriber` route.

**What this does:**
- Adds `subscriber` as a targetRef on the existing guardrails policy (PII detection, prompt injection, credential scanning)
- Creates a new RateLimitConfig and EnterpriseAgentgatewayPolicy for token-based rate limiting on the streaming route

**Demo talking point:** The platform team extends the same guardrails -- PII detection, prompt injection, credential scanning, token rate limits -- to the new team's route. The developer never has to think about compliance. This is the handshake: the platform team says "you're covered."
BODY
)")
echo "  PR 3: $PR3"

# Create cluster-1 PRs
echo ""
echo "--- Creating cluster-1 repo PRs ---"

PR4=$(gh pr create --repo "$CLUSTER1_REPO" \
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

**Demo talking point:** The developer deploys their application services. This is standard Kubernetes -- nothing agentgateway-specific yet. ArgoCD picks it up, syncs to the cluster, pods come up. But the chatbot can't reach the LLM yet because no routes exist.
BODY
)")
echo "  PR 4: $PR4"

PR5=$(gh pr create --repo "$CLUSTER1_REPO" \
  --base main \
  --head onboarding/05-add-routes \
  --title "Streaming team: Add routes and ingress" \
  --body "$(cat <<'BODY'
## Developer Team PR 2/2

Wire up agentgateway routing and ingress for the streaming team.

**Routes added:**
- HTTPRoute `subscriber` -- /openai path to shared OpenAI backend (120s timeout)
- HTTPRoute `analytics-mcp` -- /analytics-mcp path to platform-provisioned MCP backend
- HTTPRoute `streaming-chatbot-ingress-route` -- subscriber.glootest.com to chatbot
- ReferenceGrants for cross-namespace access

**Demo talking point:** The developer wires up routing. They reference the shared OpenAI backend and their MCP backend -- both provisioned by the platform team. At this point the app is fully functional and guardrails are already active. Try sending a credit card number -- it gets blocked.

**Live test after merge:**
1. Open subscriber.glootest.com (or port-forward)
2. Ask the chatbot a question -- works
3. Try: "My credit card is 4111-1111-1111-1111" -- blocked by guardrails
4. Point out: zero guardrail config from the developer
BODY
)")
echo "  PR 5: $PR5"

PR6=$(gh pr create --repo "$CLUSTER1_REPO" \
  --base main \
  --head onboarding/06-rogue-backend \
  --title "Streaming team: Add Anthropic backend" \
  --body "$(cat <<'BODY'
## Failure Demo 1: Rogue Backend

A developer attempts to bring their own Anthropic LLM backend.

**Expected result:** ArgoCD sync FAILS. Kyverno blocks the AgentgatewayBackend creation with: "Backend resources can only be managed via the infra git repo. Contact the platform team to add a new AI backend."

**Demo talking point:** Watch what happens when a developer tries to bring their own LLM backend. Kyverno blocks it at admission -- only ArgoCD's service account from the infra repo can create backends. Show the error in the ArgoCD UI.

**After demo:** Revert this PR before proceeding to PR 7.
BODY
)")
echo "  PR 6: $PR6"

PR7=$(gh pr create --repo "$CLUSTER1_REPO" \
  --base main \
  --head onboarding/07-rogue-policy \
  --title "Streaming team: Disable guardrails on our route" \
  --body "$(cat <<'BODY'
## Failure Demo 2: Rogue Policy Override

A developer attempts to create an EnterpriseAgentgatewayPolicy in the agentgateway-system namespace to disable guardrails on their route.

**Expected result:** ArgoCD sync FAILS. Kyverno blocks the policy creation with: "Policy resources in the agentgateway-system namespace can only be managed via the infra git repo."

**Demo talking point:** Same story for policies. A developer can't bypass the guardrails the platform team set. They can create policies in their own namespaces for app-specific behavior, but they can't touch the platform namespace.

**After demo:** Revert this PR, then run the reset script.
BODY
)")
echo "  PR 7: $PR7"

echo ""
echo "=== Demo PRs created ==="
echo ""
echo "Merge order:"
echo "  1. $PR1"
echo "  2. $PR2"
echo "  3. $PR3"
echo "  4. $PR4"
echo "  5. $PR5"
echo "  6. $PR6  (sync will FAIL -- Kyverno denial)"
echo "  7. $PR7  (sync will FAIL -- Kyverno denial)"
echo ""
echo "After demo, run: ./scripts/reset-onboarding-demo.sh"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/setup-onboarding-demo.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/setup-onboarding-demo.sh
git commit -m "Add onboarding demo setup script"
```

---

## Task 7: Create reset script

**Repo:** `agw-federated-infra`
**File:** `scripts/reset-onboarding-demo.sh`

- [ ] **Step 1: Create the script**

```bash
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
  git revert --no-commit "${CLUSTER1_BASELINE}..HEAD"
  git commit -m "Reset: remove streaming team resources

Reverts all onboarding demo changes to restore baseline state."
  git push origin main
  echo "  Cluster-1 reverted to baseline"
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
  git revert --no-commit "${INFRA_BASELINE}..HEAD"
  git commit -m "Reset: remove streaming team platform config

Reverts onboarding demo changes: analytics-mcp backend, streaming policy
targetRefs, streaming namespace grants."
  git push origin main
  echo "  Infra reverted to baseline"
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/reset-onboarding-demo.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/reset-onboarding-demo.sh
git commit -m "Add onboarding demo reset script"
```

---

## Task 8: Validate kustomize builds

- [ ] **Step 1: Validate infra base still builds with new backend**

Test on the `onboarding/03-extend-policies` branch (which includes all three infra PRs):

```bash
cd /Users/alexly-solo/Desktop/solo/solo-github/agentgateway-gitops/agw-federated-infra
git checkout onboarding/03-extend-policies
kubectl kustomize overlays/leaf-1
```

Expected: YAML output includes `analytics-mcp-backend`, both guardrail targetRefs, and both rate limit configs. No errors.

```bash
git checkout main
```

- [ ] **Step 2: Validate cluster-1 builds with streaming services**

Test on the `onboarding/04-deploy-services` branch:

```bash
cd /Users/alexly-solo/Desktop/solo/solo-github/agentgateway-gitops/agw-federated-cluster-1
git checkout onboarding/04-deploy-services
kubectl kustomize .
```

Expected: YAML output includes streaming namespaces, all four deployments, services, and service accounts. No errors.

```bash
git checkout main
```

- [ ] **Step 3: Validate cluster-1 builds with routes**

Test on the `onboarding/05-add-routes` branch:

```bash
git checkout onboarding/05-add-routes
kubectl kustomize .
```

Expected: YAML output includes everything from step 2 plus HTTPRoutes, ingress routes, ReferenceGrants, and RBAC. No errors.

```bash
git checkout main
```

- [ ] **Step 4: Validate rogue branches build**

```bash
git checkout onboarding/06-rogue-backend
kubectl kustomize .
git checkout main

git checkout onboarding/07-rogue-policy
kubectl kustomize .
git checkout main
```

Expected: Both produce valid YAML (the denial happens at admission time, not at kustomize build time).

- [ ] **Step 5: Commit**

No changes needed — this is validation only.

---

## Task 9: Push scripts and final commit

- [ ] **Step 1: Ensure scripts are on main in the infra repo**

```bash
cd /Users/alexly-solo/Desktop/solo/solo-github/agentgateway-gitops/agw-federated-infra
git status
```

Verify `scripts/setup-onboarding-demo.sh` and `scripts/reset-onboarding-demo.sh` are committed on `main`.

- [ ] **Step 2: Push main with scripts**

```bash
git push origin main
```

- [ ] **Step 3: Push all branches (if not already pushed)**

Infra repo:
```bash
git push origin onboarding/01-allow-streaming-namespaces
git push origin onboarding/02-add-mcp-backend
git push origin onboarding/03-extend-policies
```

Cluster-1 repo:
```bash
cd /Users/alexly-solo/Desktop/solo/solo-github/agentgateway-gitops/agw-federated-cluster-1
git push origin onboarding/04-deploy-services
git push origin onboarding/05-add-routes
git push origin onboarding/06-rogue-backend
git push origin onboarding/07-rogue-policy
git push origin onboarding/reset-cluster
```

- [ ] **Step 4: Run setup script to verify it works**

```bash
cd /Users/alexly-solo/Desktop/solo/solo-github/agentgateway-gitops/agw-federated-infra
./scripts/setup-onboarding-demo.sh
```

Expected: 7 PRs created, URLs printed in merge order.
