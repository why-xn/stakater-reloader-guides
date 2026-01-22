# How to Use Reloader with Conjur External Secrets Operator Pattern

This guide explains how to set up CyberArk Conjur with the External Secrets Operator (ESO), combined with Stakater Reloader for automatic pod restarts when secrets change.

## Authentication Options

ESO supports two authentication methods with Conjur:

| Method | Description | Use Case |
|--------|-------------|----------|
| [**API Key**](#option-1-api-key-authentication) | Uses a Conjur host ID and API key stored in a K8s Secret | Simpler setup, good for development |
| [**JWT**](#option-2-jwt-authentication) | Uses Kubernetes ServiceAccount tokens for authentication | More secure, no static credentials, recommended for production |

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
│  │  │  - Conjur URL   │         │  - refreshInterval: 30s              │  │ │
│  │  │  - Auth Method  │────────►│  - Maps Conjur vars to K8s Secret    │  │ │
│  │  │  - CA Bundle    │         │  - Adds Reloader annotation          │  │ │
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
│  │    Conjur        │                                                       │
│  │    Server        │                                                       │
│  │                  │                                                       │
│  │  Stores secrets  │                                                       │
│  └──────────────────┘                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

Complete the common setup steps from the [README](../README.md):
- Conjur OSS installed
- Conjur CLI configured
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

# Option 1: API Key Authentication

This section covers setting up ESO with API key authentication. This method stores a Conjur host ID and API key in a Kubernetes Secret.

## API Key: Step 1 - Load Conjur Policy

Create `conjur-policy.yaml`:

```yaml
# Conjur Policy for External Secrets Operator (API Key Authentication)

# Application Secrets
- !policy
  id: secrets
  body:
    - !group consumers
    - &variables
      - !variable username
      - !variable password
    - !permit
      role: !group consumers
      privilege: [ read, execute ]
      resource: *variables

# Host Identity for External Secrets Operator
- !policy
  id: apps
  body:
    - !host external-secrets

# Grant Host Access to Secrets
- !grant
  role: !group secrets/consumers
  member: !host apps/external-secrets
```

Load the policy and capture the API key:

```bash
conjur policy load -b root -f conjur-policy.yaml
```

**Important:** Save the `api_key` from the output. You'll need it later.

Example output:
```json
{
  "created_roles": {
    "myaccount:host:apps/external-secrets": {
      "id": "myaccount:host:apps/external-secrets",
      "api_key": "3d37q6ph0h2ah3wssa983b1n0gsk8v1hv3b2b74vk7ztmg2b9c992"
    }
  },
  "version": 1
}
```

## API Key: Step 2 - Set Application Secrets

```bash
conjur variable set -i secrets/username -v "admin-user"

conjur variable set -i secrets/password -v "super-secret-password"
```

## API Key: Step 3 - Create Application Namespace and Credentials

```bash
# Create namespace
kubectl create namespace eso-test-app

# Create Conjur credentials secret for ESO
# Replace <API_KEY> with the API key from Step 1
kubectl create secret generic conjur-credentials -n eso-test-app \
  --from-literal=hostId="host/apps/external-secrets" \
  --from-literal=apikey="<API_KEY>"
```

## API Key: Step 4 - Get Conjur CA Certificate

> **Note:** The `caBundle` field is only required if Conjur uses a self-signed or private SSL certificate. If Conjur uses a publicly trusted SSL certificate, you can omit the `caBundle` field from the SecretStore configuration.

```bash
# Get base64-encoded CA certificate (only needed for self-signed/private certificates)
kubectl get secret conjur-conjur-ssl-cert -n conjur -o jsonpath='{.data.tls\.crt}'
```

Save this value for the SecretStore configuration.

## API Key: Step 5 - Create SecretStore

Create `secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: conjur-secret-store
  namespace: eso-test-app
spec:
  provider:
    conjur:
      url: https://conjur-conjur-oss.conjur.svc.cluster.local
      # Paste the base64-encoded CA certificate from Step 4
      caBundle: <BASE64_ENCODED_CA_CERTIFICATE>
      auth:
        apikey:
          account: myaccount
          userRef:
            name: conjur-credentials
            key: hostId
          apiKeyRef:
            name: conjur-credentials
            key: apikey
```

Apply and verify:

```bash
kubectl apply -f secret-store.yaml
kubectl get secretstore -n eso-test-app
```

Should show `STATUS: Valid` and `READY: True`.

Now proceed to [Create ExternalSecret](#create-externalsecret) section.

---

# Option 2: JWT Authentication

This section covers setting up ESO with JWT authentication. This method uses Kubernetes ServiceAccount tokens to authenticate with Conjur - no static credentials required.

## JWT: Step 1 - Configure JWT Authenticator in Conjur

First, load the Conjur policy that configures the JWT authenticator and creates a host identity.

Create `conjur-policy.yaml`:

```yaml
# Conjur Policy for External Secrets Operator (JWT Authentication)

# Application Secrets
- !policy
  id: secrets
  body:
    - !group consumers
    - &variables
      - !variable username
      - !variable password
    - !permit
      role: !group consumers
      privilege: [ read, execute ]
      resource: *variables

# JWT Authenticator Configuration for authn-jwt/dev
- !policy
  id: conjur/authn-jwt/dev
  body:
    - !webservice

    # JWT validation variables
    - !variable public-keys
    - !variable issuer
    - !variable token-app-property
    - !variable identity-path
    - !variable audience

    # Group for apps that can authenticate
    - !group apps

    - !permit
      role: !group apps
      privilege: [ authenticate ]
      resource: !webservice

    - !webservice status

# Host identities for JWT authentication
# Identity path is 'jwt-apps', so hosts are defined under this policy
- !policy
  id: jwt-apps
  body:
    # Host for ESO service account
    # Format: system:serviceaccount:<namespace>:<serviceaccount-name>
    - !host
      id: system:serviceaccount:eso-jwt-test:eso-jwt-sa
      annotations:
        authn-jwt/dev/sub: system:serviceaccount:eso-jwt-test:eso-jwt-sa

# Grant host to authenticator group
- !grant
  role: !group conjur/authn-jwt/dev/apps
  member: !host jwt-apps/system:serviceaccount:eso-jwt-test:eso-jwt-sa

# Grant access to secrets
- !grant
  role: !group secrets/consumers
  member: !host jwt-apps/system:serviceaccount:eso-jwt-test:eso-jwt-sa
```

Load the policy:

```bash
conjur policy load -b root -f conjur-policy.yaml  
```

## JWT: Step 2 - Configure JWT Authenticator Variables

Set the JWT authenticator variables:

```bash
# Get Kubernetes JWKS public keys and format as proper JSON
kubectl get --raw /openid/v1/jwks > /tmp/jwks.json
jq -n --slurpfile jwks /tmp/jwks.json '{"type":"jwks","value":$jwks[0]}' > /tmp/public-keys.json

# Set public-keys from file (ensures proper JSON formatting)
conjur variable set -i conjur/authn-jwt/dev/public-keys -v "$(cat /tmp/public-keys.json)"

conjur variable set -i conjur/authn-jwt/dev/issuer -v "https://kubernetes.default.svc.cluster.local"

conjur variable set -i conjur/authn-jwt/dev/token-app-property -v "sub"

conjur variable set -i conjur/authn-jwt/dev/identity-path -v "jwt-apps"

conjur variable set -i conjur/authn-jwt/dev/audience -v "https://conjur-conjur-oss.conjur.svc.cluster.local"
```

> **Note:** Using `jq` to format the public-keys JSON ensures proper quoting. Malformed JSON (missing quotes around keys) will cause JWT authentication to fail with 401 errors.

## JWT: Step 3 - Set Application Secrets

```bash
conjur variable set -i secrets/username -v "admin-user"

conjur variable set -i secrets/password -v "super-secret-password"
```

## JWT: Step 4 - Create Application Namespace and ServiceAccount

```bash
# Create namespace
kubectl create namespace eso-jwt-test

# Create service account for ESO to use
kubectl create serviceaccount eso-jwt-sa -n eso-jwt-test
```

## JWT: Step 5 - Get Conjur CA Certificate

> **Note:** The `caBundle` field is only required if Conjur uses a self-signed or private SSL certificate. If Conjur uses a publicly trusted SSL certificate, you can omit the `caBundle` field from the SecretStore configuration.

```bash
# Get base64-encoded CA certificate (only needed for self-signed/private certificates)
kubectl get secret conjur-conjur-ssl-cert -n conjur -o jsonpath='{.data.tls\.crt}'
```

Save this value for the SecretStore configuration.

## JWT: Step 6 - Create SecretStore with JWT Auth

Create `secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: conjur-jwt-secret-store
  namespace: eso-jwt-test
spec:
  provider:
    conjur:
      url: https://conjur-conjur-oss.conjur.svc.cluster.local
      # Paste the base64-encoded CA certificate from Step 5
      caBundle: <BASE64_ENCODED_CA_CERTIFICATE>
      auth:
        jwt:
          account: myaccount
          serviceID: dev
          serviceAccountRef:
            name: eso-jwt-sa
            audiences:
              - https://conjur-conjur-oss.conjur.svc.cluster.local
```

Apply and verify:

```bash
kubectl apply -f secret-store.yaml
kubectl get secretstore -n eso-jwt-test
```

Should show `STATUS: Valid` and `READY: True`.

Now proceed to [Create ExternalSecret](#create-externalsecret) section.

---

# Common Configuration

The following sections apply to both authentication methods. Adjust the namespace name based on your chosen method:
- API Key: `eso-test-app`
- JWT: `eso-jwt-test`

## Create ExternalSecret

Create `external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: <NAMESPACE>  # eso-test-app or eso-jwt-test
spec:
  refreshInterval: 30s
  secretStoreRef:
    name: <SECRET_STORE_NAME>  # conjur-secret-store or conjur-jwt-secret-store
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
        key: secrets/username
    - secretKey: password
      remoteRef:
        key: secrets/password
```

Apply and verify:

```bash
kubectl apply -f external-secret.yaml
kubectl get externalsecret -n <NAMESPACE>
```

Should show `STATUS: SecretSynced` and `READY: True`.

## Deploy Application

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: eso-test-app
  namespace: <NAMESPACE>  # eso-test-app or eso-jwt-test
  annotations:
    reloader.stakater.com/search: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: eso-test-app
  template:
    metadata:
      labels:
        app: eso-test-app
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
kubectl get secretstore -n <NAMESPACE>

# ExternalSecret
kubectl get externalsecret -n <NAMESPACE>

# Secret (created by ESO)
kubectl get secret app-secrets -n <NAMESPACE>

# Pod
kubectl get pods -n <NAMESPACE>

# Verify secret contents
kubectl get secret app-secrets -n <NAMESPACE> -o jsonpath='{.data.password}' | base64 -d

# Check app logs
kubectl logs -n <NAMESPACE> -l app=eso-test-app
```

## Test Secret Rotation

### Update Secret in Conjur

```bash
conjur variable set -i secrets/password -v "new-rotated-password"
```

### Wait and Verify

Wait 30-60 seconds for ESO refresh and Reloader restart:

```bash
# Check secret was updated
kubectl get secret app-secrets -n <NAMESPACE> -o jsonpath='{.data.password}' | base64 -d

# Check pod was restarted (new pod name)
kubectl get pods -n <NAMESPACE> -l app=eso-test-app

# Check app logs show new password
kubectl logs -n <NAMESPACE> -l app=eso-test-app --tail=5
```

---

# Configuration Reference

## SecretStore Configuration

### API Key Authentication

| Field | Description |
|-------|-------------|
| `url` | Conjur server URL |
| `caBundle` | Base64-encoded CA certificate for SSL (optional if using publicly trusted certificate) |
| `auth.apikey.account` | Conjur account name |
| `auth.apikey.userRef` | Reference to K8s secret containing host ID |
| `auth.apikey.apiKeyRef` | Reference to K8s secret containing API key |

### JWT Authentication

| Field | Description |
|-------|-------------|
| `url` | Conjur server URL |
| `caBundle` | Base64-encoded CA certificate for SSL (optional if using publicly trusted certificate) |
| `auth.jwt.account` | Conjur account name |
| `auth.jwt.serviceID` | JWT authenticator service ID (e.g., `dev` for `authn-jwt/dev`) |
| `auth.jwt.serviceAccountRef.name` | Kubernetes ServiceAccount name |
| `auth.jwt.serviceAccountRef.audiences` | JWT audience values (should match Conjur's audience variable) |

## JWT Authenticator Variables

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `public-keys` | JWKS for token validation | `{"type":"jwks","value":{...}}` |
| `issuer` | Expected JWT issuer claim | `https://kubernetes.default.svc.cluster.local` |
| `token-app-property` | JWT claim for identity | `sub` |
| `identity-path` | Conjur policy path for hosts | `jwt-apps` |
| `audience` | Expected JWT audience claim | Conjur URL |

## ExternalSecret Configuration

| Field | Description |
|-------|-------------|
| `refreshInterval` | How often ESO syncs secrets from Conjur (e.g., `30s`) |
| `secretStoreRef` | Reference to the SecretStore |
| `target.name` | Name of the K8s Secret to create |
| `target.template.metadata.annotations` | Annotations to add to the created Secret |
| `data[].secretKey` | Key name in the K8s Secret |
| `data[].remoteRef.key` | Variable path in Conjur |

## Reloader Annotations

| Resource | Annotation |
|----------|------------|
| Deployment | `reloader.stakater.com/search: "true"` |
| Secret (via ExternalSecret template) | `reloader.stakater.com/match: "true"` |

---

# Comparison: API Key vs JWT Authentication

| Aspect | API Key | JWT |
|--------|---------|-----|
| **Credentials** | Static API key stored in K8s Secret | Dynamic tokens from ServiceAccount |
| **Security** | Key rotation requires manual update | No static secrets, tokens auto-rotate |
| **Setup Complexity** | Simpler | Requires JWT authenticator configuration |
| **Conjur Policy** | Host with API key | Host with JWT claim annotations |
| **Best For** | Development, simple setups | Production, security-conscious environments |

---

# Manifest Files

## API Key Authentication

All manifests are available in `../manifests/eso/`:
- `conjur-policy.yaml` - Conjur policy with host and permissions
- `secret-store.yaml` - ESO SecretStore with API key auth
- `external-secret.yaml` - ESO ExternalSecret configuration
- `deployment.yaml` - Application deployment

## JWT Authentication

All manifests are available in `../manifests/eso-jwt/`:
- `conjur-policy.yaml` - Conjur policy with JWT authenticator and host
- `secret-store.yaml` - ESO SecretStore with JWT auth
- `external-secret.yaml` - ESO ExternalSecret configuration
- `deployment.yaml` - Application deployment
