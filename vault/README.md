# How to Use Reloader with HashiCorp Vault

This guide shows how to automatically restart Kubernetes workloads when HashiCorp Vault secrets change using Stakater Reloader.

## Integration Patterns

| Pattern | How Secrets Arrive | Rotation | Reloader Compatibility | Guide |
|---------|-------------------|----------|------------------------|-------|
| **External Secrets Operator** | ESO syncs to K8s Secret | ESO refresh interval | Best fit | [ESO Guide](docs/vault-eso.md) |
| **Vault Secrets Operator** | VSO syncs to K8s Secret | VSO refresh interval | Best fit | [VSO Guide](docs/vault-vso.md) |
| **CSI Driver** | CSI mounts files + syncs to K8s Secret | CSI rotation interval | Works with secretObjects | [CSI Guide](docs/vault-csi.md) |
| **CSI Driver (File-Based)** | CSI mounts secrets as files only | CSI rotation interval | Watches SecretProviderClassPodStatus | [CSI File Guide](docs/vault-csi-file.md) |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Vault + Reloader Architecture                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Vault Server (vault namespace):                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  HashiCorp Vault                                                       │ │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐    │ │
│  │  │ KV v2 Engine     │  │ Kubernetes Auth  │  │ AppRole Auth     │    │ │
│  │  │ secret/myapp     │  │ (k8s SA tokens)  │  │ (RoleID/SecretID)│    │ │
│  │  └──────────────────┘  └──────────────────┘  └──────────────────┘    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              ▼                                               │
│  Application Namespace:                                                      │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Secret Sync (ESO / VSO / CSI)                                         │ │
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
- HashiCorp Vault (OSS or Enterprise)
- Vault CLI installed locally
- Stakater Reloader installed
- kubectl configured with cluster access

### Install Stakater Reloader

```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm install reloader stakater/reloader --namespace reloader --create-namespace
```

## Common Setup Steps

### Step 1: Install Vault

```bash
# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install Vault
helm install vault hashicorp/vault -n vault --create-namespace \
  --set "server.dataStorage.size=1Gi" \
  --set "injector.enabled=false"
```

> **Note:** The injector is disabled because this guide uses ESO, VSO, or CSI to sync secrets. Enable it if you also need Vault Agent sidecar injection.

Wait for the pod to start (it will be Running but not Ready until unsealed):

```bash
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 -n vault --timeout=180s
```

### Step 2: Initialize and Unseal Vault

```bash
# Initialize Vault (using 1 key share for simplicity; use more in production)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > vault-init.json
```

**Important:** Save `vault-init.json` securely. It contains the unseal key and root token.

```bash
# Extract unseal key and root token
VAULT_UNSEAL_KEY=$(cat vault-init.json | jq -r '.unseal_keys_b64[0]')
VAULT_ROOT_TOKEN=$(cat vault-init.json | jq -r '.root_token')

# Unseal Vault
kubectl exec -n vault vault-0 -- vault operator unseal "$VAULT_UNSEAL_KEY"
```

Vault should now show `Sealed: false`. Wait for the pod to become Ready:

```bash
kubectl wait --for=condition=ready pod/vault-0 -n vault --timeout=30s
```

### Step 3: Configure Vault CLI

```bash
# Port-forward for local CLI access
kubectl port-forward -n vault svc/vault 8200:8200 &

# Configure CLI (use the root token from Step 2)
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="$VAULT_ROOT_TOKEN"
```

### Step 4: Enable KV v2 Secrets Engine

```bash
vault secrets enable -path=secret kv-v2
```

Verify:

```bash
vault secrets list
```

You should see `secret/` listed as `kv` version 2.

### Step 5: Write Test Secrets

```bash
vault kv put secret/myapp \
  username="admin-user" \
  password="super-secret-password"
```

Verify:

```bash
vault kv get secret/myapp
```

### Step 6: Create Vault Read Policy

```bash
vault policy write myapp-read - <<EOF
path "secret/data/myapp" {
  capabilities = ["read"]
}
path "secret/metadata/myapp" {
  capabilities = ["read"]
}
EOF
```

### Step 7: Enable Kubernetes Auth

```bash
# Enable Kubernetes auth method
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"
```

### Step 8: Enable AppRole Auth (Optional)

