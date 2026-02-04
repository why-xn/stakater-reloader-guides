# How to Use Reloader with OpenBao

This guide shows how to automatically restart Kubernetes workloads when OpenBao secrets change using Stakater Reloader.

## What is OpenBao?

OpenBao is an open-source, community-driven fork of HashiCorp Vault, managed by the Linux Foundation. It was created after HashiCorp changed Vault's license from MPL 2.0 to BSL 1.1. OpenBao maintains API compatibility with Vault, making it a drop-in replacement for most use cases.

## Integration Patterns

| Pattern | How Secrets Arrive | Rotation | Reloader Compatibility | Guide |
|---------|-------------------|----------|------------------------|-------|
| **External Secrets Operator** | ESO syncs to K8s Secret | ESO refresh interval | Best fit | [ESO Guide](docs/openbao-eso.md) |
| **OpenBao Secrets Operator** | BSO syncs to K8s Secret | BSO refresh interval | Best fit | [BSO Guide](docs/openbao-bso.md) |
| **CSI Driver** | CSI mounts files + syncs to K8s Secret | CSI rotation interval | Works with secretObjects | [CSI Guide](docs/openbao-csi.md) |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     OpenBao + Reloader Architecture                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  OpenBao Server (openbao namespace):                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  OpenBao                                                               │ │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐    │ │
│  │  │ KV v2 Engine     │  │ Kubernetes Auth  │  │ AppRole Auth     │    │ │
│  │  │ secret/myapp     │  │ (k8s SA tokens)  │  │ (RoleID/SecretID)│    │ │
│  │  └──────────────────┘  └──────────────────┘  └──────────────────┘    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ▼                                               │
│  Application Namespace:                                                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Secret Sync (ESO / BSO / CSI)                                         │ │
│  │  ┌──────────────────┐    ┌──────────────────┐                         │ │
│  │  │  Operator CRDs   │───►│  K8s Secret      │                         │ │
│  │  │  (SecretStore,   │    │  (app-secrets)   │                         │ │
│  │  │   VaultAuth, etc)│    │  match: "true"   │                         │ │
│  │  └──────────────────┘    └──────────────────┘                         │ │
│  │                                   │                                    │ │
│  │                                   ▼                                    │ │
│  │  ┌──────────────────┐    ┌──────────────────┐                         │ │
│  │  │ Stakater Reloader│───►│  Application Pod │                         │ │
│  │  │ Detects change   │    │  Rolling restart  │                         │ │
│  │  └──────────────────┘    └──────────────────┘                         │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Kubernetes cluster (v1.19+)
- Helm v3+
- OpenBao (OSS)
- OpenBao CLI (`bao`) installed locally (optional)
- Stakater Reloader installed
- kubectl configured with cluster access

### Install Stakater Reloader

```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm install reloader stakater/reloader --namespace reloader --create-namespace
```

## Common Setup Steps

### Step 1: Install OpenBao

```bash
# Add OpenBao Helm repo
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update

# Install OpenBao
helm install openbao openbao/openbao -n openbao --create-namespace \
  --set "server.dataStorage.size=1Gi" \
  --set "injector.enabled=false"
```

> **Note:** The injector is disabled because this guide uses ESO, BSO, or CSI to sync secrets. Enable it if you also need OpenBao Agent sidecar injection.

Wait for the pod to start (it will be Running but not Ready until unsealed):

```bash
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n openbao --timeout=180s
```

### Step 2: Initialize and Unseal OpenBao

```bash
# Initialize OpenBao (using 1 key share for simplicity; use more in production)
kubectl exec -n openbao openbao-0 -- bao operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > openbao-init.json
```

**Important:** Save `openbao-init.json` securely. It contains the unseal key and root token.

```bash
# Extract unseal key and root token
OPENBAO_UNSEAL_KEY=$(cat openbao-init.json | jq -r '.unseal_keys_b64[0]')
OPENBAO_ROOT_TOKEN=$(cat openbao-init.json | jq -r '.root_token')

# Unseal OpenBao
kubectl exec -n openbao openbao-0 -- bao operator unseal "$OPENBAO_UNSEAL_KEY"
```

OpenBao should now show `Sealed: false`. Wait for the pod to become Ready:

```bash
kubectl wait --for=condition=ready pod/openbao-0 -n openbao --timeout=30s
```

### Step 3: Configure OpenBao CLI (Optional)

If you have the `bao` CLI installed locally:

```bash
# Port-forward for local CLI access
kubectl port-forward -n openbao svc/openbao 8200:8200 &

# Configure CLI (use the root token from Step 2)
export BAO_ADDR="http://127.0.0.1:8200"
export BAO_TOKEN="$OPENBAO_ROOT_TOKEN"
```

Alternatively, run commands via kubectl exec:

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=<token> bao <command>"
```

### Step 4: Enable KV v2 Secrets Engine

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=$OPENBAO_ROOT_TOKEN bao secrets enable -path=secret kv-v2"
```

Verify:

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=$OPENBAO_ROOT_TOKEN bao secrets list"
```

You should see `secret/` listed as `kv` version 2.

### Step 5: Write Test Secrets

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=$OPENBAO_ROOT_TOKEN bao kv put secret/myapp username='admin-user' password='super-secret-password'"
```

Verify:

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=$OPENBAO_ROOT_TOKEN bao kv get secret/myapp"
```

### Step 6: Create OpenBao Read Policy

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=$OPENBAO_ROOT_TOKEN bao policy write myapp-read - <<EOF
path \"secret/data/myapp\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/myapp\" {
  capabilities = [\"read\"]
}
EOF"
```

### Step 7: Enable Kubernetes Auth

```bash
# Enable Kubernetes auth method
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=$OPENBAO_ROOT_TOKEN bao auth enable kubernetes"

# Configure Kubernetes auth
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=$OPENBAO_ROOT_TOKEN bao write auth/kubernetes/config kubernetes_host='https://kubernetes.default.svc.cluster.local'"
```

### Step 8: Enable AppRole Auth (Optional)

Only required for the [BSO AppRole pattern](docs/openbao-bso.md#option-2-approle-authentication).

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=$OPENBAO_ROOT_TOKEN bao auth enable approle"
```

## How Reloader Works

1. **Secret provider updates K8s Secret** - ESO/BSO/CSI syncs secrets from OpenBao
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

- [External Secrets Operator Pattern](docs/openbao-eso.md) - Token or Kubernetes auth
- [OpenBao Secrets Operator Pattern](docs/openbao-bso.md) - Kubernetes auth or AppRole
- [CSI Driver Pattern](docs/openbao-csi.md) - Kubernetes auth

## References

- [Stakater Reloader](https://github.com/stakater/Reloader)
- [OpenBao Documentation](https://openbao.org/docs/)
- [OpenBao Helm Chart](https://github.com/openbao/openbao-helm)
- [External Secrets Operator - OpenBao Provider](https://external-secrets.io/latest/provider/openbao/)
- [OpenBao Secrets Operator](https://github.com/openbao/openbao-secrets-operator)
- [OpenBao CSI Provider](https://github.com/openbao/openbao-csi-provider)
