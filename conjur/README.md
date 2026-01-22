# How to Use Reloader with Conjur

This guide shows how to automatically restart Kubernetes workloads when CyberArk Conjur secrets change using Stakater Reloader.

## Integration Patterns

| Pattern | How Secrets Arrive | Rotation | Reloader Compatibility | Guide |
|---------|-------------------|----------|------------------------|-------|
| **External Secrets Operator** | ESO syncs to K8s Secret | ESO refresh interval | Best fit | [ESO Guide](docs/conjur-eso.md) |
| **Sidecar** | Sidecar updates K8s Secret | Sidecar refresh interval | Best fit | [Sidecar Guide](docs/conjur-sidecar.md) |
| **CSI Driver** | CSI mounts files + syncs to K8s Secret | CSI rotation interval | Works with secretObjects | [CSI Guide](docs/conjur-csi.md) |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Golden ConfigMap Architecture                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Cluster Level (conjur namespace):                                           │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  conjur-config-cluster-prep (Helm Chart)                               │ │
│  │  ┌──────────────────┐                                                  │ │
│  │  │ Golden ConfigMap │  Contains: CONJUR_ACCOUNT, CONJUR_APPLIANCE_URL, │ │
│  │  │ (conjur-configmap)│           CONJUR_SSL_CERTIFICATE, etc.          │ │
│  │  └──────────────────┘                                                  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ▼                                               │
│  Application Namespace:                                                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  conjur-config-namespace-prep (Helm Chart)                             │ │
│  │  ┌──────────────────┐                                                  │ │
│  │  │ conjur-connect   │  Copies connection info from Golden ConfigMap    │ │
│  │  │ ConfigMap        │                                                  │ │
│  │  └──────────────────┘                                                  │ │
│  │           │                                                            │ │
│  │           ▼                                                            │ │
│  │  ┌──────────────────────────────────────────────────────────────────┐ │ │
│  │  │                    Application Pod                                │ │ │
│  │  │  ┌─────────────┐         ┌────────────────────────────────────┐ │ │ │
│  │  │  │ App         │         │ Secrets Provider Sidecar           │ │ │ │
│  │  │  │ Container   │         │ - Reads from conjur-connect        │ │ │ │
│  │  │  │             │         │ - Authenticates via JWT            │ │ │ │
│  │  │  │             │         │ - Syncs secrets to K8s Secret      │ │ │ │
│  │  │  └─────────────┘         └────────────────────────────────────┘ │ │ │
│  │  └──────────────────────────────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Kubernetes cluster (v1.19+)
- Helm v3+
- Conjur OSS or Enterprise
- Conjur CLI installed locally
- Stakater Reloader installed
- kubectl configured with cluster access

### Install Stakater Reloader

```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm install reloader stakater/reloader --namespace reloader --create-namespace
```

## Common Setup Steps

### Step 1: Install Conjur OSS

```bash
# Add CyberArk Helm repo
helm repo add cyberark https://cyberark.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace conjur

# Generate data key
DATA_KEY=$(docker run --rm cyberark/conjur data-key generate)

# Install Conjur with authn-jwt enabled
helm install conjur cyberark/conjur-oss -n conjur \
  --set account.name=myaccount \
  --set account.create=true \
  --set dataKey="$DATA_KEY" \
  --set authenticators="authn\,authn-jwt/dev" \
  --set ssl.hostname=conjur-conjur-oss.conjur.svc.cluster.local \
  --wait --timeout 60s
```

### Step 2: Configure Conjur CLI

```bash
# Get admin API key
ADMIN_API_KEY=$(kubectl exec -n conjur deployment/conjur-conjur-oss -c conjur-oss -- \
  conjurctl role retrieve-key myaccount:user:admin)

# Get the Conjur SSL certificate
kubectl get secret -n conjur conjur-conjur-ssl-cert \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > conjur.pem

# Initialize Conjur CLI (assumes Conjur is accessible via port-forward or ingress)
# Option 1: Port-forward for local access
kubectl port-forward -n conjur svc/conjur-conjur-oss 8443:443 &

# Initialize and login
conjur init \
  --url https://localhost:8443 \
  --account myaccount \
  --ca-cert conjur.pem \
  --force

conjur login -i admin -p $ADMIN_API_KEY
```

### Step 3: Install Golden ConfigMap (Cluster Prep)

```bash
CONJUR_SSL_CERT=$(kubectl get secret -n conjur conjur-conjur-ssl-cert \
  -o jsonpath='{.data.tls\.crt}' | base64 -d)

helm install conjur-config-cluster cyberark/conjur-config-cluster-prep -n conjur \
  --set conjur.account=myaccount \
  --set conjur.applianceUrl="https://conjur-conjur-oss.conjur.svc.cluster.local" \
  --set conjur.certificateBase64="$(echo -n "$CONJUR_SSL_CERT" | base64 -w0)" \
  --set authnK8s.authenticatorID=dev \
  --set authnK8s.serviceAccount.create=false
```

## How Reloader Works

1. **Secret Provider updates K8s Secret** - Sidecar/ESO/CSI syncs secrets from Conjur
2. **Reloader detects change** - Watches for Secret changes via Kubernetes API
3. **Pod restart triggered** - Rolling restart of pods referencing the changed Secret

### Reloader Annotations

**On Deployment:**
```yaml
metadata:
  annotations:
    reloader.stakater.com/search: "true"
```

**On Secret (must be annotation, not label):**
```yaml
metadata:
  annotations:
    reloader.stakater.com/match: "true"
```

## Pattern-Specific Guides

- [Sidecar Pattern](docs/conjur-sidecar.md)
- [CSI Driver Pattern](docs/conjur-csi.md)
- [ESO Pattern](docs/conjur-eso.md)

## References

- [Stakater Reloader](https://github.com/stakater/Reloader)
- [CyberArk Conjur Documentation](https://docs.conjur.org/)
- [Conjur CLI Installation](https://docs.conjur.org/Latest/en/Content/Tools/CLI_Install.htm)
- [Conjur Config Cluster Prep](https://github.com/cyberark/conjur-authn-k8s-client/tree/master/helm/conjur-config-cluster-prep)
- [Conjur Config Namespace Prep](https://github.com/cyberark/conjur-authn-k8s-client/tree/master/helm/conjur-config-namespace-prep)
