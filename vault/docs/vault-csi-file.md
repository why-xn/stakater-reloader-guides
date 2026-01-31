# How to Use Reloader with Vault CSI Driver (File-Based) Pattern

This guide explains how to set up HashiCorp Vault with the Secrets Store CSI Driver using file-based secrets (no Kubernetes Secret), combined with Stakater Reloader's CSI integration for automatic pod restarts when secrets change.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Kubernetes Cluster                                 │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         Application Pod                                 │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │ │
│  │  │  App Container                                                   │   │ │
│  │  │                                                                  │   │ │
│  │  │  - Reads secrets directly from mounted files                    │   │ │
│  │  │  - No K8s Secret or env vars needed                            │   │ │
│  │  │                                                                  │   │ │
│  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  │                              │                                          │ │
│  │                              ▼                                          │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │ │
│  │  │  CSI Volume Mount (/mnt/secrets)                                │   │ │
│  │  │  - username (file)                                              │   │ │
│  │  │  - password (file)                                              │   │ │
│  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                       │
│            ┌─────────────────────────┴─────────────────────────┐            │
│            ▼                                                   ▼            │
│  ┌──────────────────┐    ┌─────────────────────────────────────────────┐   │
│  │  Vault CSI       │    │  Stakater Reloader                          │   │
│  │  Provider        │    │                                              │   │
│  │                  │    │  Watches SecretProviderClassPodStatus        │   │
│  │  - Authenticates │    │  for version hash changes, then             │   │
│  │    via K8s auth  │    │  triggers rolling restart                   │   │
│  │  - Fetches from  │    │                                              │   │
│  │    Vault KV v2   │    │  Requires: --enable-csi-integration=true    │   │
│  │  - Updates files │    │                                              │   │
│  │    on rotation   │    └─────────────────────────────────────────────┘   │
│  └──────────────────┘                                                       │
│            │                                                                 │
│            ▼                                                                 │
│  ┌──────────────────┐                                                       │
│  │    Vault         │                                                       │
│  │    Server        │                                                       │
│  │                  │                                                       │
│  │  KV v2 engine   │                                                       │
│  └──────────────────┘                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## How This Differs from the K8s Secret CSI Pattern

| Aspect | [CSI + K8s Secret](vault-csi.md) | CSI File-Based (this guide) |
|--------|----------------------------------|----------------------------|
| **Secret delivery** | `secretObjects` syncs to K8s Secret | Secrets mounted as files only |
| **App reads secrets from** | Environment variables (via `secretKeyRef`) | Files on disk (e.g., `/mnt/secrets/password`) |
| **Reloader watches** | K8s Secret changes (`search`/`match` annotations) | `SecretProviderClassPodStatus` version hashes |
| **Reloader flag** | None (default behavior) | `--enable-csi-integration=true` required |
| **Reloader annotation** | `reloader.stakater.com/search` on Deployment | `secretproviderclass.reloader.stakater.com/reload` on Deployment |

> **When to use this pattern:** Choose this when your application reads secrets from files rather than environment variables, or when you want to avoid creating intermediate Kubernetes Secret objects. The CSI driver updates files in-place on the mounted volume during rotation, so the running process can re-read files without a restart. However, if your application caches secrets at startup, Reloader's restart ensures the new values are picked up.

## Prerequisites

Complete the common setup steps from the [README](../README.md):
- Vault installed, initialized, and unsealed
- Vault CLI configured
- KV v2 secrets engine enabled
- Test secrets written to `secret/myapp`
- Read policy (`myapp-read`) created
- Stakater Reloader installed **with `--enable-csi-integration=true`**

Additionally required:
- Secrets Store CSI Driver installed with `enableSecretRotation=true`
- Vault CSI Provider installed

### Install Stakater Reloader with CSI Integration

CSI file-based integration requires the `--enable-csi-integration=true` flag:

```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm install reloader stakater/reloader --namespace reloader --create-namespace \
  --set reloader.deployment.extraArgs.enable-csi-integration=true
```

If Reloader is already installed, upgrade it:

```bash
helm upgrade reloader stakater/reloader --namespace reloader \
  --set reloader.deployment.extraArgs.enable-csi-integration=true
```

### Install Secrets Store CSI Driver

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set enableSecretRotation=true \
  --set rotationPollInterval=30s
```

> **Note:** `syncSecret.enabled` is **not** required for this pattern since we are not creating a Kubernetes Secret via `secretObjects`.

### Install Vault CSI Provider

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault -n vault \
  --set "server.enabled=false" \
  --set "injector.enabled=false" \
  --set "csi.enabled=true"
```

> **Note:** If Vault is already installed in the cluster, install only the CSI provider by setting `server.enabled=false` and `injector.enabled=false`.

## Step 1: Create Vault Policy

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

## Step 2: Enable and Configure Kubernetes Auth

```bash
# Enable Kubernetes auth method (skip if already enabled)
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"
```

## Step 3: Create Vault Role

```bash
vault write auth/kubernetes/role/csi-file-role \
  bound_service_account_names=vault-csi-file-sa \
  bound_service_account_namespaces=vault-csi-file-test \
  policies=myapp-read \
  ttl=1h
```

## Step 4: Write Secrets

```bash
vault kv put secret/myapp \
  username="admin-user" \
  password="super-secret-password"
```

## Step 5: Create Application Namespace and ServiceAccount

```bash
kubectl create namespace vault-csi-file-test
kubectl create serviceaccount vault-csi-file-sa -n vault-csi-file-test
```

## Step 6: Create SecretProviderClass

Create `secret-provider-class.yaml`:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-secrets
  namespace: vault-csi-file-test
