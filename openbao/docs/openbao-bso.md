# How to Use Reloader with OpenBao Secrets Operator Pattern

This guide explains how to set up OpenBao with the OpenBao Secrets Operator (BSO), combined with Stakater Reloader for automatic pod restarts when secrets change.

> **Note:** The OpenBao Secrets Operator uses CRDs with "Vault" naming (VaultConnection, VaultAuth, VaultStaticSecret) for API compatibility. This is expected behavior - OpenBao is API-compatible with HashiCorp Vault.

## Authentication Options

BSO supports multiple authentication methods with OpenBao:

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
│  │                    OpenBao Secrets Operator                             │ │
│  │                                                                         │ │
│  │  ┌─────────────────┐  ┌────────────┐  ┌────────────────────────────┐  │ │
│  │  │ VaultConnection │  │ VaultAuth  │  │ VaultStaticSecret          │  │ │
│  │  │                 │  │            │  │                            │  │ │
│  │  │ - OpenBao addr  │─►│ - K8s Auth │─►│ - mount: secret            │  │ │
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
│  │    OpenBao       │                                                       │
│  │    Server        │                                                       │
│  │                  │                                                       │
│  │  KV v2 engine   │                                                       │
│  └──────────────────┘                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

Complete the common setup steps from the [README](../README.md):
- OpenBao installed, initialized, and unsealed
- OpenBao CLI configured
- KV v2 secrets engine enabled
- Test secrets written to `secret/myapp`
- Read policy (`myapp-read`) created
- Stakater Reloader installed

Additionally required:
- OpenBao Secrets Operator installed

### Install OpenBao Secrets Operator

```bash
kubectl apply -k "https://github.com/openbao/openbao-secrets-operator//config/default?ref=main"
```

Verify installation:

```bash
kubectl get pods -n vault-secrets-operator-system
```

---

# Option 1: Kubernetes Authentication

This section covers setting up BSO with OpenBao Kubernetes authentication. This method uses Kubernetes ServiceAccount tokens to authenticate with OpenBao.

## K8s Auth: Step 1 - Create OpenBao Policy

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao policy write myapp-read - <<EOF
path \"secret/data/myapp\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/myapp\" {
  capabilities = [\"read\"]
}
EOF"
```

## K8s Auth: Step 2 - Enable and Configure Kubernetes Auth

```bash
# Enable Kubernetes auth method (skip if already enabled)
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao auth enable kubernetes"

# Configure Kubernetes auth
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao write auth/kubernetes/config kubernetes_host='https://kubernetes.default.svc.cluster.local'"
```

## K8s Auth: Step 3 - Create OpenBao Role

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao write auth/kubernetes/role/bso-role \
  bound_service_account_names=openbao-bso-sa \
  bound_service_account_namespaces=openbao-bso-test \
  policies=myapp-read \
  ttl=1h"
```

## K8s Auth: Step 4 - Write Secrets

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao kv put secret/myapp username='admin-user' password='super-secret-password'"
```

## K8s Auth: Step 5 - Create Application Namespace and ServiceAccount

```bash
# Create namespace
kubectl create namespace openbao-bso-test

# Create service account
kubectl create serviceaccount openbao-bso-sa -n openbao-bso-test
```

## K8s Auth: Step 6 - Create VaultConnection

Create `vault-connection.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: openbao-connection
  namespace: openbao-bso-test
spec:
  address: "http://openbao.openbao.svc.cluster.local:8200"
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
  name: openbao-auth
  namespace: openbao-bso-test
spec:
  vaultConnectionRef: openbao-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: bso-role
    serviceAccount: openbao-bso-sa
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
  namespace: openbao-bso-test
spec:
  vaultAuthRef: openbao-auth
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

This section covers setting up BSO with OpenBao AppRole authentication. This method uses a RoleID and SecretID pair.

## AppRole: Step 1 - Create OpenBao Policy

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao policy write myapp-read - <<EOF
path \"secret/data/myapp\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/myapp\" {
  capabilities = [\"read\"]
}
EOF"
```

## AppRole: Step 2 - Enable and Configure AppRole Auth

```bash
# Enable AppRole auth method (skip if already enabled)
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao auth enable approle"

# Create AppRole role
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao write auth/approle/role/bso-role \
  secret_id_ttl=0 \
  token_policies=myapp-read \
  token_ttl=1h \
  token_max_ttl=4h"
