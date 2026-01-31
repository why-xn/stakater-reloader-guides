# How to Use Reloader with Vault CSI Driver (K8s Secret) Pattern

This guide explains how to set up HashiCorp Vault with the Secrets Store CSI Driver using Kubernetes authentication, combined with Stakater Reloader for automatic pod restarts when secrets change. This pattern uses `secretObjects` to sync CSI-mounted secrets into a Kubernetes Secret, which Reloader then watches.

> **See also:** [CSI Driver File-Based Pattern](vault-csi-file.md) - an alternative that skips the K8s Secret entirely and uses Reloader's CSI integration to watch `SecretProviderClassPodStatus` directly.

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
│  │  │  - Reads secrets from env vars (K8s Secret)                     │   │ │
│  │  │  - Optionally reads secrets from mounted files                  │   │ │
│  │  │                                                                  │   │ │
│  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  │                              │                                          │ │
│  │                              ▼                                          │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │ │
│  │  │  CSI Volume Mount (/mnt/secrets)                                │   │ │
│  │  │  - username                                                      │   │ │
│  │  │  - password                                                      │   │ │
│  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                       │
│            ┌─────────────────────────┼─────────────────────────┐            │
│            ▼                         ▼                         ▼            │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐      │
│  │  Vault CSI       │    │   K8s Secret     │    │  Stakater        │      │
│  │  Provider        │───►│   (app-secrets)  │───►│  Reloader        │      │
│  │                  │    │                  │    │                  │      │
│  │  - Authenticates │    │  annotation:     │    │  Watches secret  │      │
│  │    via K8s auth  │    │  reloader.../    │    │  changes and     │      │
│  │  - Fetches from  │    │  match: "true"   │    │  restarts pods   │      │
│  │    Vault KV v2   │    │                  │    │                  │      │
│  │  - Syncs via     │    │  (secretObjects) │    │                  │      │
│  │    secretObjects │    │                  │    │                  │      │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘      │
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

## Prerequisites

Complete the common setup steps from the [README](../README.md):
- Vault installed, initialized, and unsealed
- Vault CLI configured
- KV v2 secrets engine enabled
- Test secrets written to `secret/myapp`
- Read policy (`myapp-read`) created
- Stakater Reloader installed

Additionally required:
- Secrets Store CSI Driver installed with `syncSecret.enabled=true`
- Vault CSI Provider installed

### Install Secrets Store CSI Driver

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true \
  --set rotationPollInterval=30s
```

**Important:** `syncSecret.enabled=true` is required for the CSI driver to create Kubernetes Secrets from mounted volumes. Without this, the `secretObjects` field will not work.

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
vault write auth/kubernetes/role/csi-role \
  bound_service_account_names=vault-csi-sa \
  bound_service_account_namespaces=vault-csi-test \
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
kubectl create namespace vault-csi-test
kubectl create serviceaccount vault-csi-sa -n vault-csi-test
```

## Step 6: Create SecretProviderClass

Create `secret-provider-class.yaml`:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-secrets
  namespace: vault-csi-test
spec:
  provider: vault
  # Sync to Kubernetes Secret - Required for Reloader integration
  secretObjects:
    - secretName: app-secrets
      type: Opaque
      annotations:
        reloader.stakater.com/match: "true"
      data:
        - key: username
          objectName: username
        - key: password
          objectName: password
  parameters:
    vaultAddress: "http://vault.vault.svc.cluster.local:8200"
    roleName: "csi-role"
    objects: |
      - objectName: "username"
        secretPath: "secret/data/myapp"
        secretKey: "username"
      - objectName: "password"
        secretPath: "secret/data/myapp"
        secretKey: "password"
```

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
  name: vault-csi-test-app
  namespace: vault-csi-test
  annotations:
    reloader.stakater.com/search: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault-csi-test-app
  template:
    metadata:
      labels:
        app: vault-csi-test-app
    spec:
      serviceAccountName: vault-csi-sa
      containers:
        - name: app
          image: busybox:latest
          command:
            - "sh"
            - "-c"
            - |
              while true; do
                echo "Username: $APP_USERNAME"
                echo "Password: $APP_PASSWORD"
                sleep 30
              done
          # Reference secrets from K8s Secret (required for Reloader)
          env:
            - name: APP_USERNAME
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: username
            - name: APP_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: password
          # CSI volume mount required to trigger secret sync
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
kubectl get pods -n vault-csi-test
```

Pod should be Running.

### Check SecretProviderClassPodStatus

```bash
kubectl get secretproviderclasspodstatuses -n vault-csi-test
```

### Verify Secrets are Populated

```bash
# Check K8s Secret was created
kubectl get secret app-secrets -n vault-csi-test -o jsonpath='{.data.password}' | base64 -d

# Check app logs
kubectl logs -n vault-csi-test -l app=vault-csi-test-app
```

## Step 9: Test Secret Rotation

### Update Secret in Vault

```bash
vault kv put secret/myapp \
  username="admin-user" \
  password="new-rotated-password"
```

### Wait and Verify

Wait 30-60 seconds for CSI rotation and Reloader restart:

```bash
# Check secret was updated
kubectl get secret app-secrets -n vault-csi-test -o jsonpath='{.data.password}' | base64 -d

# Check pod was restarted (new pod name)
kubectl get pods -n vault-csi-test -l app=vault-csi-test-app
```

## Key Configuration Points

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
| `objectName` | Name of the mounted file and key in `secretObjects` |
| `secretPath` | Full Vault path (KV v2: `secret/data/<path>`) |
| `secretKey` | Specific field within the Vault secret |

### secretObjects Configuration

The `secretObjects` field syncs mounted secrets to a Kubernetes Secret:

```yaml
secretObjects:
  - secretName: app-secrets
    type: Opaque
    annotations:
      reloader.stakater.com/match: "true"
    data:
      - key: username
        objectName: username  # Must match objectName in parameters.objects
      - key: password
        objectName: password
```

### Reloader Annotations

| Resource | Annotation |
|----------|------------|
| Deployment | `reloader.stakater.com/search: "true"` |
| Secret | `reloader.stakater.com/match: "true"` (via `secretObjects`) |

### Why CSI Volume Mount is Required

Even if your app only uses environment variables from the K8s Secret, the CSI volume must be mounted because:
1. The CSI driver only syncs secrets when a pod mounts the volume
2. Without the mount, the K8s Secret (`secretObjects`) won't be created

## Manifest Files

All manifests are available in `../manifests/csi/`:
- `vault-policy.hcl` - Vault read policy
- `secret-provider-class.yaml` - SecretProviderClass configuration
- `deployment.yaml` - Application deployment