spec:
  provider: vault
  parameters:
    vaultAddress: "http://vault.vault.svc.cluster.local:8200"
    roleName: "csi-file-role"
    objects: |
      - objectName: "username"
        secretPath: "secret/data/myapp"
        secretKey: "username"
      - objectName: "password"
        secretPath: "secret/data/myapp"
        secretKey: "password"
```

**Important:** Each object must include `secretKey`. Reloader tracks changes by comparing version hashes of individual objects in the `SecretProviderClassPodStatus`. Without `secretKey`, Reloader may not detect updates correctly.

> **Note:** There is no `secretObjects` field in this configuration. Secrets are delivered purely as files on the CSI volume mount.

Apply:

```bash
kubectl apply -f secret-provider-class.yaml
```

## Step 7: Deploy Application

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-csi-file-test-app
  namespace: vault-csi-file-test
  annotations:
    secretproviderclass.reloader.stakater.com/reload: "vault-secrets"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault-csi-file-test-app
  template:
    metadata:
      labels:
        app: vault-csi-file-test-app
    spec:
      serviceAccountName: vault-csi-file-sa
      containers:
        - name: app
          image: busybox:latest
          command:
            - "sh"
            - "-c"
            - |
              while true; do
                echo "Username: $(cat /mnt/secrets/username)"
                echo "Password: $(cat /mnt/secrets/password)"
                sleep 10
              done
          volumeMounts:
            - name: vault-secrets
              mountPath: /mnt/secrets
              readOnly: true
      volumes:
        - name: vault-secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: vault-secrets
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

## Step 8: Verify the Setup

### Check Pod Status

```bash
kubectl get pods -n vault-csi-file-test
```

Pod should be Running.

### Check SecretProviderClassPodStatus

```bash
kubectl get secretproviderclasspodstatuses -n vault-csi-file-test -o yaml
```

You should see `mounted: true` with version hashes for each object:

```yaml
status:
  mounted: true
  objects:
    - id: password
      version: "7vqIvQ_EK1QRzcRgswkuu_jFo8gie6VFk9BSQ28f59w="
    - id: username
      version: "Oi7gx1M05Zm6xN4CR5FQ-ryYL7iC7OTqO8aXVvVyIAk="
```

### Verify Secrets are Mounted as Files

```bash
# Check files exist on the volume
kubectl exec -n vault-csi-file-test deploy/vault-csi-file-test-app -- ls /mnt/secrets

# Check file contents
kubectl exec -n vault-csi-file-test deploy/vault-csi-file-test-app -- cat /mnt/secrets/username
kubectl exec -n vault-csi-file-test deploy/vault-csi-file-test-app -- cat /mnt/secrets/password

# Check app logs
kubectl logs -n vault-csi-file-test -l app=vault-csi-file-test-app
```

## Step 9: Test Secret Rotation

### Update Secret in Vault

```bash
vault kv put secret/myapp \
  username="new-admin" \
  password="new-rotated-password"
```

### Wait and Verify

Wait 30-60 seconds for CSI rotation and Reloader restart:

```bash
# Check SecretProviderClassPodStatus - version hashes should change
kubectl get secretproviderclasspodstatuses -n vault-csi-file-test -o yaml

# Check pod was restarted (new pod name)
kubectl get pods -n vault-csi-file-test -l app=vault-csi-file-test-app

# Check app logs show new values
kubectl logs -n vault-csi-file-test -l app=vault-csi-file-test-app --tail=5
```

The `SecretProviderClassPodStatus` `generation` field increments and each object's `version` hash changes when its value is updated.

---

## Key Configuration Points

### Reloader CSI Integration

| Setting | Description |
|---------|-------------|
| `--enable-csi-integration=true` | Required Reloader flag to watch `SecretProviderClassPodStatus` |

### Reloader Annotations for CSI

| Annotation | Description |
|------------|-------------|
| `secretproviderclass.reloader.stakater.com/reload: "<name>"` | Restart when the named SecretProviderClass updates |
| `secretproviderclass.reloader.stakater.com/auto: "true"` | Restart when any SecretProviderClass used by the workload updates |
| `reloader.stakater.com/auto: "true"` | Global auto-discovery (includes CSI, Secrets, and ConfigMaps) |

### SecretProviderClass Configuration

| Field | Description |
|-------|-------------|
| `provider` | Must be `vault` |
| `parameters.vaultAddress` | Vault server URL |
| `parameters.roleName` | Vault Kubernetes auth role name |
| `parameters.objects` | YAML string defining which secrets to mount |

### Objects Configuration

Each object in the `parameters.objects` field maps a Vault secret field to a file:

| Field | Description |
|-------|-------------|
| `objectName` | Name of the mounted file |
| `secretPath` | Full Vault path (KV v2: `secret/data/<path>`) |
| `secretKey` | Specific field within the Vault secret (required for Reloader change detection) |

### How Reloader Detects Changes

1. The CSI driver periodically polls Vault for secret updates (controlled by `rotationPollInterval`)
2. When secrets change, the CSI driver updates the files on disk and updates the `SecretProviderClassPodStatus` resource with new version hashes
3. Reloader watches `SecretProviderClassPodStatus` resources and compares version hashes
4. When a hash changes, Reloader triggers a rolling restart of the annotated Deployment

## Manifest Files

All manifests are available in `../manifests/csi-file/`:
- `vault-policy.hcl` - Vault read policy
- `secret-provider-class.yaml` - SecretProviderClass configuration (file-based, no secretObjects)
- `deployment.yaml` - Application deployment with CSI Reloader annotation
