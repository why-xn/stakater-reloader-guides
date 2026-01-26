# How to Use Reloader with Conjur JWT Sidecar Pattern

This guide explains how to set up CyberArk Conjur with the Secrets Provider sidecar pattern using JWT-based authentication (authn-jwt), combined with Stakater Reloader for automatic pod restarts when secrets change.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Kubernetes Cluster                             │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                         Application Pod                             │ │
│  │  ┌─────────────────┐         ┌──────────────────────────────────┐  │ │
│  │  │  App Container  │         │  Secrets Provider Sidecar        │  │ │
│  │  │                 │         │                                  │  │ │
│  │  │  Reads secrets  │         │  1. Gets projected SA JWT token  │  │ │
│  │  │  from K8s       │         │  2. Authenticates via authn-jwt  │  │ │
│  │  │  Secret         │         │  3. Fetches secrets from Conjur  │  │ │
│  │  │                 │         │  4. Updates K8s Secret           │  │ │
│  │  │                 │         │  5. Refreshes every 30s          │  │ │
│  │  └─────────────────┘         └──────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                      │                                   │
│                                      ▼                                   │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐   │
│  │   K8s Secret     │    │  Stakater        │    │    Conjur        │   │
│  │   (app-secrets)  │◄───│  Reloader        │    │    Server        │   │
│  │                  │    │                  │    │                  │   │
│  │  annotation:     │    │  Watches secret  │    │  Stores secrets  │   │
│  │  reloader.../    │    │  changes and     │    │  Validates JWT   │   │
│  │  match: "true"   │    │  restarts pods   │    │  tokens          │   │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

Complete the common setup steps from the [README](../README.md):
- Conjur OSS installed
- Conjur CLI configured
- Golden ConfigMap (cluster-prep) installed

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
      - !variable db-url
    - !permit
      role: !group consumers
      privilege: [ read, execute ]
      resource: *variables

# Host Identity for JWT Authentication
- !policy
  id: jwt-apps
  body:
    - !host
      id: system:serviceaccount:jwt-test-app:jwt-test-app-sa
      annotations:
        authn-jwt/dev/sub: system:serviceaccount:jwt-test-app:jwt-test-app-sa

# Grant Host to JWT Authenticator Group
- !grant
  role: !group conjur/authn-jwt/dev/apps
  member: !host jwt-apps/system:serviceaccount:jwt-test-app:jwt-test-app-sa

# Grant Host Access to Secrets
- !grant
  role: !group secrets/consumers
  member: !host jwt-apps/system:serviceaccount:jwt-test-app:jwt-test-app-sa
```

Load the policy:

```bash
conjur policy load -b root -f conjur-policy.yaml
```

## Step 2: Configure JWT Authenticator Variables

**Important:** Use `public-keys` instead of `jwks-uri`. The `jwks-uri` approach fails because Conjur cannot reach the Kubernetes API server due to SSL certificate issues.

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

# Set audience
conjur variable set -i conjur/authn-jwt/dev/audience \
  -v "https://conjur-conjur-oss.conjur.svc.cluster.local"
```

## Step 3: Set Application Secrets

```bash
conjur variable set -i secrets/username -v "admin-user"

conjur variable set -i secrets/password -v "super-secret-password"
```

## Step 4: Create Application Namespace

```bash
kubectl create namespace jwt-test-app
kubectl create serviceaccount jwt-test-app-sa -n jwt-test-app
```

## Step 5: Install Namespace Prep

```bash
helm install conjur-config-jwt-test cyberark/conjur-config-namespace-prep -n jwt-test-app \
  --set conjur.configMap.namespace=conjur \
  --set conjur.configMap.name=conjur-configmap \
  --set authnK8s.goldenConfigMap=conjur-configmap \
  --set authnK8s.namespace=conjur
```

## Step 6: Create RBAC for Secrets Provider

Create `rbac.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secrets-provider-role
  namespace: jwt-test-app
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: secrets-provider-rolebinding
  namespace: jwt-test-app
subjects:
- kind: ServiceAccount
  name: jwt-test-app-sa
  namespace: jwt-test-app
roleRef:
  kind: Role
  name: secrets-provider-role
  apiGroup: rbac.authorization.k8s.io
```

Apply:

```bash
kubectl apply -f rbac.yaml
```

