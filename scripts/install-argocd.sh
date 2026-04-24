#!/usr/bin/env bash
set -euo pipefail

# AGW Federated GitOps -- ArgoCD Bootstrap Script
# Installs ArgoCD on the hub cluster and registers leaf clusters.
#
# Supported platforms: Colima (local k3s), EKS, GKE
# Platform is auto-detected from kubeconfig API server URLs.
#
# Prerequisites:
#   - 3 clusters: 1 hub + 2 leaf (contexts configurable via env vars)
#   - SOLO_TRIAL_LICENSE_KEY and OPENAI_API_KEY environment variables set
#   - helm, kubectl, argocd CLI installed
#   - For Colima: colima CLI installed
#
# Usage:
#   export SOLO_TRIAL_LICENSE_KEY=<key>
#   export OPENAI_API_KEY=<key>
#   ./scripts/install-argocd.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HUB_CTX="${HUB_CTX:-cluster1}"
LEAF1_CTX="${LEAF1_CTX:-cluster2}"
LEAF2_CTX="${LEAF2_CTX:-cluster3}"

ARGOCD_VERSION="${ARGOCD_VERSION:-7.8.13}"

# =============================================================================
# Platform Detection
# =============================================================================
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

PLATFORM=""  # Set during validation

# =============================================================================
# Validation
# =============================================================================
validate() {
  echo "=== Validating prerequisites ==="

  # Check env vars
  for var in SOLO_TRIAL_LICENSE_KEY OPENAI_API_KEY; do
    if [ -z "${!var:-}" ]; then
      echo "ERROR: $var is not set. Run: export $var=<your-key>"
      exit 1
    fi
  done

  # Check base CLIs
  for cmd in helm kubectl argocd; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: $cmd not found. Please install it."
      exit 1
    fi
  done

  # Check clusters reachable
  for ctx in $HUB_CTX $LEAF1_CTX $LEAF2_CTX; do
    if ! kubectl cluster-info --context "$ctx" &>/dev/null; then
      echo "ERROR: Cannot reach cluster '$ctx'."
      exit 1
    fi
  done

  # Detect platform from hub cluster
  PLATFORM=$(detect_platform "$HUB_CTX")
  echo "Detected platform: $PLATFORM"

  # Platform-specific CLI checks
  case "$PLATFORM" in
    colima)
      if ! command -v colima &>/dev/null; then
        echo "ERROR: colima not found. Please install it."
        exit 1
      fi
      ;;
    eks)
      if ! command -v aws &>/dev/null; then
        echo "WARNING: aws CLI not found. EKS-specific features may not work."
      fi
      ;;
    gke)
      if ! command -v gcloud &>/dev/null; then
        echo "WARNING: gcloud CLI not found. GKE-specific features may not work."
      fi
      ;;
  esac

  echo "All prerequisites met."
}

# =============================================================================
# Install ArgoCD on hub
# =============================================================================
install_argocd() {
  echo "=== Installing ArgoCD on $HUB_CTX ==="

  kubectl create namespace argocd --context "$HUB_CTX" 2>/dev/null || true

  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update argo

  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version "$ARGOCD_VERSION" \
    --kube-context "$HUB_CTX" \
    --values "$REPO_ROOT/argocd/bootstrap/values.yaml" \
    --wait --timeout 300s

  echo "Waiting for ArgoCD server..."
  kubectl wait --for=condition=available deploy/argocd-server \
    -n argocd --context "$HUB_CTX" --timeout=180s

  # Colima: switch to NodePort immediately (port-forward is unreliable)
  if [ "$PLATFORM" = "colima" ]; then
    kubectl patch svc argocd-server -n argocd --context "$HUB_CTX" \
      -p '{"spec":{"type":"NodePort"}}' --type=merge
    echo "ArgoCD service patched to NodePort."
  fi

  # Set admin password to solo.io
  kubectl --context "$HUB_CTX" -n argocd patch secret argocd-secret \
    -p '{"stringData": {
      "admin.password": "$2a$10$79yaoOg9dL5MO8pn8hGqtO4xQDejSEVNWAGQR268JHLdrCw6UCYmy",
      "admin.passwordMtime": "'$(date +%FT%T%Z)'"
    }}' > /dev/null 2>&1

  echo "ArgoCD installed on $HUB_CTX. (admin / solo.io)"
}