Only required for the [VSO AppRole pattern](docs/vault-vso.md#option-2-approle-authentication).

```bash
vault auth enable approle
```

## How Reloader Works

1. **Secret provider updates K8s Secret** - ESO/VSO/CSI syncs secrets from Vault
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

- [External Secrets Operator Pattern](docs/vault-eso.md) - Token or Kubernetes auth
- [Vault Secrets Operator Pattern](docs/vault-vso.md) - Kubernetes auth or AppRole
- [CSI Driver Pattern](docs/vault-csi.md) - Kubernetes auth
- [CSI Driver File-Based Pattern](docs/vault-csi-file.md) - Kubernetes auth, no K8s Secret

## Using External Vault (Multi-Cluster Setup)

Vault does not need to run inside Kubernetes. A single external Vault instance can serve multiple Kubernetes clusters. This is a common production pattern for centralized secrets management.

### Requirements

1. **Network connectivity** - Pods must be able to reach the external Vault URL
2. **TLS certificates** - Production Vault should use TLS; clusters need the CA certificate
3. **Per-cluster Kubernetes auth configuration** - Each cluster's JWT tokens are unique

### Authentication Methods with External Vault

| Auth Method | Works with External Vault? | Additional Configuration |
|-------------|---------------------------|-------------------------|
| **Token** | Yes | None - just update Vault URL |
| **AppRole** | Yes | None - just update Vault URL |
| **Kubernetes** | Yes | Requires per-cluster auth mount configuration |

### Configuring Kubernetes Auth for External Vault

When Vault runs outside the cluster, it cannot automatically discover the Kubernetes API. You must provide:

```bash
# Create a service account for Vault to validate tokens
kubectl create serviceaccount vault-auth -n kube-system

# Grant token review permissions
kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kube-system:vault-auth

# Get the service account token (for K8s 1.24+, create a secret)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
EOF

# Extract values for Vault configuration
TOKEN_REVIEWER_JWT=$(kubectl get secret vault-auth-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)
KUBE_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')
```

Configure Vault with a separate auth mount per cluster:

```bash
# Enable Kubernetes auth for this cluster
vault auth enable -path=kubernetes-cluster-a kubernetes

# Configure with cluster-specific values
vault write auth/kubernetes-cluster-a/config \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA_CERT" \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT"

# Create role (same as before)
vault write auth/kubernetes-cluster-a/role/myapp-role \
  bound_service_account_names=myapp-sa \
  bound_service_account_namespaces=production \
  policies=myapp-read \
  ttl=1h
```

### Manifest Changes for External Vault

Update the Vault address in your manifests:

**ESO SecretStore:**
```yaml
spec:
  provider:
    vault:
      server: "https://vault.example.com:8200"
      caBundle: "<base64-encoded-ca-cert>"  # For TLS
      path: secret
      auth:
        kubernetes:
          mountPath: kubernetes-cluster-a  # Cluster-specific mount
          role: myapp-role
```

**VSO VaultConnection:**
```yaml
spec:
  address: "https://vault.example.com:8200"
  caCertSecretRef:
    name: vault-ca-cert
    key: ca.crt
```

**VSO VaultAuth (with external Vault):**
```yaml
spec:
  method: kubernetes
  mount: kubernetes-cluster-a  # Cluster-specific mount
  kubernetes:
    role: myapp-role
    serviceAccount: myapp-sa
```

**CSI SecretProviderClass:**
```yaml
parameters:
  vaultAddress: "https://vault.example.com:8200"
  vaultCACertPath: "/vault/tls/ca.crt"  # Or use vaultSkipTLSVerify for testing
  roleName: myapp-role
```

### Multi-Cluster Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         External Vault Server                                │
│                      (https://vault.example.com:8200)                       │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐    │ │
│  │  │ KV v2 Engine     │  │ kubernetes-      │  │ kubernetes-      │    │ │
│  │  │ secret/myapp     │  │ cluster-a/       │  │ cluster-b/       │    │ │
│  │  │                  │  │ (auth mount)     │  │ (auth mount)     │    │ │
│  │  └──────────────────┘  └──────────────────┘  └──────────────────┘    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
          │                           │                           │
          ▼                           ▼                           ▼
┌──────────────────┐       ┌──────────────────┐       ┌──────────────────┐
│  Cluster A       │       │  Cluster B       │       │  Cluster C       │
│  (Production)    │       │  (Staging)       │       │  (Dev)           │
│                  │       │                  │       │                  │
│  ESO / VSO / CSI │       │  ESO / VSO / CSI │       │  ESO / VSO / CSI │
│  + Reloader      │       │  + Reloader      │       │  + Reloader      │
└──────────────────┘       └──────────────────┘       └──────────────────┘
```

## References

- [Stakater Reloader](https://github.com/stakater/Reloader)
- [HashiCorp Vault Documentation](https://developer.hashicorp.com/vault/docs)
- [Vault Helm Chart](https://developer.hashicorp.com/vault/docs/platform/k8s/helm)
- [External Secrets Operator - Vault Provider](https://external-secrets.io/latest/provider/hashicorp-vault/)
- [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso)
- [Vault CSI Provider](https://developer.hashicorp.com/vault/docs/platform/k8s/csi)
