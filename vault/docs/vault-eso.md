# How to Use Reloader with Vault External Secrets Operator Pattern

This guide explains how to set up HashiCorp Vault with the External Secrets Operator (ESO), combined with Stakater Reloader for automatic pod restarts when secrets change.

## Authentication Options

ESO supports two authentication methods with Vault:

| Method | Description | Use Case |
|--------|-------------|----------|
| [**Token**](#option-1-token-authentication) | Uses a Vault token stored in a K8s Secret | Simpler setup, good for development |
| [**Kubernetes Auth**](#option-2-kubernetes-authentication) | Uses Kubernetes ServiceAccount tokens for authentication | More secure, no static credentials, recommended for production |

Choose the authentication method that best fits your security requirements and proceed to the corresponding section.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Kubernetes Cluster                                 │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                    External Secrets Operator                            │ │
│  │                                                                         │ │
│  │  ┌─────────────────┐         ┌──────────────────────────────────────┐  │ │
│  │  │  SecretStore    │         │  ExternalSecret                      │  │ │
│  │  │                 │         │                                      │  │ │
│  │  │  - Vault URL    │         │  - refreshInterval: 30s              │  │ │
│  │  │  - Auth Method  │────────►│  - Maps Vault KV to K8s Secret       │  │ │
│  │  │  - KV v2 path   │         │  - Adds Reloader annotation          │  │ │
│  │  │                 │         │                                      │  │ │
│  │  └─────────────────┘         └──────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                       │
│                                      ▼                                       │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐       │
│  │   K8s Secret     │    │  Stakater        │    │  Application     │       │
│  │   (app-secrets)  │───►│  Reloader        │───►│  Pod             │       │
│  │                  │    │                  │    │                  │       │
│  │  annotation:     │    │  Watches secret  │    │  Reads secrets   │       │
│  │  reloader.../    │    │  changes and     │    │  from env vars   │       │
│  │  match: "true"   │    │  restarts pods   │    │                  │       │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘       │
│            ▲                                                                 │
│            │                                                                 │
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
- External Secrets Operator installed

### Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --wait
```

Verify installation:

```bash
kubectl get pods -n external-secrets
```

---

# Option 1: Token Authentication

This section covers setting up ESO with Vault token authentication. This method stores a Vault token in a Kubernetes Secret.

## Token: Step 1 - Create Vault Policy

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

## Token: Step 2 - Write Secrets

```bash
vault kv put secret/myapp \
  username="admin-user" \
  password="super-secret-password"
```

## Token: Step 3 - Create Vault Token

Create a token with the read policy:

```bash
vault token create \
  -policy=myapp-read \
  -period=24h \
  -display-name=eso-token
```

**Important:** Save the `token` value from the output. You'll need it in the next step.

Example output:
```
Key                  Value
---                  -----
token                hvs.CAESI...
token_accessor       abc123...
token_duration       24h
token_renewable      true
token_policies       ["default", "myapp-read"]
```

## Token: Step 4 - Create Application Namespace and Token Secret

```bash
# Create namespace
kubectl create namespace vault-eso-test

# Create token secret for ESO
# Replace <VAULT_TOKEN> with the token from Step 3
kubectl create secret generic vault-token -n vault-eso-test \
  --from-literal=token="<VAULT_TOKEN>"
```

## Token: Step 5 - Create SecretStore

Create `secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-secret-store
  namespace: vault-eso-test
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          key: token
```

Apply and verify:

```bash
kubectl apply -f secret-store.yaml
kubectl get secretstore -n vault-eso-test
```

Should show `STATUS: Valid` and `READY: True`.

Now proceed to [Create ExternalSecret](#create-externalsecret) section.

---

# Option 2: Kubernetes Authentication

This section covers setting up ESO with Vault Kubernetes authentication. This method uses Kubernetes ServiceAccount tokens to authenticate with Vault - no static credentials required.

## K8s Auth: Step 1 - Create Vault Policy

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

## K8s Auth: Step 2 - Enable and Configure Kubernetes Auth

```bash
# Enable Kubernetes auth method (skip if already enabled)
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"
```

## K8s Auth: Step 3 - Create Vault Role

```bash
vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=vault-eso-sa \
  bound_service_account_namespaces=vault-eso-test \
  policies=myapp-read \
  ttl=1h
```

## K8s Auth: Step 4 - Write Secrets

```bash
vault kv put secret/myapp \
  username="admin-user" \
  password="super-secret-password"
```

## K8s Auth: Step 5 - Create Application Namespace and ServiceAccount

```bash
# Create namespace
kubectl create namespace vault-eso-test

# Create service account for ESO to use
kubectl create serviceaccount vault-eso-sa -n vault-eso-test
```

## K8s Auth: Step 6 - Create SecretStore

Create `secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-secret-store
  namespace: vault-eso-test
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso-role"
          serviceAccountRef:
            name: vault-eso-sa
```

Apply and verify:

```bash
kubectl apply -f secret-store.yaml
kubectl get secretstore -n vault-eso-test
```

Should show `STATUS: Valid` and `READY: True`.

Now proceed to [Create ExternalSecret](#create-externalsecret) section.

---

# Common Configuration

The following sections apply to both authentication methods.

## Create ExternalSecret

Create `external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: vault-eso-test
spec:
  refreshInterval: 30s
  secretStoreRef:
    name: vault-secret-store
    kind: SecretStore
  target:
    name: app-secrets
    creationPolicy: Owner
    template:
      metadata:
        annotations:
          # Reloader annotation - triggers restart on workloads with search: "true"
          reloader.stakater.com/match: "true"
  data:
    - secretKey: username
      remoteRef:
        key: secret/data/myapp
        property: username
    - secretKey: password
      remoteRef:
        key: secret/data/myapp
        property: password
```

Apply and verify:

```bash
kubectl apply -f external-secret.yaml
kubectl get externalsecret -n vault-eso-test
```

Should show `STATUS: SecretSynced` and `READY: True`.

## Deploy Application

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-eso-test-app
  namespace: vault-eso-test
  annotations:
    reloader.stakater.com/search: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault-eso-test-app
  template:
    metadata:
      labels:
        app: vault-eso-test-app
    spec:
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
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

## Verify the Setup

```bash
# SecretStore
kubectl get secretstore -n vault-eso-test

# ExternalSecret
kubectl get externalsecret -n vault-eso-test

# Secret (created by ESO)
kubectl get secret app-secrets -n vault-eso-test

# Pod
kubectl get pods -n vault-eso-test

# Verify secret contents
kubectl get secret app-secrets -n vault-eso-test -o jsonpath='{.data.password}' | base64 -d

# Check app logs
kubectl logs -n vault-eso-test -l app=vault-eso-test-app
```

## Test Secret Rotation

### Update Secret in Vault

```bash
vault kv put secret/myapp \
  username="admin-user" \
  password="new-rotated-password"
```

### Wait and Verify

Wait 30-60 seconds for ESO refresh and Reloader restart:

```bash
# Check secret was updated
kubectl get secret app-secrets -n vault-eso-test -o jsonpath='{.data.password}' | base64 -d

# Check pod was restarted (new pod name)
kubectl get pods -n vault-eso-test -l app=vault-eso-test-app

# Check app logs show new password
kubectl logs -n vault-eso-test -l app=vault-eso-test-app --tail=5
```

---

# Configuration Reference

## SecretStore Configuration

### Token Authentication

| Field | Description |
|-------|-------------|
| `server` | Vault server URL |
| `path` | KV secrets engine mount path (e.g., `secret`) |
| `version` | KV engine version (`v2`) |
| `auth.tokenSecretRef.name` | Name of K8s Secret containing Vault token |
| `auth.tokenSecretRef.key` | Key in the Secret containing the token value |

### Kubernetes Authentication

| Field | Description |
|-------|-------------|
| `server` | Vault server URL |
| `path` | KV secrets engine mount path (e.g., `secret`) |
| `version` | KV engine version (`v2`) |
| `auth.kubernetes.mountPath` | Vault auth mount path (e.g., `kubernetes`) |
| `auth.kubernetes.role` | Vault role name bound to the ServiceAccount |
| `auth.kubernetes.serviceAccountRef.name` | Kubernetes ServiceAccount name |

## ExternalSecret Configuration

| Field | Description |
|-------|-------------|
| `refreshInterval` | How often ESO syncs secrets from Vault (e.g., `30s`) |
| `secretStoreRef` | Reference to the SecretStore |
| `target.name` | Name of the K8s Secret to create |
| `target.template.metadata.annotations` | Annotations to add to the created Secret |
| `data[].secretKey` | Key name in the K8s Secret |
| `data[].remoteRef.key` | Path in Vault (KV v2: `secret/data/<path>`) |
| `data[].remoteRef.property` | Specific field within the Vault secret |

## Reloader Annotations

| Resource | Annotation |
|----------|------------|
| Deployment | `reloader.stakater.com/search: "true"` |
| Secret (via ExternalSecret template) | `reloader.stakater.com/match: "true"` |

---

# Comparison: Token vs Kubernetes Authentication

| Aspect | Token | Kubernetes Auth |
|--------|-------|-----------------|
| **Credentials** | Static token stored in K8s Secret | Dynamic tokens from ServiceAccount |
| **Security** | Token must be manually rotated | No static secrets, tokens auto-rotate |
| **Setup Complexity** | Simpler - just create a token | Requires Vault K8s auth configuration |
| **Vault Config** | Policy + token | Policy + auth method + role |
| **Best For** | Development, simple setups | Production, security-conscious environments |

---

# Manifest Files

## Token Authentication

All manifests are available in `../manifests/eso-token/`:
- `vault-policy.hcl` - Vault read policy
- `secret-store.yaml` - ESO SecretStore with token auth
- `external-secret.yaml` - ESO ExternalSecret configuration
- `deployment.yaml` - Application deployment

## Kubernetes Authentication

All manifests are available in `../manifests/eso-k8s-auth/`:
- `vault-policy.hcl` - Vault read policy
- `secret-store.yaml` - ESO SecretStore with Kubernetes auth
- `external-secret.yaml` - ESO ExternalSecret configuration
- `deployment.yaml` - Application deployment
