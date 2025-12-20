#!/bin/bash
#
# GKE Deployment Script for Agent Scheduler
#
# Prerequisites:
# 1. gcloud CLI installed and configured
# 2. Docker installed
# 3. kubectl configured to use GKE cluster
#
# Usage:
#   export PROJECT_ID="your-project-id"
#   export REGION="europe-west1"
#   export SCHEDULER_DOMAIN="scheduler.yourdomain.com"
#   ./deploy-gke.sh
#

set -e

# Configuration
PROJECT_ID="${PROJECT_ID:?Error: Set PROJECT_ID environment variable}"
REGION="${REGION:-europe-west1}"
SCHEDULER_DOMAIN="${SCHEDULER_DOMAIN:?Error: Set SCHEDULER_DOMAIN environment variable}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/agent-scheduler"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "========================================"
echo "GKE Deployment for Agent Scheduler"
echo "========================================"
echo "Project:  ${PROJECT_ID}"
echo "Region:   ${REGION}"
echo "Domain:   ${SCHEDULER_DOMAIN}"
echo "Registry: ${REGISTRY}"
echo "========================================"

# Check if gcloud is authenticated
if ! gcloud auth print-access-token &>/dev/null; then
    echo "Error: Not authenticated with gcloud. Run 'gcloud auth login'"
    exit 1
fi

# Check if kubectl is configured
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: kubectl not configured. Run:"
    echo "  gcloud container clusters get-credentials <cluster-name> --region ${REGION}"
    exit 1
fi

# Configure Docker for Artifact Registry
echo ""
echo "Configuring Docker authentication..."
gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet

# Build and push images
echo ""
echo "Building and pushing images..."

declare -A IMAGES=(
    ["scheduler"]="${ROOT_DIR}/scheduler"
    ["scheduler-ui"]="${ROOT_DIR}/scheduler/agent-scheduler-ui"
    ["agent-db-api"]="${ROOT_DIR}/agent-db-api"
    ["agent-ctl"]="${ROOT_DIR}/agent-ctl"
)

for name in "${!IMAGES[@]}"; do
    dir="${IMAGES[$name]}"
    if [ -d "$dir" ]; then
        echo ""
        echo "Building ${name}..."
        docker build -t "${REGISTRY}/${name}:latest" "$dir"
        echo "Pushing ${name}..."
        docker push "${REGISTRY}/${name}:latest"
    else
        echo "Warning: Directory not found: $dir (skipping ${name})"
    fi
done

# Update manifests with actual values
echo ""
echo "Preparing manifests..."
TEMP_DIR=$(mktemp -d)
cp "${SCRIPT_DIR}"/*.yaml "${TEMP_DIR}/"

# Replace placeholders in manifests
for file in "${TEMP_DIR}"/*.yaml; do
    sed -i "s|REGISTRY_PATH|${REGISTRY}|g" "$file"
    sed -i "s|\${SCHEDULER_DOMAIN}|${SCHEDULER_DOMAIN}|g" "$file"
    sed -i "s|\${REGION}|${REGION}|g" "$file"
    sed -i "s|\${PROJECT_ID}|${PROJECT_ID}|g" "$file"
done

# Apply manifests in order
echo ""
echo "Applying Kubernetes manifests..."

kubectl apply -f "${TEMP_DIR}/00-namespace.yaml"

# Update CORS in configmap with actual domain
sed -i "s|\${SCHEDULER_DOMAIN}|${SCHEDULER_DOMAIN}|g" "${TEMP_DIR}/01-configmap.yaml"
kubectl apply -f "${TEMP_DIR}/01-configmap.yaml"

kubectl apply -f "${TEMP_DIR}/02-secrets.yaml"
kubectl apply -f "${TEMP_DIR}/07-database-schema-configmap.yaml"
kubectl apply -f "${TEMP_DIR}/08-agent-db-schema-configmap.yaml"

echo "Waiting for namespace to be ready..."
sleep 2

kubectl apply -f "${TEMP_DIR}/03-postgres-statefulset.yaml"

echo "Waiting for PostgreSQL to be ready..."
kubectl rollout status statefulset/postgres -n agent-scheduler --timeout=300s

kubectl apply -f "${TEMP_DIR}/04-scheduler-deployment.yaml"
kubectl apply -f "${TEMP_DIR}/05-ui-deployment.yaml"
kubectl apply -f "${TEMP_DIR}/09-agent-db-deployment.yaml"
kubectl apply -f "${TEMP_DIR}/10-agent-ctl-deployment.yaml"
kubectl apply -f "${TEMP_DIR}/06-managed-cert.yaml"
kubectl apply -f "${TEMP_DIR}/06-ingress.yaml"
kubectl apply -f "${TEMP_DIR}/11-postgres-backup-cronjob.yaml"

# Wait for deployments
echo ""
echo "Waiting for deployments to be ready..."
kubectl rollout status deployment/scheduler -n agent-scheduler --timeout=300s
kubectl rollout status deployment/ui -n agent-scheduler --timeout=300s
kubectl rollout status deployment/agent-db-api -n agent-scheduler --timeout=300s
kubectl rollout status deployment/agent-ctl -n agent-scheduler --timeout=300s

# Cleanup temp directory
rm -rf "${TEMP_DIR}"

# Get ingress IP
echo ""
echo "========================================"
echo "Deployment Complete!"
echo "========================================"
echo ""
echo "Pods:"
kubectl get pods -n agent-scheduler
echo ""
echo "Services:"
kubectl get services -n agent-scheduler
echo ""
echo "Ingress:"
kubectl get ingress -n agent-scheduler
echo ""

# Get static IP
STATIC_IP=$(gcloud compute addresses describe scheduler-ip --global --format="get(address)" 2>/dev/null || echo "Not found")

echo "========================================"
echo "Next Steps:"
echo "========================================"
echo ""
echo "1. Configure DNS:"
echo "   Add an A record: ${SCHEDULER_DOMAIN} -> ${STATIC_IP}"
echo ""
echo "2. Wait for SSL certificate provisioning (15-60 minutes after DNS):"
echo "   kubectl describe managedcertificate scheduler-cert -n agent-scheduler"
echo ""
echo "3. Access your application:"
echo "   https://${SCHEDULER_DOMAIN}/"
echo ""
echo "4. Check logs if needed:"
echo "   kubectl logs -f deployment/scheduler -n agent-scheduler"
echo ""
