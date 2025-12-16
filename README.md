# Agent Scheduler Kubernetes Deployment

Kubernetes manifests for deploying the Agent Scheduler system, including the scheduler backend, UI frontend, agent database API, and admin control panel.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Ingress (nginx)                          │
│                  scheduler.local                             │
├──────────────┬──────────────┬──────────────┬────────────────┤
│ /admin/api/* │   /admin/*   │   /api/*     │      /*        │
│  (rewrite)   │              │              │                │
└──────┬───────┴──────┬───────┴──────┬───────┴────────┬───────┘
       │              │              │                │
       ▼              ▼              ▼                ▼
┌────────────┐ ┌────────────┐ ┌────────────┐ ┌──────────────┐
│ agent-db-  │ │ agent-ctl- │ │ scheduler- │ │ ui-service   │
│ service    │ │ service    │ │ service    │ │              │
│ :8000      │ │ :3000      │ │ :8000      │ │ :80          │
└─────┬──────┘ └────────────┘ └─────┬──────┘ └──────────────┘
      │                             │
      │        ┌────────────────────┘
      │        │
      ▼        ▼
┌──────────────────────┐
│ PostgreSQL           │
│ (StatefulSet)        │
│ :5432                │
└──────────────────────┘
```

## Components

### Core Services

- **Scheduler Backend** (`04-scheduler-deployment.yaml`)
  - Main scheduling engine
  - API endpoints at `/api/*`
  - Port: 8000

- **UI Frontend** (`05-ui-deployment.yaml`)
  - User interface for scheduler
  - Served at root path `/`
  - Port: 80

- **PostgreSQL** (`03-postgres-statefulset.yaml`)
  - Persistent data storage
  - StatefulSet with PVC
  - Port: 5432
  - Database schemas:
    - `scheduler_db` - Main scheduler database (07)
    - `agent_db` - Agent management database (08)

### Agent Management

- **Agent DB API** (`09-agent-db-deployment.yaml`)
  - Agent configuration and management API
  - Accessible via `/admin/api/*` (rewritten to `/`)
  - Port: 8000

- **Agent Control Panel** (`10-agent-ctl-deployment.yaml`)
  - Admin UI for managing agents
  - Accessible at `/admin/*`
  - React application with SSR
  - Port: 3000

### Infrastructure

- **Namespace** (`00-namespace.yaml`)
  - All resources deployed in `agent-scheduler` namespace

- **ConfigMap** (`01-configmap.yaml`)
  - Configuration for scheduler and services

- **Secrets** (`02-secrets.yaml`)
  - Database credentials and sensitive data

- **Ingress** (`06-ingress.yaml`)
  - nginx ingress controller
  - Routes:
    - `/admin/api/*` → agent-db-service (with path rewriting)
    - `/admin/*` → agent-ctl-service
    - `/api/*` → scheduler-service
    - `/` → ui-service

## Prerequisites

- Kubernetes cluster (v1.20+)
- kubectl configured to access the cluster
- nginx ingress controller installed
- Persistent volume support (for PostgreSQL)

## Deployment

### Quick Start

Deploy all components in order:

```bash
# Apply all manifests
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-configmap.yaml
kubectl apply -f 02-secrets.yaml
kubectl apply -f 03-postgres-statefulset.yaml
kubectl apply -f 04-scheduler-deployment.yaml
kubectl apply -f 05-ui-deployment.yaml
kubectl apply -f 06-ingress.yaml
kubectl apply -f 07-database-schema-configmap.yaml
kubectl apply -f 08-agent-db-schema-configmap.yaml
kubectl apply -f 09-agent-db-deployment.yaml
kubectl apply -f 10-agent-ctl-deployment.yaml

# Or apply all at once
kubectl apply -f .
```

### Verify Deployment

```bash
# Check all resources
kubectl get all -n agent-scheduler

# Check pods are running
kubectl get pods -n agent-scheduler

# Check services
kubectl get svc -n agent-scheduler

# Check ingress
kubectl get ingress -n agent-scheduler
```

### Wait for Pods to be Ready

```bash
# Wait for PostgreSQL
kubectl wait --for=condition=ready pod -l app=postgres -n agent-scheduler --timeout=300s

# Wait for scheduler
kubectl wait --for=condition=ready pod -l app=scheduler -n agent-scheduler --timeout=180s

# Wait for agent-ctl
kubectl wait --for=condition=ready pod -l app=agent-ctl -n agent-scheduler --timeout=180s
```

## Accessing the Services

### Configure /etc/hosts

Add the following line to `/etc/hosts`:

```
127.0.0.1 scheduler.local
```

### Service URLs

- **Main UI**: http://scheduler.local/
- **Admin Control Panel**: http://scheduler.local/admin/
- **Scheduler API**: http://scheduler.local/api/
- **Agent DB API**: http://scheduler.local/admin/api/

### Port Forwarding (Development)

If you don't have ingress configured:

```bash
# Scheduler UI
kubectl port-forward -n agent-scheduler svc/ui-service 8080:80

# Scheduler API
kubectl port-forward -n agent-scheduler svc/scheduler-service 8000:8000

# Agent Control UI
kubectl port-forward -n agent-scheduler svc/agent-ctl-service 3000:3000

# Agent DB API
kubectl port-forward -n agent-scheduler svc/agent-db-service 8001:8000

# PostgreSQL
kubectl port-forward -n agent-scheduler svc/postgres-service 5432:5432
```

## Configuration

### Environment Variables

Key environment variables can be configured in ConfigMaps and Secrets:

**ConfigMap** (`01-configmap.yaml`):
- Database connection settings
- Service URLs
- Application configuration

**Secrets** (`02-secrets.yaml`):
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_DB`

### Database Schemas

Database schemas are automatically initialized via init containers:

- **Scheduler Schema** (`07-database-schema-configmap.yaml`)
  - Tables for scheduling, tasks, executions

- **Agent Schema** (`08-agent-db-schema-configmap.yaml`)
  - Tables for agents, warehouses, assignments, schedules, logs

## Resource Requirements

### Default Resource Limits

| Service | CPU Request | Memory Request | CPU Limit | Memory Limit |
|---------|------------|----------------|-----------|--------------|
| PostgreSQL | 250m | 256Mi | 1000m | 1Gi |
| Scheduler | 100m | 128Mi | 500m | 512Mi |
| UI | 50m | 64Mi | 200m | 256Mi |
| Agent DB API | 100m | 128Mi | 500m | 512Mi |
| Agent CTL | 100m | 128Mi | 500m | 512Mi |

## Ingress Configuration

The ingress is configured with path-based routing:

### Admin API Path Rewriting

```yaml
# /admin/api/warehouses → agent-db-service/warehouses
path: /admin/api(/|$)(.*)
annotation: nginx.ingress.kubernetes.io/rewrite-target: /$2
```

### Admin UI (No Rewriting)

```yaml
# /admin/ → agent-ctl-service/admin/
path: /admin
# No rewrite annotation - path preserved
```

## Troubleshooting

### Check Pod Logs

```bash
# Scheduler logs
kubectl logs -n agent-scheduler deployment/scheduler --tail=50

# Agent CTL logs
kubectl logs -n agent-scheduler deployment/agent-ctl --tail=50

# Agent DB API logs
kubectl logs -n agent-scheduler deployment/agent-db-api --tail=50

# PostgreSQL logs
kubectl logs -n agent-scheduler statefulset/postgres --tail=50
```

### Check Pod Status

```bash
# Describe pod for events
kubectl describe pod -n agent-scheduler <pod-name>

# Check if init containers ran successfully
kubectl get pods -n agent-scheduler -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.initContainerStatuses[*].state}{"\n"}{end}'
```

### Database Connection Issues

```bash
# Test PostgreSQL connectivity
kubectl exec -it -n agent-scheduler postgres-0 -- psql -U scheduler_user -d scheduler_db -c '\dt'

# Check database logs
kubectl logs -n agent-scheduler statefulset/postgres --tail=100
```

### Ingress Issues

```bash
# Check ingress configuration
kubectl describe ingress -n agent-scheduler

# Check ingress controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --tail=50
```

## Updating Deployments

### Update Docker Images

After building new images:

```bash
# Import image to cluster (kind example)
docker save image-name:tag | docker exec -i kind-control-plane ctr --namespace k8s.io images import -

# Restart deployment
kubectl rollout restart deployment/deployment-name -n agent-scheduler

# Check rollout status
kubectl rollout status deployment/deployment-name -n agent-scheduler
```

### Update Configuration

```bash
# Edit ConfigMap
kubectl edit configmap agent-scheduler-config -n agent-scheduler

# Restart affected deployments
kubectl rollout restart deployment/scheduler -n agent-scheduler
```

## Cleanup

### Delete All Resources

```bash
# Delete all resources in namespace
kubectl delete namespace agent-scheduler
```

### Delete Individual Components

```bash
# Delete specific deployment
kubectl delete -f 10-agent-ctl-deployment.yaml

# Delete ingress
kubectl delete -f 06-ingress.yaml
```

## Contributing

When making changes to the Kubernetes manifests:

1. Test changes in a development cluster
2. Verify all pods are running and healthy
3. Test all service endpoints
4. Update this README if adding new components
5. Commit changes with descriptive messages

## License

[Your License Here]