# =============================================================================
# Get ArgoCD admin password
# =============================================================================
get_argocd_password() {
  kubectl get secret argocd-initial-admin-secret -n argocd \
    --context "$HUB_CTX" -o jsonpath='{.data.password}' | base64 -d
}

# =============================================================================
# Login to ArgoCD CLI
#   - Colima: use NodePort (port-forward is unreliable with k3s socat/gRPC)
#   - EKS/GKE: use port-forward (works fine with real clusters)
# =============================================================================
ARGOCD_PF_PID=""

argocd_login() {
  local password
  password=$(get_argocd_password)

  if [ "$PLATFORM" = "colima" ]; then
    local nodeport
    nodeport=$(kubectl get svc argocd-server -n argocd --context "$HUB_CTX" \
      -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')

    argocd login "127.0.0.1:${nodeport}" \
      --username admin \
      --password "$password" \
      --plaintext
  else
    # EKS/GKE: port-forward works reliably
    kubectl port-forward svc/argocd-server -n argocd 8443:80 \
      --context "$HUB_CTX" &>/dev/null &
    ARGOCD_PF_PID=$!
    sleep 5

    argocd login localhost:8443 \
      --username admin \
      --password "$password" \
      --plaintext
  fi
}

argocd_logout() {
  if [ -n "$ARGOCD_PF_PID" ]; then
    kill "$ARGOCD_PF_PID" 2>/dev/null || true
    ARGOCD_PF_PID=""
  fi
}

# =============================================================================
# Get the API server URL reachable from ArgoCD pods
# =============================================================================
get_leaf_server_url() {
  local leaf_ctx=$1
  local leaf_platform
  leaf_platform=$(detect_platform "$leaf_ctx")

  # EKS/GKE: kubeconfig server URL is already externally routable
  if [ "$leaf_platform" != "colima" ]; then
    local cluster_name
    cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$leaf_ctx\")].context.cluster}" 2>/dev/null)
    kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster_name\")].cluster.server}" 2>/dev/null
    return
  fi

  # Colima: find VM IP + k3s API port
  local vm_ip api_port

  # Get VM IP
  vm_ip=$(colima ssh --profile "$leaf_ctx" -- hostname -I 2>/dev/null | awk '{print $1}')
  if [ -z "$vm_ip" ]; then
    echo "ERROR: Cannot determine VM IP for $leaf_ctx" >&2
    return 1
  fi

  # Get k3s API port from kubeconfig (the port forwarded into the VM)
  local cluster_name
  cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$leaf_ctx\")].context.cluster}" 2>/dev/null)
  local server_url
  server_url=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster_name\")].cluster.server}" 2>/dev/null)
  api_port=$(echo "$server_url" | sed 's|.*:\([0-9]*\)$|\1|')

  echo "https://${vm_ip}:${api_port}"
}

# =============================================================================
# Register leaf clusters with ArgoCD
#   - Colima: create cluster secrets directly (argocd cluster add fails
#     because it stores localhost URLs unreachable from ArgoCD pods)
#   - EKS/GKE: use argocd cluster add (server URLs are externally routable)
# =============================================================================
register_clusters() {
  echo "=== Registering leaf clusters with ArgoCD ==="

  if [ "$PLATFORM" = "colima" ]; then
    register_clusters_colima
  else
    register_clusters_cloud
  fi

  echo "Leaf clusters registered."
}