## Step 7: Deploy Application with Secrets Provider Sidecar

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jwt-test-app
  namespace: jwt-test-app
  annotations:
    reloader.stakater.com/search: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jwt-test-app
  template:
    metadata:
      labels:
        app: jwt-test-app
      annotations:
        # Required for sidecar refresh
        conjur.org/container-mode: sidecar
        conjur.org/secrets-refresh-interval: 30s
    spec:
      serviceAccountName: jwt-test-app-sa
      containers:
      - name: app
        image: busybox:latest
        command: ["sh", "-c", "while true; do echo \"Username: $APP_USERNAME\"; echo \"Password: $APP_PASSWORD\"; sleep 30; done"]
        # App must reference the secret for Reloader to trigger restart
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

      - name: conjur-secrets-provider
        image: cyberark/secrets-provider-for-k8s:1.6.1
        imagePullPolicy: IfNotPresent
        env:
        - name: CONJUR_ACCOUNT
          valueFrom:
            configMapKeyRef:
              name: conjur-connect
              key: CONJUR_ACCOUNT
        - name: CONJUR_APPLIANCE_URL
          valueFrom:
            configMapKeyRef:
              name: conjur-connect
              key: CONJUR_APPLIANCE_URL
        - name: CONJUR_AUTHN_URL
          value: "https://conjur-conjur-oss.conjur.svc.cluster.local/authn-jwt/dev"
        - name: CONJUR_SSL_CERTIFICATE
          valueFrom:
            configMapKeyRef:
              name: conjur-connect
              key: CONJUR_SSL_CERTIFICATE
        - name: SSL_CERT_FILE
          value: /etc/ssl/conjur/conjur.pem
        - name: MY_POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: MY_POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: K8S_SECRETS
          value: "app-secrets"
        - name: SECRETS_DESTINATION
          value: "k8s_secrets"
        - name: CONTAINER_MODE
          value: "sidecar"
        - name: DEBUG
          value: "true"
        - name: JWT_TOKEN_PATH
          value: /var/run/secrets/tokens/jwt
        volumeMounts:
        - name: conjur-secrets
          mountPath: /conjur/secrets
        - name: jwt-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
        - name: conjur-ssl
          mountPath: /etc/ssl/conjur
          readOnly: true
        - name: podinfo
          mountPath: /conjur/podinfo

      volumes:
      - name: conjur-secrets
        emptyDir:
          medium: Memory
      - name: jwt-token
        projected:
          sources:
          - serviceAccountToken:
              path: jwt
              expirationSeconds: 6000
              audience: https://conjur-conjur-oss.conjur.svc.cluster.local
      - name: conjur-ssl
        configMap:
          name: conjur-connect
          items:
          - key: CONJUR_SSL_CERTIFICATE
            path: conjur.pem
      - name: podinfo
        downwardAPI:
          defaultMode: 420
          items:
          - path: annotations
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.annotations
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: jwt-test-app
  annotations:
    reloader.stakater.com/match: "true"
type: Opaque
stringData:
  username: ""
  password: ""
  conjur-map: |
    username: secrets/username
    password: secrets/password
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

## Step 8: Verify the Setup

### Check Pod Status

```bash
kubectl get pods -n jwt-test-app
```

Both containers should be Running.

### Check Sidecar Logs

```bash
kubectl logs -n jwt-test-app deployment/jwt-test-app -c conjur-secrets-provider
```

Look for:
- `CAKC035 Successfully authenticated`
- `CSPFK009I DAP/Conjur Secrets updated in Kubernetes successfully`

### Verify Secrets are Populated

```bash
kubectl get secret app-secrets -n jwt-test-app -o jsonpath='{.data.password}' | base64 -d
```

## Step 9: Test Secret Rotation

### Update Secret in Conjur

```bash
conjur variable set -i secrets/password -v "new-rotated-password"
```

### Wait and Verify

Wait 30-60 seconds for sidecar refresh and Reloader restart:

```bash
# Check secret was updated
kubectl get secret app-secrets -n jwt-test-app -o jsonpath='{.data.password}' | base64 -d

# Check pod was restarted
kubectl get pods -n jwt-test-app -l app=jwt-test-app
```

## Key Configuration Points

### JWT Authenticator Variables

| Variable | Description | Value |
|----------|-------------|-------|
| `public-keys` | JWKS for token validation | `{"type":"jwks","value":{"keys":[...]}}` |
| `issuer` | Expected `iss` claim | `https://kubernetes.default.svc.cluster.local` |
| `token-app-property` | JWT claim for identity | `sub` |
| `identity-path` | Policy path for hosts | `jwt-apps` |
| `audience` | Expected `aud` claim | Conjur URL |

### Why `public-keys` Instead of `jwks-uri`?

When using `jwks-uri`, Conjur tries to fetch JWKS from the Kubernetes API server but fails due to SSL certificate verification issues. With `public-keys`, we provide the JWKS directly to Conjur.

### Required Pod Annotations

These must be on the **Pod template** metadata:

```yaml
annotations:
  conjur.org/container-mode: sidecar
  conjur.org/secrets-refresh-interval: 30s
```

### Required Volumes

| Volume | Purpose |
|--------|---------|
| `jwt-token` | Projected ServiceAccount token with custom audience |
| `conjur-ssl` | SSL certificate for Conjur |
| `podinfo` | DownwardAPI to expose pod annotations to sidecar |
| `conjur-secrets` | emptyDir for sidecar use |

### Reloader Annotations

| Resource | Annotation |
|----------|------------|
| Deployment | `reloader.stakater.com/search: "true"` |
| Secret | `reloader.stakater.com/match: "true"` (must be annotation, not label) |

## Manifest Files

All manifests are available in `../manifests/sidecar-jwt/`:
- `conjur-policy.yaml` - Conjur policy
- `deployment.yaml` - Application deployment and secret
- `rbac.yaml` - RBAC for secrets provider
