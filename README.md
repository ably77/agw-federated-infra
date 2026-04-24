# AGW Federated GitOps -- Infra Repo

Platform-team owned repository for the [AGW Federated GitOps Reference Architecture](https://github.com/ably77/agentgateway-federated-gitops-ref-arch).

## What This Repo Contains

- **ArgoCD configuration** -- bootstrap, AppProjects, ApplicationSets
- **Helm values** -- Istio, Enterprise Agentgateway, Kyverno, Prometheus/Grafana
- **Kustomize base** -- backends, global policies, guardrails, mesh, ingress, admission policies, RBAC, observability
- **Kustomize overlays** -- per-leaf-cluster patches (secret refs, endpoints)
- **Scripts** -- install, cluster registration, validation

## Quick Start

```bash
# Prerequisites: 3 clusters (cluster1=hub, cluster2=leaf-1, cluster3=leaf-2)
# Supported platforms: Colima (local k3s), EKS, GKE
export SOLO_TRIAL_LICENSE_KEY=<key>
export OPENAI_API_KEY=<key>

./scripts/install-argocd.sh

# Validate
./scripts/validate.sh
```

## Architecture

```
cluster1 (hub)          cluster2 (leaf-1)       cluster3 (leaf-2)
┌──────────────┐        ┌──────────────┐        ┌──────────────┐
│   ArgoCD     │───────>│  Istio       │        │  Istio       │
│   AppSets    │───────>│  AGW CP+DP   │        │  AGW CP+DP   │
│              │───────>│  Kyverno     │        │  Kyverno     │
│              │───────>│  Monitoring  │        │  Monitoring  │
│              │───────>│  Workloads   │        │  Workloads   │
└──────────────┘        └──────────────┘        └──────────────┘
```

## Sync Wave Order

| Wave | Component |
|------|-----------|
| 1 | Gateway API CRDs + Istio base |
| 2 | Istio CNI |
| 3 | istiod |
| 4 | ztunnel |
| 5 | AGW CRDs |
| 6 | AGW controller |
| 7 | Kyverno |
| 8 | Prometheus/Grafana |
| 10 | Infra config (Kustomize) |
| 20 | Developer workloads |

## Platform Support

The install scripts auto-detect the platform from kubeconfig:

| Platform | Cluster Discovery | Access |
|----------|------------------|--------|
| Colima | VM IP detection via `colima ssh` | Port-forward |
| EKS | Kubeconfig server URL (direct) | LoadBalancer / port-forward |
| GKE | Kubeconfig server URL (direct) | LoadBalancer / port-forward |

## Related Repos

- [agw-federated-cluster-1](https://github.com/ably77/agw-federated-cluster-1) -- Developer workloads for leaf-1
- [agw-federated-cluster-2](https://github.com/ably77/agw-federated-cluster-2) -- Developer workloads for leaf-2
- [Reference Architecture](https://github.com/ably77/agentgateway-federated-gitops-ref-arch) -- Design document
