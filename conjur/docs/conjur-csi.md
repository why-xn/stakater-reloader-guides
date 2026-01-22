# How to Use Reloader with Conjur CSI Driver Pattern

This guide explains how to set up CyberArk Conjur with the Secrets Store CSI Driver using JWT-based authentication (authn-jwt), combined with Stakater Reloader for automatic pod restarts when secrets change.

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
│  │  │  - username.txt                                                  │   │ │
│  │  │  - password.txt                                                  │   │ │
│  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                      │                                       │
│            ┌─────────────────────────┼─────────────────────────┐            │
│            ▼                         ▼                         ▼            │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐      │
│  │  Conjur CSI      │    │   K8s Secret     │    │  Stakater        │      │
│  │  Provider        │───►│   (app-secrets)  │───►│  Reloader        │      │
│  │                  │    │                  │    │                  │      │
│  │  - Authenticates │    │  annotation:     │    │  Watches secret  │      │
│  │    via JWT       │    │  reloader.../    │    │  changes and     │      │
│  │  - Fetches from  │    │  match: "true"   │    │  restarts pods   │      │
│  │    Conjur        │    │                  │    │                  │      │
│  │  - Syncs via     │    │  (secretObjects) │    │                  │      │
│  │    secretObjects │    │                  │    │                  │      │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘      │
│            │                                                                 │
│            ▼                                                                 │
│  ┌──────────────────┐                                                       │
│  │    Conjur        │                                                       │
│  │    Server        │                                                       │
│  │                  │                                                       │
│  │  Stores secrets  │                                                       │
│  │  Validates JWT   │                                                       │
│  └──────────────────┘                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

Complete the common setup steps from the [README](../README.md):
- Conjur OSS installed
- Conjur CLI configured
- Golden ConfigMap (cluster-prep) installed

Additionally required:
- Secrets Store CSI Driver installed with `syncSecret.enabled=true`
- CyberArk Conjur CSI Provider installed

### Install Secrets Store CSI Driver

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true \
  --set rotationPollInterval=30s \
  --set tokenRequests[0].audience="conjur"
```

**Important:** The `tokenRequests[0].audience="conjur"` is required for JWT authentication with Conjur CSI Provider.

### Install Conjur CSI Provider

```bash
helm repo add cyberark https://cyberark.github.io/helm-charts
helm install conjur-csi-provider cyberark/conjur-k8s-csi-provider \
  --namespace kube-system
```

## Step 1: Load Conjur Policies

Create `conjur-policy.yaml`:

```yaml
# JWT Authenticator Configuration
- !policy
  id: conjur/authn-jwt/dev
  body:
    - !webservice
    - !group apps
    - !permit
      role: !group apps
      privilege: [ read, authenticate ]
      resource: !webservice
    # Use public-keys instead of jwks-uri
    - !variable public-keys
    - !variable issuer
    - !variable token-app-property
    - !variable identity-path
    - !variable audience

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

# Host Identity for CSI test app
- !policy
  id: jwt-apps
  body:
    - !host
      id: system:serviceaccount:csi-test-app:csi-test-app-sa
      annotations:
        authn-jwt/dev/sub: system:serviceaccount:csi-test-app:csi-test-app-sa

# Grant Host to JWT Authenticator Group
- !grant
  role: !group conjur/authn-jwt/dev/apps
  member: !host jwt-apps/system:serviceaccount:csi-test-app:csi-test-app-sa

# Grant Host Access to Secrets
- !grant
  role: !group secrets/consumers
  member: !host jwt-apps/system:serviceaccount:csi-test-app:csi-test-app-sa
```

Load the policy:

```bash
conjur policy load -b root -f conjur-policy.yaml
```

## Step 2: Configure JWT Authenticator Variables

**Important:** Use `public-keys` instead of `jwks-uri`. The `jwks-uri` approach fails because Conjur cannot reach the Kubernetes API server due to SSL certificate issues.

**Important:** For CSI Provider, the audience must be `"conjur"` (not the Conjur URL).

> **Note:** Using `jq` to format the public-keys JSON ensures proper quoting. Malformed JSON (missing quotes around keys) will cause JWT authentication to fail with 401 errors.

```bash
# Get Kubernetes JWKS public keys and format as proper JSON
kubectl get --raw /openid/v1/jwks > /tmp/jwks.json
jq -n --slurpfile jwks /tmp/jwks.json '{"type":"jwks","value":$jwks[0]}' > /tmp/public-keys.json

# Set public-keys from file (ensures proper JSON formatting)
conjur variable set -i conjur/authn-jwt/dev/public-keys -v "$(cat /tmp/public-keys.json)"

# Set issuer
conjur variable set -i conjur/authn-jwt/dev/issuer \
  -v "https://kubernetes.default.svc.cluster.local"

# Set token-app-property
conjur variable set -i conjur/authn-jwt/dev/token-app-property -v "sub"

# Set identity-path
conjur variable set -i conjur/authn-jwt/dev/identity-path -v "jwt-apps"

# Set audience - MUST be "conjur" for CSI Provider
conjur variable set -i conjur/authn-jwt/dev/audience -v "conjur"
```

## Step 3: Set Application Secrets

```bash
conjur variable set -i secrets/username -v "admin-user"