register_clusters_colima() {
  for pair in "leaf-1:$LEAF1_CTX" "leaf-2:$LEAF2_CTX"; do
    local leaf_name="${pair%%:*}"
    local leaf_ctx="${pair##*:}"
    local leaf_num="${leaf_name##leaf-}"
    local cluster_repo="https://github.com/ably77/agw-federated-cluster-${leaf_num}.git"

    echo "Registering $leaf_name ($leaf_ctx) via kubectl secret..."

    # Create ServiceAccount + RBAC on the leaf cluster
    kubectl create sa argocd-manager -n kube-system --context "$leaf_ctx" 2>/dev/null || true
    kubectl apply --context "$leaf_ctx" -f - <<'RBACEOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager-role
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
  - nonResourceURLs: ["*"]
    verbs: ["*"]
RBACEOF
    kubectl create clusterrolebinding argocd-manager-role-binding \
      --clusterrole=argocd-manager-role \
      --serviceaccount=kube-system:argocd-manager \
      --context "$leaf_ctx" 2>/dev/null || true

    # Create a long-lived token secret
    kubectl apply --context "$leaf_ctx" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
    sleep 3

    # Get token
    local token
    token=$(kubectl get secret argocd-manager-token -n kube-system \
      --context "$leaf_ctx" -o jsonpath='{.data.token}' | base64 -d)

    # Get server URL reachable from hub cluster pods
    local server_url
    server_url=$(get_leaf_server_url "$leaf_ctx")
    echo "  Server URL: $server_url"

    # Create ArgoCD cluster secret on the hub
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
}

register_clusters_cloud() {
  argocd_login

  for pair in "leaf-1:$LEAF1_CTX" "leaf-2:$LEAF2_CTX"; do
    local leaf_name="${pair%%:*}"
    local leaf_ctx="${pair##*:}"
    local cluster_repo="https://github.com/ably77/agw-federated-cluster-${leaf_name##leaf-}.git"

    echo "Registering $leaf_name ($leaf_ctx) via argocd CLI..."

    argocd cluster add "$leaf_ctx" \
      --name "$leaf_name" \
      --label "agw-role=leaf" \
      --label "agw-leaf-name=${leaf_name}" \
      --annotation "agw-cluster-repo=${cluster_repo}" \
      --yes

    echo "  $leaf_name registered."
  done

  argocd_logout
}

# =============================================================================
# Apply ArgoCD resources (projects, applicationsets)
# =============================================================================
apply_argocd_resources() {
  echo "=== Applying ArgoCD AppProjects and ApplicationSets ==="

  kubectl apply -f "$REPO_ROOT/argocd/projects/" --context "$HUB_CTX"

  # Patch developers project to allow empty-namespace apps (multi-namespace kustomize)
  kubectl patch appproject developers -n argocd --context "$HUB_CTX" \
    --type=json -p='[{"op":"add","path":"/spec/destinations/-","value":{"namespace":"","server":"*"}}]' 2>/dev/null || true

  kubectl apply -f "$REPO_ROOT/argocd/applicationsets/" --context "$HUB_CTX"

  echo "ArgoCD resources applied."
}

# =============================================================================
# Inject license key into enterprise-agw ApplicationSet
# (Keeps the license out of git -- applied directly on the cluster)
# =============================================================================
inject_license_key() {
  echo "=== Injecting license key into ApplicationSets ==="

  # Enterprise AgentGateway
  kubectl patch applicationset enterprise-agw -n argocd --context "$HUB_CTX" \
    --type=json -p="[
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/sources/0/helm/parameters\",
        \"value\": [{\"name\": \"licensing.licenseKey\", \"value\": \"$SOLO_TRIAL_LICENSE_KEY\"}]
      }
    ]"

  # Solo Management UI
  kubectl patch applicationset solo-management-ui -n argocd --context "$HUB_CTX" \
    --type=json -p="[
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/sources/0/helm/parameters\",
        \"value\": [{\"name\": \"licensing.licenseKey\", \"value\": \"$SOLO_TRIAL_LICENSE_KEY\"}]
      }
    ]"

  echo "License keys injected."
}

# =============================================================================
# Label istio-system namespace with network topology for multicluster peering
# =============================================================================
label_istio_networks() {
  echo "=== Labeling istio-system namespaces with network topology ==="

  kubectl label namespace istio-system --context "$LEAF1_CTX" \
    topology.istio.io/network=cluster2 --overwrite
  kubectl label namespace istio-system --context "$LEAF2_CTX" \
    topology.istio.io/network=cluster3 --overwrite

  echo "Network labels applied."
}

