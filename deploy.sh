#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="agent-scheduler"
K8S_NODE="desktop-control-plane"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Image definitions: local_name:k8s_name
declare -A IMAGES=(
    ["scheduler:latest"]="docker.io/library/scheduler:latest"
    ["scheduler-ui:latest"]="docker.io/library/scheduler-ui:latest"
    ["agent-db-api:latest"]="docker.io/library/agent-db-api:latest"
    ["agent-ctl:latest"]="docker.io/library/agent-ctl:latest"
)

# Deployment names for restart
DEPLOYMENTS=("scheduler" "ui" "agent-db-api" "agent-ctl")

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    # Check docker
    if ! command -v docker &> /dev/null; then
        log_error "docker not found. Please install docker."
        exit 1
    fi

    # Check kubernetes context
    local context=$(kubectl config current-context 2>/dev/null)
    if [[ "$context" != "docker-desktop" ]]; then
        log_warn "Current context is '$context', expected 'docker-desktop'"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Check if node is accessible
    if ! docker exec "$K8S_NODE" echo "OK" &> /dev/null; then
        log_error "Cannot access Kubernetes node '$K8S_NODE'. Is Docker Desktop Kubernetes running?"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

load_image() {
    local image=$1
    log_info "Loading image: $image"

    # Check if image exists locally
    if ! docker image inspect "$image" &> /dev/null; then
        log_error "Image '$image' not found locally. Please build it first."
        return 1
    fi

    # Load into containerd
    docker save "$image" | docker exec -i "$K8S_NODE" ctr -n k8s.io images import -

    if [ $? -eq 0 ]; then
        log_success "Loaded: $image"
    else
        log_error "Failed to load: $image"
        return 1
    fi
}

load_all_images() {
    log_info "Loading images into Kubernetes containerd..."

    local failed=0
    for local_image in "${!IMAGES[@]}"; do
        if ! load_image "$local_image"; then
            ((failed++))
        fi
    done

    if [ $failed -gt 0 ]; then
        log_error "$failed image(s) failed to load"
        return 1
    fi

    log_success "All images loaded successfully"
}

apply_manifests() {
    log_info "Applying Kubernetes manifests..."

    # Apply in order
    local manifests=(
        "00-namespace.yaml"
        "01-configmap.yaml"
        "02-secrets.yaml"
        "07-database-schema-configmap.yaml"
        "08-agent-db-schema-configmap.yaml"
        "03-postgres-statefulset.yaml"
        "04-scheduler-deployment.yaml"
        "05-ui-deployment.yaml"
        "09-agent-db-deployment.yaml"
        "10-agent-ctl-deployment.yaml"
        "06-ingress.yaml"
    )

    for manifest in "${manifests[@]}"; do
        local file="$SCRIPT_DIR/$manifest"
        if [ -f "$file" ]; then
            log_info "Applying $manifest..."
            kubectl apply -f "$file"
        else
            log_warn "Manifest not found: $manifest"
        fi
    done

    log_success "Manifests applied"
}

restart_deployments() {
    log_info "Restarting deployments..."

    for deployment in "${DEPLOYMENTS[@]}"; do
        log_info "Restarting $deployment..."
        kubectl rollout restart deployment/"$deployment" -n "$NAMESPACE" 2>/dev/null || true
    done

    log_success "Deployments restarted"
}

wait_for_pods() {
    log_info "Waiting for pods to be ready..."

    local timeout=120
    local start_time=$(date +%s)

    while true; do
        local not_ready=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Running\|Completed" | grep -v "Terminating" | wc -l)

        if [ "$not_ready" -eq 0 ]; then
            log_success "All pods are running"
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -ge $timeout ]; then
            log_error "Timeout waiting for pods (${timeout}s)"
            kubectl get pods -n "$NAMESPACE"
            return 1
        fi

        echo -ne "\r${BLUE}[INFO]${NC} Waiting for $not_ready pod(s)... (${elapsed}s/${timeout}s)"
        sleep 2
    done
}

verify_deployment() {
    log_info "Verifying deployment..."

    echo ""
    echo "=== Pods ==="
    kubectl get pods -n "$NAMESPACE"

    echo ""
    echo "=== Deployments ==="
    kubectl get deployments -n "$NAMESPACE"

    echo ""
    echo "=== Services ==="
    kubectl get services -n "$NAMESPACE"

    echo ""
    echo "=== Ingress ==="
    kubectl get ingress -n "$NAMESPACE"

    # Test endpoints
    echo ""
    log_info "Testing endpoints..."

    local endpoints=(
        "http://scheduler.local/|UI"
        "http://scheduler.local/api/v1/health|Scheduler API"
        "http://scheduler.local/admin/api/warehouses|Admin API"
    )

    for endpoint in "${endpoints[@]}"; do
        local url="${endpoint%%|*}"
        local name="${endpoint##*|}"
        local status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || echo "000")

        if [[ "$status" =~ ^2 ]] || [[ "$status" =~ ^3 ]]; then
            log_success "$name ($url): $status"
        else
            log_warn "$name ($url): $status"
        fi
    done
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

Deploy applications to Kubernetes (Docker Desktop)

Commands:
    all         Full deployment: load images, apply manifests, restart (default)
    images      Load Docker images into Kubernetes containerd
    apply       Apply Kubernetes manifests only
    restart     Restart all deployments
    status      Show current deployment status
    verify      Verify deployment and test endpoints
    help        Show this help message

Options:
    -n, --no-restart    Don't restart deployments after applying
    -f, --force         Skip confirmation prompts
    -i, --image NAME    Load only specified image (can be repeated)

Examples:
    $0                      # Full deployment
    $0 images               # Load images only
    $0 apply --no-restart   # Apply manifests without restarting
    $0 -i scheduler:latest  # Load only scheduler image
    $0 status               # Check current status

EOF
}

# Parse arguments
COMMAND="all"
NO_RESTART=false
FORCE=false
SPECIFIC_IMAGES=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--no-restart)
            NO_RESTART=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -i|--image)
            SPECIFIC_IMAGES+=("$2")
            shift 2
            ;;
        all|images|apply|restart|status|verify|help)
            COMMAND=$1
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main execution
case $COMMAND in
    help)
        show_help
        exit 0
        ;;
    status)
        kubectl get pods,deployments,services -n "$NAMESPACE"
        exit 0
        ;;
    verify)
        verify_deployment
        exit 0
        ;;
    images)
        check_prerequisites
        if [ ${#SPECIFIC_IMAGES[@]} -gt 0 ]; then
            for img in "${SPECIFIC_IMAGES[@]}"; do
                load_image "$img"
            done
        else
            load_all_images
        fi
        ;;
    apply)
        check_prerequisites
        apply_manifests
        if [ "$NO_RESTART" = false ]; then
            restart_deployments
            wait_for_pods
        fi
        ;;
    restart)
        restart_deployments
        wait_for_pods
        ;;
    all)
        check_prerequisites

        if [ ${#SPECIFIC_IMAGES[@]} -gt 0 ]; then
            for img in "${SPECIFIC_IMAGES[@]}"; do
                load_image "$img"
            done
        else
            load_all_images
        fi

        apply_manifests

        if [ "$NO_RESTART" = false ]; then
            restart_deployments
        fi

        wait_for_pods
        verify_deployment
        ;;
esac

echo ""
log_success "Done!"
