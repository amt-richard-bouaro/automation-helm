#!/bin/bash
set -e

############################################
# CONFIG
############################################
NAMESPACE="automation-assessment"
ARGOCD_RELEASE="argocd"
ARGOCD_CHART_DIR="./argo-cd"
ARGOCD_EXPOSE_METHOD=${ARGOCD_EXPOSE_METHOD:-interactive} # interactive | ingress | port-forward

############################################
# UTILS
############################################
log() {
  echo -e "\n👉 $1"
}

############################################
# HELM
############################################
check_helm_installed() {
  if ! command -v helm &>/dev/null; then
    log "Helm not found. Installing..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
  else
    log "Helm already installed."
  fi
}

############################################
# K8S NAMESPACE
############################################
create_namespace_if_not_exists() {
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log "Creating namespace '$NAMESPACE'"
    kubectl create namespace "$NAMESPACE"
  else
    log "Namespace '$NAMESPACE' already exists."
  fi
}

set_default_namespace() {
  log "Setting default namespace to $NAMESPACE"
  kubectl config set-context --current --namespace="$NAMESPACE"
}

############################################
# NGINX INGRESS
############################################
install_or_upgrade_ingress() {
  log "Ensuring NGINX Ingress is installed"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx &>/dev/null || true
  helm repo update

  helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
    --namespace "$NAMESPACE"

  kubectl rollout status deployment/nginx-ingress-controller \
    -n "$NAMESPACE" --timeout=180s || true
}

############################################
# ARGO CD
############################################
argocd_runtime_exists() {
  kubectl get deployment argocd-server -n "$NAMESPACE" &>/dev/null &&
  kubectl get svc argocd-server -n "$NAMESPACE" &>/dev/null
}

install_or_upgrade_argocd() {
  log "Installing / Upgrading Argo CD"

  helm upgrade --install "$ARGOCD_RELEASE" "$ARGOCD_CHART_DIR" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$ARGOCD_CHART_DIR/values.yaml"

  log "Waiting for Argo CD server to become ready"
  kubectl rollout status deployment/argocd-server \
    -n "$NAMESPACE" --timeout=180s
}

ensure_argocd_installed() {
  if argocd_runtime_exists; then
    log "Argo CD is already installed and running."
  else
    log "Argo CD not fully present. Reconciling..."
    install_or_upgrade_argocd
  fi
}

############################################
# ARGO CD EXPOSURE
############################################
get_argocd_service() {
  kubectl get svc argocd-server -n "$NAMESPACE" &>/dev/null && echo "argocd-server" && return
  kubectl get svc argo-cd-argocd-server -n "$NAMESPACE" &>/dev/null && echo "argo-cd-argocd-server" && return
  echo ""
}

expose_argocd() {
  local method="$ARGOCD_EXPOSE_METHOD"

  if [[ "$method" == "interactive" ]]; then
    echo "How would you like to expose Argo CD?"
    echo "1) Ingress"
    echo "2) Port Forwarding"
    read -p "Choice (1 or 2): " choice

    [[ "$choice" == "1" ]] && method="ingress"
    [[ "$choice" == "2" ]] && method="port-forward"
  fi

  case "$method" in
    ingress)
      log "Configuring ingress for Argo CD"
      helm upgrade --install "$ARGOCD_RELEASE" "$ARGOCD_CHART_DIR" \
        -n "$NAMESPACE" \
        -f "$ARGOCD_CHART_DIR/values-ingress.yaml"
      kubectl get ingress -n "$NAMESPACE"
      ;;
    port-forward)
      SERVICE_NAME=$(get_argocd_service)
      [[ -z "$SERVICE_NAME" ]] && echo "❌ Argo CD service not found" && exit 1

      log "Port-forwarding Argo CD on http://localhost:8080"
      kubectl port-forward svc/"$SERVICE_NAME" -n "$NAMESPACE" 8080:443 &

      log "Fetching admin password"
      for i in {1..30}; do
        if kubectl get secret argocd-initial-admin-secret -n "$NAMESPACE" &>/dev/null; then
          kubectl get secret argocd-initial-admin-secret \
            -n "$NAMESPACE" \
            -o jsonpath="{.data.password}" | base64 -d
          echo
          break
        fi
        sleep 1
      done
      ;;
    *)
      echo "❌ Invalid exposure method"
      exit 1
      ;;
  esac
}

############################################
# SSL SECRET
############################################
create_ssl_secret() {
  local cert_file="/home/richard/Documents/server-cert.crt"

  if [[ -f "$cert_file" ]]; then
    log "Ensuring SSL secret exists"
    kubectl create secret generic automation-assessment-cert \
      --from-file=server-cert.crt="$cert_file" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  else
    log "⚠️ SSL cert not found at $cert_file"
  fi
}

############################################
# APPLICATIONS
############################################
deploy_apps() {
  create_ssl_secret

  log "Deploying MySQL"
  helm upgrade --install mysql ./mysql -n "$NAMESPACE"

  log "Deploying automation-assessment"
  helm upgrade --install automation-assessment ./automation-assessment -n "$NAMESPACE"

  log "Deploying User managementMySQL"
  helm upgrade --install usermgmt-mysql ./usermgmt-mysql -n "$NAMESPACE"

  log "Deploying User management"
  helm upgrade --install usermgmt ./usermgmt -n "$NAMESPACE"

  log "Deploying root-app"
  helm upgrade --install root-app ./root-app -n "$NAMESPACE"

  log "Applications deployed"
  kubectl get pods -n "$NAMESPACE"
}

############################################
# MAIN
############################################
check_helm_installed
create_namespace_if_not_exists
set_default_namespace
install_or_upgrade_ingress
ensure_argocd_installed
expose_argocd

echo
read -p "Deploy applications (MySQL + automation-assessment + root-app)? (yes/no): " deploy_choice
if [[ "$deploy_choice" =~ ^[Yy]es$ ]]; then
  deploy_apps
else
  log "Skipping application deployment."
fi

log "Script execution complete ✅"