# =============================================================================
# Inject east-west gateway addresses into remote peering ApplicationSets
# Waits for the east-west gateways to be deployed by ArgoCD, then patches
# the peering-remote values with the actual addresses.
# =============================================================================
inject_peering_addresses() {
  echo "=== Injecting east-west gateway addresses for multicluster peering ==="

  # Wait for east-west gateway pods on both leaf clusters
  echo "Waiting for east-west gateways..."
  for ctx in $LEAF1_CTX $LEAF2_CTX; do
    for i in $(seq 1 60); do
      if kubectl get pods -n istio-eastwest --context "$ctx" 2>/dev/null | grep -q Running; then
        echo "  East-west gateway running on $ctx"
        break
      fi
      if [ $i -eq 60 ]; then
        echo "WARNING: East-west gateway not ready on $ctx after 120s -- skipping peering"
        return 1
      fi
      sleep 2
    done
  done

  # Get east-west gateway addresses
  local leaf1_ew_addr leaf2_ew_addr

  if [ "$PLATFORM" = "colima" ]; then
    # Colima: use node IP (VM IP) since no LoadBalancer is available
    leaf1_ew_addr=$(colima ssh --profile "$LEAF1_CTX" -- hostname -I 2>/dev/null | awk '{print $1}')
    leaf2_ew_addr=$(colima ssh --profile "$LEAF2_CTX" -- hostname -I 2>/dev/null | awk '{print $1}')
  else
    # Cloud: get LoadBalancer address from the east-west gateway service
    for i in $(seq 1 30); do
      leaf1_ew_addr=$(get_lb_address istio-eastwest istio-eastwest "$LEAF1_CTX")
      leaf2_ew_addr=$(get_lb_address istio-eastwest istio-eastwest "$LEAF2_CTX")
      if [ "$leaf1_ew_addr" != "<pending>" ] && [ "$leaf2_ew_addr" != "<pending>" ]; then
        break
      fi
      echo "  Waiting for east-west LB addresses... (${i}/30)"
      sleep 4
    done
  fi

  echo "  Leaf-1 east-west address: $leaf1_ew_addr"
  echo "  Leaf-2 east-west address: $leaf2_ew_addr"

  if [ -z "$leaf1_ew_addr" ] || [ -z "$leaf2_ew_addr" ]; then
    echo "ERROR: Could not determine east-west gateway addresses."
    return 1
  fi

  # Update the peering-remote values files with actual addresses
  # leaf-1 needs leaf-2's address (to reach cluster3)
  sed -i.bak "s|address: \"PLACEHOLDER\"|address: \"${leaf2_ew_addr}\"|" \
    "$REPO_ROOT/helm-apps/istio/overlays/leaf-1-peering-remote-values.yaml"
  # leaf-2 needs leaf-1's address (to reach cluster2)
  sed -i.bak "s|address: \"PLACEHOLDER\"|address: \"${leaf1_ew_addr}\"|" \
    "$REPO_ROOT/helm-apps/istio/overlays/leaf-2-peering-remote-values.yaml"
  rm -f "$REPO_ROOT/helm-apps/istio/overlays/"*.bak

  # Commit and push the address updates so ArgoCD picks them up
  cd "$REPO_ROOT"
  git add helm-apps/istio/overlays/leaf-*-peering-remote-values.yaml
  git commit -m "Inject east-west gateway addresses for multicluster peering" 2>/dev/null || true
  git push 2>/dev/null || true
  cd -

  echo "Peering addresses injected and pushed to git."
}