```

## AppRole: Step 3 - Get RoleID and SecretID

```bash
# Get RoleID
ROLE_ID=$(kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao read -field=role_id auth/approle/role/bso-role/role-id")
echo "RoleID: $ROLE_ID"

# Generate SecretID
SECRET_ID=$(kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao write -field=secret_id -f auth/approle/role/bso-role/secret-id")
echo "SecretID: $SECRET_ID"
```

**Important:** Save both values. You'll need them in Step 5.

## AppRole: Step 4 - Write Secrets

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao kv put secret/myapp username='admin-user' password='super-secret-password'"
```

## AppRole: Step 5 - Create Application Namespace and AppRole Secret

```bash
# Create namespace
kubectl create namespace openbao-bso-test

# Create Kubernetes Secret with AppRole SecretID
# The secret must have a key named "id" (required by BSO)
# Replace <SECRET_ID> with the SecretID from Step 3
kubectl create secret generic openbao-approle-secret -n openbao-bso-test \
  --from-literal=id="<SECRET_ID>"
```

## AppRole: Step 6 - Create VaultConnection

Create `vault-connection.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: openbao-connection
  namespace: openbao-bso-test
spec:
  address: "http://openbao.openbao.svc.cluster.local:8200"
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
  name: openbao-auth
  namespace: openbao-bso-test
spec:
  vaultConnectionRef: openbao-connection
  method: appRole
  mount: approle
  appRole:
    roleId: <ROLE_ID>
    secretRef: openbao-approle-secret
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
  namespace: openbao-bso-test
spec:
  vaultAuthRef: openbao-auth
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
  name: openbao-bso-test-app
  namespace: openbao-bso-test
  annotations:
    reloader.stakater.com/search: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openbao-bso-test-app
  template:
    metadata:
      labels:
        app: openbao-bso-test-app
    spec:
      serviceAccountName: openbao-bso-sa
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
kubectl get vaultconnection -n openbao-bso-test

# VaultAuth
kubectl get vaultauth -n openbao-bso-test

# VaultStaticSecret
kubectl get vaultstaticsecret -n openbao-bso-test

# Secret (created by BSO)
kubectl get secret app-secrets -n openbao-bso-test

# Pod
kubectl get pods -n openbao-bso-test

# Verify secret contents
kubectl get secret app-secrets -n openbao-bso-test -o jsonpath='{.data.password}' | base64 -d

# Check app logs
kubectl logs -n openbao-bso-test -l app=openbao-bso-test-app
```

## Test Secret Rotation

### Update Secret in OpenBao

```bash
kubectl exec -n openbao openbao-0 -- sh -c "BAO_TOKEN=\$OPENBAO_ROOT_TOKEN bao kv put secret/myapp username='admin-user' password='new-rotated-password'"
```

### Wait and Verify

Wait 30-60 seconds for BSO refresh and Reloader restart:

```bash
# Check secret was updated
kubectl get secret app-secrets -n openbao-bso-test -o jsonpath='{.data.password}' | base64 -d

# Check pod was restarted (new pod name)
kubectl get pods -n openbao-bso-test -l app=openbao-bso-test-app

# Check app logs show new password
kubectl logs -n openbao-bso-test -l app=openbao-bso-test-app --tail=5
```

---

# Configuration Reference

## VaultConnection Configuration

| Field | Description |
|-------|-------------|
| `address` | OpenBao server URL (e.g., `http://openbao.openbao.svc.cluster.local:8200`) |
| `caCertSecretRef` | (Optional) Reference to K8s Secret containing OpenBao CA certificate |
| `tlsServerName` | (Optional) TLS server name for certificate verification |
| `skipTLSVerify` | (Optional) Skip TLS verification (not recommended for production) |

## VaultAuth Configuration

### Kubernetes Authentication

| Field | Description |
|-------|-------------|
| `vaultConnectionRef` | Reference to the VaultConnection resource |
| `method` | Auth method: `kubernetes` |
| `mount` | Auth mount path in OpenBao (e.g., `kubernetes`) |
| `kubernetes.role` | OpenBao role name |
| `kubernetes.serviceAccount` | Kubernetes ServiceAccount name |

### AppRole Authentication

| Field | Description |
|-------|-------------|
| `vaultConnectionRef` | Reference to the VaultConnection resource |
| `method` | Auth method: `appRole` |
| `mount` | Auth mount path in OpenBao (e.g., `approle`) |
| `appRole.roleId` | AppRole RoleID |
| `appRole.secretRef` | Name of K8s Secret containing SecretID (must have a key named `id`) |

## VaultStaticSecret Configuration

| Field | Description |
|-------|-------------|
| `vaultAuthRef` | Reference to the VaultAuth resource |
| `mount` | Secrets engine mount path (e.g., `secret`) |
| `type` | Secrets engine type (`kv-v2` or `kv-v1`) |
| `path` | Secret path within the mount (e.g., `myapp`) |
| `refreshAfter` | How often BSO syncs secrets from OpenBao (e.g., `30s`) |
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
| **Setup Complexity** | Requires OpenBao K8s auth configuration | Requires AppRole setup + secret management |
| **OpenBao Config** | Policy + K8s auth role | Policy + AppRole role |
| **Best For** | In-cluster workloads, production | Cross-cluster setups, CI/CD pipelines |

---

# Manifest Files

## Kubernetes Authentication

All manifests are available in `../manifests/bso-k8s-auth/`:
- `vault-connection.yaml` - VaultConnection resource
- `vault-auth.yaml` - VaultAuth with Kubernetes method
- `vault-static-secret.yaml` - VaultStaticSecret configuration
- `deployment.yaml` - Application deployment

## AppRole Authentication

All manifests are available in `../manifests/bso-approle/`:
- `vault-connection.yaml` - VaultConnection resource
- `vault-auth.yaml` - VaultAuth with AppRole method
- `vault-static-secret.yaml` - VaultStaticSecret configuration
- `deployment.yaml` - Application deployment
