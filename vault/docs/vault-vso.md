# How to Use Reloader with Vault Secrets Operator Pattern

This guide explains how to set up HashiCorp Vault with the Vault Secrets Operator (VSO), combined with Stakater Reloader for automatic pod restarts when secrets change.

## Authentication Options

VSO supports multiple authentication methods with Vault:

| Method | Description | Use Case |
|--------|-------------|----------|
| [**Kubernetes Auth**](#option-1-kubernetes-authentication) | Uses Kubernetes ServiceAccount tokens for authentication | Recommended for production, no static credentials |
| [**AppRole**](#option-2-approle-authentication) | Uses a RoleID and SecretID pair | Good for non-Kubernetes clients or cross-cluster setups |

Choose the authentication method that best fits your security requirements and proceed to the corresponding section.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Kubernetes Cluster                                 │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                    Vault Secrets Operator                               │ │
│  │                                                                         │ │
│  │  ┌─────────────────┐  ┌────────────┐  ┌────────────────────────────┐  │ │
│  │  │ VaultConnection │  │ VaultAuth  │  │ VaultStaticSecret          │  │ │
│  │  │                 │  │            │  │                            │  │ │
│  │  │ - Vault address │─►│ - K8s Auth │─►│ - mount: secret            │  │ │
│  │  │                 │  │   or       │  │ - path: myapp              │  │ │
│  │  │                 │  │ - AppRole  │  │ - refreshAfter: 30s        │  │ │
│  │  │                 │  │            │  │ - Reloader annotation      │  │ │
│  │  └─────────────────┘  └────────────┘  └────────────────────────────┘  │ │
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

> **Note:** VSO has a built-in `rolloutRestartTargets` field on `VaultStaticSecret` that can trigger workload restarts natively. However, using Stakater Reloader provides a **uniform restart mechanism across all secret operators** (ESO, VSO, CSI), which is valuable when running multiple patterns in the same cluster.

## Prerequisites

Complete the common setup steps from the [README](../README.md):
- Vault installed, initialized, and unsealed
- Vault CLI configured
- KV v2 secrets engine enabled
- Test secrets written to `secret/myapp`
- Read policy (`myapp-read`) created
- Stakater Reloader installed

Additionally required:
- Vault Secrets Operator installed

### Install Vault Secrets Operator

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system \
  --create-namespace \
  --wait
```

Verify installation:

```bash
kubectl get pods -n vault-secrets-operator-system
```

---

# Option 1: Kubernetes Authentication

This section covers setting up VSO with Vault Kubernetes authentication. This method uses Kubernetes ServiceAccount tokens to authenticate with Vault.

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
vault write auth/kubernetes/role/vso-role \
  bound_service_account_names=vault-vso-sa \
  bound_service_account_namespaces=vault-vso-test \
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
kubectl create namespace vault-vso-test

# Create service account
kubectl create serviceaccount vault-vso-sa -n vault-vso-test
```

## K8s Auth: Step 6 - Create VaultConnection

Create `vault-connection.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: vault-vso-test
spec:
  address: "http://vault.vault.svc.cluster.local:8200"
```

Apply:

```bash
kubectl apply -f vault-connection.yaml
```

## K8s Auth: Step 7 - Create VaultAuth

Create `vault-auth.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: vault-vso-test
spec:
  vaultConnectionRef: vault-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: vso-role
    serviceAccount: vault-vso-sa
```

Apply:

```bash
kubectl apply -f vault-auth.yaml
```

## K8s Auth: Step 8 - Create VaultStaticSecret

Create `vault-static-secret.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: app-secrets
  namespace: vault-vso-test
spec:
  vaultAuthRef: vault-auth
  mount: secret
  type: kv-v2
  path: myapp
  refreshAfter: 30s
  destination:
    name: app-secrets
    create: true
    annotations:
      reloader.stakater.com/match: "true"
```

Apply:

```bash
kubectl apply -f vault-static-secret.yaml
```

Now proceed to [Deploy Application](#deploy-application) section.

---

# Option 2: AppRole Authentication

This section covers setting up VSO with Vault AppRole authentication. This method uses a RoleID and SecretID pair.

## AppRole: Step 1 - Create Vault Policy

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

## AppRole: Step 2 - Enable and Configure AppRole Auth

```bash
# Enable AppRole auth method (skip if already enabled)
vault auth enable approle

# Create AppRole role
vault write auth/approle/role/vso-role \
  secret_id_ttl=0 \
  token_policies=myapp-read \
  token_ttl=1h \
  token_max_ttl=4h
```

## AppRole: Step 3 - Get RoleID and SecretID

```bash
# Get RoleID
ROLE_ID=$(vault read -field=role_id auth/approle/role/vso-role/role-id)
echo "RoleID: $ROLE_ID"

# Generate SecretID
SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/vso-role/secret-id)
echo "SecretID: $SECRET_ID"
```

**Important:** Save both values. You'll need them in Step 5.

## AppRole: Step 4 - Write Secrets

```bash
vault kv put secret/myapp \
  username="admin-user" \
  password="super-secret-password"
```

## AppRole: Step 5 - Create Application Namespace and AppRole Secret

```bash
# Create namespace
kubectl create namespace vault-vso-test

# Create Kubernetes Secret with AppRole SecretID
# The secret must have a key named "id" (required by VSO)
# Replace <SECRET_ID> with the SecretID from Step 3
kubectl create secret generic vault-approle-secret -n vault-vso-test \
  --from-literal=id="<SECRET_ID>"
```

## AppRole: Step 6 - Create VaultConnection

Create `vault-connection.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: vault-vso-test
spec:
  address: "http://vault.vault.svc.cluster.local:8200"
```

Apply:

```bash
kubectl apply -f vault-connection.yaml
```

## AppRole: Step 7 - Create VaultAuth

Create `vault-auth.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: vault-vso-test
spec:
  vaultConnectionRef: vault-connection
  method: appRole
  mount: approle
  appRole:
    roleId: <ROLE_ID>
    secretRef: vault-approle-secret
```

**Note:** Replace `<ROLE_ID>` with the RoleID from Step 3. The `secretRef` is the name of the K8s Secret created in Step 5, which must contain a key named `id` with the SecretID value.

Apply:

```bash
kubectl apply -f vault-auth.yaml
```

## AppRole: Step 8 - Create VaultStaticSecret

Create `vault-static-secret.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: app-secrets
  namespace: vault-vso-test
spec:
  vaultAuthRef: vault-auth
  mount: secret
  type: kv-v2
  path: myapp
  refreshAfter: 30s
  destination:
    name: app-secrets
    create: true
    annotations:
      reloader.stakater.com/match: "true"
```

Apply:

```bash
kubectl apply -f vault-static-secret.yaml
```

Now proceed to [Deploy Application](#deploy-application) section.

---

# Common Configuration

The following sections apply to both authentication methods.

## Deploy Application

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-vso-test-app
  namespace: vault-vso-test
  annotations:
    reloader.stakater.com/search: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault-vso-test-app
  template:
    metadata:
      labels:
        app: vault-vso-test-app
    spec:
      serviceAccountName: vault-vso-sa
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
# VaultConnection
kubectl get vaultconnection -n vault-vso-test

# VaultAuth
kubectl get vaultauth -n vault-vso-test

# VaultStaticSecret
kubectl get vaultstaticsecret -n vault-vso-test

# Secret (created by VSO)
kubectl get secret app-secrets -n vault-vso-test

# Pod
kubectl get pods -n vault-vso-test

# Verify secret contents
kubectl get secret app-secrets -n vault-vso-test -o jsonpath='{.data.password}' | base64 -d

# Check app logs
kubectl logs -n vault-vso-test -l app=vault-vso-test-app
```

## Test Secret Rotation

### Update Secret in Vault

```bash
vault kv put secret/myapp \
  username="admin-user" \
  password="new-rotated-password"
```

### Wait and Verify

Wait 30-60 seconds for VSO refresh and Reloader restart:

```bash
# Check secret was updated
kubectl get secret app-secrets -n vault-vso-test -o jsonpath='{.data.password}' | base64 -d

# Check pod was restarted (new pod name)
kubectl get pods -n vault-vso-test -l app=vault-vso-test-app

# Check app logs show new password
kubectl logs -n vault-vso-test -l app=vault-vso-test-app --tail=5
```

---

# Configuration Reference

## VaultConnection Configuration

| Field | Description |
|-------|-------------|
| `address` | Vault server URL (e.g., `http://vault.vault.svc.cluster.local:8200`) |
| `caCertSecretRef` | (Optional) Reference to K8s Secret containing Vault CA certificate |
| `tlsServerName` | (Optional) TLS server name for certificate verification |
| `skipTLSVerify` | (Optional) Skip TLS verification (not recommended for production) |

## VaultAuth Configuration

### Kubernetes Authentication

| Field | Description |
|-------|-------------|
| `vaultConnectionRef` | Reference to the VaultConnection resource |
| `method` | Auth method: `kubernetes` |
| `mount` | Auth mount path in Vault (e.g., `kubernetes`) |
| `kubernetes.role` | Vault role name |
| `kubernetes.serviceAccount` | Kubernetes ServiceAccount name |

### AppRole Authentication

| Field | Description |
|-------|-------------|
| `vaultConnectionRef` | Reference to the VaultConnection resource |
| `method` | Auth method: `appRole` |
| `mount` | Auth mount path in Vault (e.g., `approle`) |
| `appRole.roleId` | AppRole RoleID |
| `appRole.secretRef` | Name of K8s Secret containing SecretID (must have a key named `id`) |

## VaultStaticSecret Configuration

| Field | Description |
|-------|-------------|
| `vaultAuthRef` | Reference to the VaultAuth resource |
| `mount` | Secrets engine mount path (e.g., `secret`) |
| `type` | Secrets engine type (`kv-v2` or `kv-v1`) |
| `path` | Secret path within the mount (e.g., `myapp`) |
| `refreshAfter` | How often VSO syncs secrets from Vault (e.g., `30s`) |
| `destination.name` | Name of the K8s Secret to create |
| `destination.create` | Whether to create the Secret if it doesn't exist |
| `destination.annotations` | Annotations to add to the created Secret |

## Reloader Annotations

| Resource | Annotation |
|----------|------------|
| Deployment | `reloader.stakater.com/search: "true"` |
| Secret (via VaultStaticSecret destination) | `reloader.stakater.com/match: "true"` |

---

# Comparison: Kubernetes Auth vs AppRole

| Aspect | Kubernetes Auth | AppRole |
|--------|----------------|---------|
| **Credentials** | Dynamic tokens from ServiceAccount | Static RoleID + rotating SecretID |
| **Security** | No static secrets, tokens auto-rotate | SecretID can be rotated, RoleID is static |
| **Setup Complexity** | Requires Vault K8s auth configuration | Requires AppRole setup + secret management |
| **Vault Config** | Policy + K8s auth role | Policy + AppRole role |
| **Best For** | In-cluster workloads, production | Cross-cluster setups, CI/CD pipelines |

---

# Manifest Files

## Kubernetes Authentication

All manifests are available in `../manifests/vso-k8s-auth/`:
- `vault-policy.hcl` - Vault read policy
- `vault-connection.yaml` - VaultConnection resource
- `vault-auth.yaml` - VaultAuth with Kubernetes method
- `vault-static-secret.yaml` - VaultStaticSecret configuration
- `deployment.yaml` - Application deployment

## AppRole Authentication

All manifests are available in `../manifests/vso-approle/`:
- `vault-policy.hcl` - Vault read policy
- `vault-connection.yaml` - VaultConnection resource
- `vault-auth.yaml` - VaultAuth with AppRole method
- `vault-static-secret.yaml` - VaultStaticSecret configuration
- `deployment.yaml` - Application deployment
