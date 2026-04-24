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

  echo "ArgoCD installed on $HUB_CTX."
}

# =============================================================================
# Get ArgoCD admin password
# =============================================================================
get_argocd_password() {
  kubectl get secret argocd-initial-admin-secret -n argocd \
    --context "$HUB_CTX" -o jsonpath='{.data.password}' | base64 -d
}

# =============================================================================
# Discover API server address reachable from hub cluster pods
# =============================================================================
get_api_server_for_argocd() {
  local leaf_ctx=$1
  local leaf_platform
  leaf_platform=$(detect_platform "$leaf_ctx")

  # --- EKS / GKE / unknown: kubeconfig server URL is already externally routable ---
  if [ "$leaf_platform" != "colima" ]; then
    local cluster_name
    cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$leaf_ctx\")].context.cluster}" 2>/dev/null)
    kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster_name\")].cluster.server}" 2>/dev/null
    return
  fi

  # --- Colima: localhost-forwarded ports need special handling ---

  # Strategy 1: Use Colima VM IP + port 6443
  local vm_name="${leaf_ctx}"
  local vm_ip
  vm_ip=$(colima ssh --profile "$vm_name" -- hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "$vm_ip" ]; then
    if kubectl exec -n argocd deploy/argocd-server --context "$HUB_CTX" -- \
       wget -q --spider --timeout=3 "https://${vm_ip}:6443" 2>/dev/null; then
      echo "https://${vm_ip}:6443"
      return
    fi
  fi

  # Strategy 2: Use host gateway IP + forwarded port
  local api_server
  api_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"colima-${leaf_ctx}\")].cluster.server}" 2>/dev/null)
  if [ -z "$api_server" ]; then
    api_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${leaf_ctx}\")].cluster.server}" 2>/dev/null)
  fi
  local port
  port=$(echo "$api_server" | sed 's|.*:\([0-9]*\)$|\1|')

  local host_ip
  host_ip=$(kubectl exec -n argocd deploy/argocd-server --context "$HUB_CTX" -- \
    sh -c "getent hosts host.docker.internal 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)

  if [ -z "$host_ip" ]; then
    host_ip=$(kubectl exec -n argocd deploy/argocd-server --context "$HUB_CTX" -- \
      sh -c "ip route | grep default | awk '{print \$3}'" 2>/dev/null || true)
  fi

  if [ -n "$host_ip" ] && [ -n "$port" ]; then
    echo "https://${host_ip}:${port}"
    return
  fi

  # Strategy 3: Fallback
  echo "$api_server"
}

# =============================================================================
# Register leaf clusters with ArgoCD
# =============================================================================
register_clusters() {
  echo "=== Registering leaf clusters with ArgoCD ==="

  # Get ArgoCD password and login
  local password
  password=$(get_argocd_password)

  # Port-forward ArgoCD for CLI access
  kubectl port-forward svc/argocd-server -n argocd 8443:443 \
    --context "$HUB_CTX" &>/dev/null &
  local pf_pid=$!
  sleep 3

  argocd login localhost:8443 \
    --username admin \
    --password "$password" \
    --insecure \
    --grpc-web

  # Register each leaf cluster
  local leaf_name leaf_ctx
  for pair in "leaf-1:$LEAF1_CTX" "leaf-2:$LEAF2_CTX"; do
    leaf_name="${pair%%:*}"
    leaf_ctx="${pair##*:}"
    local cluster_repo="https://github.com/ably77/agw-federated-cluster-${leaf_name##leaf-}.git"

    echo "Registering $leaf_name ($leaf_ctx)..."

    # Use argocd cluster add which handles ServiceAccount creation
    argocd cluster add "$leaf_ctx" \
      --name "$leaf_name" \
      --label "agw-role=leaf" \
      --label "agw-leaf-name=${leaf_name}" \
      --label "agw-cluster-repo=${cluster_repo}" \
      --yes

    echo "$leaf_name registered."
  done

  # Clean up port-forward
  kill $pf_pid 2>/dev/null || true

  echo "Leaf clusters registered."
}

# =============================================================================
# Apply ArgoCD resources (projects, applicationsets)
# =============================================================================
apply_argocd_resources() {
  echo "=== Applying ArgoCD AppProjects and ApplicationSets ==="

  kubectl apply -f "$REPO_ROOT/argocd/projects/" --context "$HUB_CTX"
  kubectl apply -f "$REPO_ROOT/argocd/applicationsets/" --context "$HUB_CTX"

  echo "ArgoCD resources applied."
}

# =============================================================================
# Create LLM secrets on leaf clusters
# =============================================================================
create_secrets() {
  echo "=== Creating LLM API key secrets on leaf clusters ==="

  for ctx in $LEAF1_CTX $LEAF2_CTX; do
    kubectl create namespace agentgateway-system --context "$ctx" 2>/dev/null || true
    kubectl create secret generic enrollment-openai-secret \
      -n agentgateway-system \
      --from-literal="Authorization=Bearer $OPENAI_API_KEY" \
      --dry-run=client -oyaml | kubectl apply --context "$ctx" -f -
    echo "Secret created on $ctx."
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
# Wait for ArgoCD sync
# =============================================================================
wait_for_sync() {
  echo "=== Waiting for ArgoCD to sync all applications ==="

  local timeout=600
  local interval=15
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    local total healthy
    total=$(kubectl get applications -n argocd --context "$HUB_CTX" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    healthy=$(kubectl get applications -n argocd --context "$HUB_CTX" --no-headers 2>/dev/null | grep -c "Healthy.*Synced" || true)

    echo "  Applications: $healthy/$total healthy+synced (${elapsed}s elapsed)"

    if [ "$total" -gt 0 ] && [ "$healthy" -eq "$total" ]; then
      echo "All applications synced and healthy!"
      return 0
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "WARNING: Not all applications synced within ${timeout}s."
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
  echo "ArgoCD UI:"
  echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443 --context $HUB_CTX"
  echo "  URL: https://localhost:8080"
  echo "  Username: admin"
  echo "  Password: $password"
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
  echo "Enrollment Chatbot (leaf-1):"
  echo "  kubectl port-forward svc/enrollment-chatbot -n wgu-demo-frontend 8501:8501 --context $LEAF1_CTX"
  echo "  URL: http://localhost:8501"
  echo ""
  echo "Grafana (leaf-1):"
  echo "  kubectl port-forward svc/grafana-prometheus -n monitoring 3000:3000 --context $LEAF1_CTX"
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
wait_for_sync || true
print_access_info