conjur variable set -i secrets/password -v "super-secret-password"
```

## Step 4: Create Application Namespace

```bash
kubectl create namespace csi-test-app
kubectl create serviceaccount csi-test-app-sa -n csi-test-app
```

## Step 5: Install Namespace Prep

```bash
helm install conjur-config-namespace-prep cyberark/conjur-config-namespace-prep \
  --namespace csi-test-app \
  --set authnK8s.goldenConfigMap="conjur-configmap" \
  --set authnK8s.namespace="conjur"
```

## Step 6: Create SecretProviderClass

Create `secret-provider-class.yaml`:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: conjur-secrets
  namespace: csi-test-app
spec:
  provider: conjur
  # Sync to Kubernetes Secret - Required for Reloader integration
  secretObjects:
    - secretName: app-secrets
      type: Opaque
      annotations:
        reloader.stakater.com/match: "true"
      data:
        - key: username
          objectName: username.txt
        - key: password
          objectName: password.txt
  parameters:
    # IMPORTANT: Use version 0.2.0 - secrets mapping is done via pod annotations
    conjur.org/configurationVersion: "0.2.0"
    account: myaccount
    applianceUrl: "https://conjur-conjur-oss.conjur.svc.cluster.local"
    authnId: authn-jwt/dev
    # Get SSL certificate from conjur-connect configmap
    sslCertificate: |
      -----BEGIN CERTIFICATE-----
      <your-conjur-ssl-certificate-here>
      -----END CERTIFICATE-----
```

**Note:** Get the SSL certificate from:
```bash
kubectl get configmap conjur-connect -n csi-test-app -o jsonpath='{.data.CONJUR_SSL_CERTIFICATE}'
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
  name: csi-test-app
  namespace: csi-test-app
  annotations:
    reloader.stakater.com/search: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: csi-test-app
  template:
    metadata:
      labels:
        app: csi-test-app
      annotations:
        # REQUIRED: Map Conjur secrets to files in the CSI volume
        # Format: - <filename>: <conjur-variable-path>
        conjur.org/secrets: |
          - username.txt: secrets/username
          - password.txt: secrets/password
    spec:
      serviceAccountName: csi-test-app-sa
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
            - name: conjur-secrets
              mountPath: /mnt/secrets
              readOnly: true
      volumes:
        - name: conjur-secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: conjur-secrets
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

## Step 8: Verify the Setup

### Check Pod Status

```bash
kubectl get pods -n csi-test-app
```

Pod should be Running.

### Check SecretProviderClassPodStatus

```bash
kubectl get secretproviderclasspodstatuses -n csi-test-app
```

Verify `mounted: true` in the status.

### Verify Secrets are Populated

```bash
# Check K8s Secret was created
kubectl get secret app-secrets -n csi-test-app -o jsonpath='{.data.password}' | base64 -d

# Check app logs
kubectl logs -n csi-test-app -l app=csi-test-app
```

## Step 9: Test Secret Rotation

### Update Secret in Conjur

```bash
conjur variable set -i secrets/password -v "new-rotated-password"
```

### Wait and Verify

Wait 30-60 seconds for CSI rotation and Reloader restart:

```bash
# Check secret was updated
kubectl get secret app-secrets -n csi-test-app -o jsonpath='{.data.password}' | base64 -d

# Check pod was restarted (new pod name)
kubectl get pods -n csi-test-app -l app=csi-test-app
```

## Key Configuration Points

### SecretProviderClass Configuration (v0.2.0)

| Field | Description |
|-------|-------------|
| `conjur.org/configurationVersion` | Must be `"0.2.0"` for pod annotation-based secrets mapping |
| `account` | Conjur account name |
| `applianceUrl` | Conjur server URL |
| `authnId` | JWT authenticator ID (e.g., `authn-jwt/dev`) |
| `sslCertificate` | Conjur SSL certificate (PEM format) |

**Note:** In v0.2.0, the `identity` field is NOT used. Identity is derived from the JWT token automatically.

### Pod Annotations

The pod **must** have the `conjur.org/secrets` annotation to map Conjur variables to files:

```yaml
annotations:
  conjur.org/secrets: |
    - username.txt: secrets/username
    - password.txt: secrets/password
```

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
        objectName: username.txt  # Must match filename in conjur.org/secrets
      - key: password
        objectName: password.txt
```

### CSI Driver Token Configuration

The CSI Driver must be installed with `tokenRequests` for JWT authentication:

```bash
helm install csi-secrets-store ... \
  --set tokenRequests[0].audience="conjur"
```

### Reloader Annotations

| Resource | Annotation |
|----------|------------|
| Deployment | `reloader.stakater.com/search: "true"` |
| Secret | `reloader.stakater.com/match: "true"` (via secretObjects) |

### Why CSI Volume Mount is Required

Even if your app only uses environment variables from the K8s Secret, the CSI volume must be mounted because:
1. The CSI driver only syncs secrets when a pod mounts the volume
2. Without the mount, the K8s Secret (secretObjects) won't be created

## Manifest Files

All manifests are available in `../manifests/csi/`:
- `combined-policy.yaml` - Conjur policy
- `secret-provider-class.yaml` - SecretProviderClass configuration
- `deployment.yaml` - Application deployment
