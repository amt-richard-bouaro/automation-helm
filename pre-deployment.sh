#!/bin/bash

# Function to check if Helm is installed
check_helm_installed() {
    if ! command -v helm &> /dev/null; then
        echo "Helm is not installed. Installing Helm..."
        # Install Helm (for macOS or Linux)
#        curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3.sh | bash
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
    else
        echo "Helm is already installed."
    fi
}

# Function to create the namespace if it does not exist
create_namespace_if_not_exists() {
    local namespace="$1"
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        echo "Creating namespace '$namespace'..."
        kubectl create namespace "$namespace"
    else
        echo "Namespace '$namespace' already exists."
    fi
}

make_automation_assessment_default_namespace() {
  # Check the current Kubernetes context
  echo "Current Kubernetes context:"
  kubectl config current-context

  # Display the currently set namespace
  echo "Currently set namespace:"
  kubectl config view --minify | grep namespace:

  # Set the namespace to automation-assessment
  echo "Setting namespace to automation-assessment..."
  kubectl config set-context --current --namespace=automation-assessment

  # Verify the namespace is set
  echo "Namespace set to:"
  kubectl config view --minify | grep namespace:
}

# Main script execution
NAMESPACE="automation-assessment"

check_helm_installed

create_namespace_if_not_exists "$NAMESPACE"


# Set the default namespace to automation-assessment for the current shell session
# This ensures that subsequent Helm commands and Argo CD installation will use this namespace by default.
make_automation_assessment_default_namespace

# Function to check if NGINX Ingress is installed
check_ingress_installed() {
    if helm list -n "$NAMESPACE" | grep -q "nginx-ingress"; then
        echo "NGINX Ingress is already installed."
        return 0
    else
        echo "NGINX Ingress is not installed."
        return 1
    fi
}

# Function to install NGINX Ingress Controller
install_nginx_ingress() {
    echo "Adding NGINX Ingress repository..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update

    echo "Installing NGINX Ingress Controller..."
    helm install nginx-ingress ingress-nginx/ingress-nginx --namespace "$NAMESPACE"

    echo "NGINX Ingress Controller installed."
}


# Check if NGINX Ingress is installed
check_ingress_installed || install_nginx_ingress

# Function to check if Argo CD is already installed
check_argocd_installed() {
    local namespace="$1"
    if helm list -n "$namespace" | grep -q "argocd"; then
        echo "Argo CD is already installed in namespace '$namespace'."
        return 0  # Argo CD is installed
    else
        return 1  # Argo CD is not installed
    fi
}

# Function to check if Argo CD CRDs exist
check_argocd_crds() {
    if kubectl get crd applications.argoproj.io &> /dev/null; then
        echo "Argo CD CRD already exists."
        return 0
    else
        return 1
    fi
}

# Function to install the Argo CD chart
install_argocd_chart() {
    local namespace="$1"
    echo "Installing Argo CD in namespace '$namespace'..."
    helm install argocd ./argo-cd --namespace "$namespace" --values ./argo-cd/values.yaml
}

## Function to check if Argo CD is already installed
#check_argocd_installed() {
#    local namespace="$1"
#    if helm list -n "$namespace" | grep -q "argocd"; then
#        echo "Argo CD is already installed in namespace '$namespace'."
#        return 0  # Argo CD is installed
#    else
#        return 1  # Argo CD is not installed
#    fi
#}

expose_argocd() {
  echo "How would you like to expose Argo CD?"
  echo "1) Ingress"
  echo "2) Port Forwarding"
  read -p "Please enter your choice (1 or 2): " CHOICE

  if [[ "$CHOICE" -eq 1 ]]; then
    echo "Setting up ingress for Argo CD..."
    helm upgrade argocd "$ARGOCD_CHART_DIR" --namespace automation-assessment -f ./argo-cd/values-ingress.yaml
    echo "Ingress for Argo CD has been set up. Check your ingress resource with:"
    echo "kubectl get ingress -n automation-assessment"
  elif [[ "$CHOICE" -eq 2 ]]; then
    local port
    read -p "Enter the local port you want to use for port-forwarding (default is 8080): " port
    port=${port:-8080}

    # Check if the service name is `argocd-server` or `argo-cd-argocd-server`
    if kubectl get svc/argocd-server -n automation-assessment &> /dev/null; then
      SERVICE_NAME="argocd-server"
    elif kubectl get svc/argo-cd-argocd-server -n automation-assessment &> /dev/null; then
      SERVICE_NAME="argo-cd-argocd-server"
    else
      echo "Error: Argo CD service not found."
      exit 1
    fi

    echo "Port-forwarding to Argo CD server on port $port..."
    kubectl port-forward svc/"$SERVICE_NAME" -n automation-assessment "$port":443 &

    echo "Argo CD is now accessible at http://localhost:$port"
    echo "Authenticate with username:admin and password below"
    echo "======================================================"
    # Wait for ArgoCD secret to be created
    for i in {1..30}; do
      if kubectl get secret argocd-initial-admin-secret -n automation-assessment &> /dev/null; then
        kubectl get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" -n automation-assessment | base64 -d
        echo ""
        break
      fi
      if [ $i -eq 30 ]; then
        echo "Warning: ArgoCD secret not found. Check with: kubectl get secrets -n automation-assessment"
      fi
      sleep 1
    done
    echo "======================================================"
  else
    echo "Invalid choice. Exiting."
    exit 1
  fi
}

# Check if Argo CD CRDs exist, if not, install Argo CD
if ! check_argocd_crds; then
    if ! check_argocd_installed "$NAMESPACE"; then
        install_argocd_chart "$NAMESPACE"
    else
        echo "Skipping installation of Argo CD."
    fi
else
    echo "Argo CD CRDs already exist. Skipping installation."
fi

# Expose Argo CD
expose_argocd

# Function to create SSL certificate secret
create_ssl_secret() {
    local cert_file="/home/richard/Documents/server-cert.crt"
    if [ -f "$cert_file" ]; then
        echo "Creating SSL certificate secret..."
        kubectl create secret generic automation-assessment-cert --from-file=server-cert.crt="$cert_file" -n "$NAMESPACE" 2>/dev/null || echo "SSL certificate secret already exists."
    else
        echo "Warning: SSL certificate file not found at $cert_file"
    fi
}

# Function to deploy apps
deploy_apps() {
    echo "Deploying applications (MySQL and automation-assessment)..."
    
    # Create SSL certificate secret
    create_ssl_secret
    
    # Deploy MySQL
    echo "Deploying MySQL..."
    helm install mysql ./mysql --namespace "$NAMESPACE" 2>/dev/null || echo "MySQL already installed or failed."
    
    # Wait for MySQL to be ready
    echo "Waiting for MySQL to be ready..."
    sleep 10
    
    # Deploy automation-assessment
    echo "Deploying automation-assessment..."
    helm install automation-assessment ./automation-assessment --namespace "$NAMESPACE" 2>/dev/null || echo "Automation-assessment already installed or failed."
    
    # Deploy root-app
    echo "Deploying root-app..."
    helm install root-app ./root-app --namespace "$NAMESPACE" 2>/dev/null || echo "Root-app already installed or failed."
    
    echo "Applications deployment initiated."
    echo "Monitor with: kubectl get pods -n $NAMESPACE"
}

# Deploy the applications
echo ""
echo "Would you like to deploy the applications (MySQL and automation-assessment)?"
read -p "Enter yes/no: " deploy_choice
if [[ "$deploy_choice" =~ ^[Yy]es$ ]]; then
    deploy_apps
else
    echo "Skipping application deployment."
fi

echo "Script execution complete."