# =============================================================================
# Create LLM secrets on leaf clusters
# =============================================================================
create_secrets() {
  echo "=== Creating secrets on leaf clusters ==="

  for ctx in $LEAF1_CTX $LEAF2_CTX; do
    kubectl create namespace agentgateway-system --context "$ctx" 2>/dev/null || true

    # OpenAI API key
    kubectl create secret generic enrollment-openai-secret \
      -n agentgateway-system \
      --from-literal="Authorization=Bearer $OPENAI_API_KEY" \
      --dry-run=client -oyaml | kubectl apply --context "$ctx" -f -

    # Solo license key (for enterprise-agentgateway)
    kubectl create secret generic solo-license \
      -n agentgateway-system \
      --from-literal="license-key=$SOLO_TRIAL_LICENSE_KEY" \
      --dry-run=client -oyaml | kubectl apply --context "$ctx" -f -

    echo "  Secrets created on $ctx."
  done
}

# =============================================================================
# Create shared root CA for Istio multi-cluster
# =============================================================================
create_istio_certs() {
  echo "=== Generating shared root CA for Istio ==="
  local WORK_DIR
  WORK_DIR=$(mktemp -d)

  cat > "$WORK_DIR/root-openssl.cnf" <<'CNFEOF'
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = v3_ca
[ dn ]
C  = US
ST = California
L  = San Francisco
O  = MyOrg
OU = MyUnit
CN = root-cert
[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
CNFEOF

  cat > "$WORK_DIR/intermediate-req.cnf" <<'CNFEOF'
[ req ]
prompt = no
distinguished_name = dn
[ dn ]
C  = US
ST = California
L  = San Francisco
O  = MyOrg
OU = MyUnit
CN = istio-intermediate-ca
CNFEOF

  cat > "$WORK_DIR/ca-ext.cnf" <<'CNFEOF'
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
CNFEOF

  openssl req -x509 -sha256 -nodes -days 3650 \
    -newkey rsa:2048 -keyout "$WORK_DIR/root-key.pem" \
    -out "$WORK_DIR/root-cert.pem" \
    -config "$WORK_DIR/root-openssl.cnf" -extensions v3_ca 2>/dev/null

  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$WORK_DIR/ca-key.pem" -out "$WORK_DIR/ca.csr" \
    -config "$WORK_DIR/intermediate-req.cnf" 2>/dev/null

  openssl x509 -req -sha256 -days 3650 \
    -in "$WORK_DIR/ca.csr" \
    -CA "$WORK_DIR/root-cert.pem" -CAkey "$WORK_DIR/root-key.pem" \
    -CAcreateserial -out "$WORK_DIR/ca-cert.pem" \
    -extfile "$WORK_DIR/ca-ext.cnf" -extensions v3_ca 2>/dev/null

  cat "$WORK_DIR/ca-cert.pem" "$WORK_DIR/root-cert.pem" > "$WORK_DIR/cert-chain.pem"

  # Install on both leaf clusters
  for ctx in $LEAF1_CTX $LEAF2_CTX; do
    kubectl create namespace istio-system --context "$ctx" 2>/dev/null || true
    kubectl create secret generic cacerts -n istio-system \
      --from-file=ca-cert.pem="$WORK_DIR/ca-cert.pem" \
      --from-file=ca-key.pem="$WORK_DIR/ca-key.pem" \
      --from-file=root-cert.pem="$WORK_DIR/root-cert.pem" \
      --from-file=cert-chain.pem="$WORK_DIR/cert-chain.pem" \
      --context "$ctx" --dry-run=client -oyaml | kubectl apply --context "$ctx" -f -
  done

  rm -rf "$WORK_DIR"
  echo "Istio CA certs installed on leaf clusters."
}

# =============================================================================
# Wait for ArgoCD sync -- count Healthy (not Synced+Healthy) because
# k8s 1.35 structured merge diff causes cosmetic OutOfSync on some apps
# =============================================================================
wait_for_sync() {
  echo "=== Waiting for ArgoCD to sync all applications ==="

  local timeout=900
  local interval=15
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    local total healthy
    total=$(kubectl get applications -n argocd --context "$HUB_CTX" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    healthy=$(kubectl get applications -n argocd --context "$HUB_CTX" --no-headers 2>/dev/null | grep -c "Healthy" || true)

    echo "  Applications: $healthy/$total healthy (${elapsed}s elapsed)"

    if [ "$total" -gt 0 ] && [ "$healthy" -eq "$total" ]; then
      echo "All applications healthy!"
      return 0
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "WARNING: Not all applications healthy within ${timeout}s."
  echo "Check: kubectl get applications -n argocd --context $HUB_CTX"
  return 1
}

# =============================================================================
# Resolve LoadBalancer address (IP on GKE, hostname on EKS NLB)
# =============================================================================
get_lb_address() {
  local svc=$1 ns=$2 ctx=$3
  local ip hostname
  ip=$(kubectl get svc "$svc" -n "$ns" --context "$ctx" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [ -n "$ip" ]; then echo "$ip"; return; fi
  hostname=$(kubectl get svc "$svc" -n "$ns" --context "$ctx" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$hostname" ]; then echo "$hostname"; return; fi
  echo "<pending>"
}

# =============================================================================
# Print access info
# =============================================================================
print_access_info() {
  local password
  password=$(get_argocd_password)

  echo ""
  echo "============================================"
  echo "  AGW Federated GitOps -- Install Complete"
  echo "============================================"
  echo ""
  echo "Platform: $PLATFORM"
  echo ""

  if [ "$PLATFORM" = "colima" ]; then
    local nodeport
    nodeport=$(kubectl get svc argocd-server -n argocd --context "$HUB_CTX" \
      -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)
    echo "ArgoCD UI:"
    echo "  URL: http://localhost:${nodeport}"
    echo "  Username: admin"
    echo "  Password: $password"
  else
    echo "ArgoCD UI:"
    echo "  kubectl port-forward svc/argocd-server -n argocd 8080:80 --context $HUB_CTX"
    echo "  URL: http://localhost:8080"
    echo "  Username: admin"
    echo "  Password: $password"
  fi

  echo ""

  if [ "$PLATFORM" = "eks" ] || [ "$PLATFORM" = "gke" ]; then
    echo "Ingress Gateway (leaf-1):"
    local lb_addr
    lb_addr=$(get_lb_address ingress agentgateway-system "$LEAF1_CTX")
    echo "  LoadBalancer: $lb_addr"
    if [[ "$lb_addr" == *".elb."* || "$lb_addr" == *".amazonaws.com"* ]]; then
      echo "  EKS NLB detected -- resolve hostname to IP for /etc/hosts:"
      echo "    nslookup $lb_addr"
    fi
    echo "  Add to /etc/hosts:"
    echo "    <LB_IP> enroll.glootest.com grafana.glootest.com"
    echo ""
  fi

  echo "Port-forward access (works on all platforms):"
  echo ""
  echo "Solo Management UI (leaf-1):"
  echo "  kubectl port-forward svc/solo-enterprise-ui -n kagent 4000:80 --context $LEAF1_CTX"
  echo "  URL: http://localhost:4000"
  echo ""
  echo "Enrollment Chatbot (leaf-1):"
  echo "  kubectl port-forward svc/enrollment-chatbot -n wgu-demo-frontend 8501:8501 --context $LEAF1_CTX"
  echo "  URL: http://localhost:8501"
  echo ""
  echo "Grafana (leaf-1):"
  echo "  kubectl port-forward svc/kube-prometheus-leaf-1-grafana -n monitoring 3000:3000 --context $LEAF1_CTX"
  echo "  URL: http://localhost:3000 (admin / prom-operator)"
  echo ""
  echo "Enrollment Chatbot (leaf-2):"
  echo "  kubectl port-forward svc/enrollment-chatbot -n wgu-demo-frontend 8502:8501 --context $LEAF2_CTX"
  echo "  URL: http://localhost:8502"
  echo ""
  echo "ArgoCD Applications:"
  echo "  kubectl get applications -n argocd --context $HUB_CTX"
  echo ""
}

# =============================================================================
# Main
# =============================================================================
validate
install_argocd
create_istio_certs
create_secrets
register_clusters
apply_argocd_resources
inject_license_key
label_istio_networks
wait_for_sync || true
inject_peering_addresses
print_access_info
