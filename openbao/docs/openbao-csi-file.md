# OpenBao CSI Driver (File-Based) + Stakater Reloader Integration

This guide demonstrates integrating OpenBao with Stakater Reloader using the
Secrets Store CSI Driver in file-based mode, where secrets are delivered
directly as mounted files without syncing to Kubernetes Secrets.

## Overview

In the file-based CSI pattern, secrets from OpenBao are mounted directly into
pods as files. Reloader monitors the `SecretProviderClassPodStatus` resource
for version changes and triggers pod restarts when secrets are rotated.

```text
┌─────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                          │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    Application Namespace                       │  │
│  │                                                                │  │
│  │  ┌─────────────────┐    ┌──────────────────────────────────┐  │  │
│  │  │ SecretProvider  │    │         Application Pod          │  │  │
│  │  │     Class       │    │  ┌────────────────────────────┐  │  │  │
│  │  │                 │    │  │  CSI Volume Mount          │  │  │  │
│  │  │ - provider:     │    │  │  /mnt/secrets/             │  │  │  │
│  │  │   openbao       │    │  │    ├── username            │  │  │  │
│  │  │ - parameters    │    │  │    └── password            │  │  │  │
│  │  │   (no secret-   │    │  └────────────────────────────┘  │  │  │
│  │  │    Objects)     │    └──────────────────────────────────┘  │  │
│  │  └────────┬────────┘                     ▲                    │  │
│  │           │                              │                    │  │
│  │           │              ┌───────────────┴───────────────┐    │  │
│  │           │              │     Secrets Store CSI         │    │  │
│  │           │              │         Driver                │    │  │
│  │           │              │                               │    │  │
│  │           │              │  - Mounts secrets as files    │    │  │
│  │           │              │  - Updates version in status  │    │  │
│  │           │              └───────────────┬───────────────┘    │  │
│  │           │                              │                    │  │
│  │           ▼                              ▼                    │  │
│  │  ┌─────────────────────────────────────────────────────────┐  │  │
│  │  │          SecretProviderClassPodStatus                   │  │  │
│  │  │                                                         │  │  │
│  │  │  status:                                                │  │  │
│  │  │    objects:                                             │  │  │
│  │  │    - id: username                                       │  │  │
│  │  │      version: "abc123..."  ◄── Version hash changes     │  │  │
│  │  │    - id: password               when secret rotates     │  │  │
│  │  │      version: "def456..."                               │  │  │
│  │  └──────────────────────┬──────────────────────────────────┘  │  │
│  │                         │                                     │  │
│  └─────────────────────────┼─────────────────────────────────────┘  │
│                            │                                        │
│                            ▼                                        │
│             ┌─────────────────────────┐                            │
│             │    Stakater Reloader    │                            │
│             │                         │                            │
│             │  Watches SPCPS for      │                            │
│             │  version changes        │                            │
│             │                         │                            │
│             │  Triggers pod restart   │                            │
│             │  on version change      │                            │
│             └─────────────────────────┘                            │
│                                                                     │
│             ┌─────────────────────────┐                            │
│             │    OpenBao CSI          │                            │
│             │      Provider           │                            │
│             └───────────┬─────────────┘                            │
│                         │                                           │
└─────────────────────────┼───────────────────────────────────────────┘
                          │
                          ▼
               ┌─────────────────────┐
               │      OpenBao        │
               │                     │
               │  KV v2 Secrets      │
               │  secret/myapp       │
               │                     │
               │  Kubernetes Auth    │
               └─────────────────────┘
```

## When to Use This Pattern

Use the file-based CSI pattern when:

- Applications read secrets directly from files
- You want to avoid creating Kubernetes Secret objects
- Security policies require secrets to exist only in memory/tmpfs
- You need the simplest possible secret delivery mechanism

## Prerequisites

1. Kubernetes cluster with OpenBao installed and unsealed
2. Stakater Reloader installed
3. Secrets Store CSI Driver installed with rotation enabled
4. OpenBao CSI Provider installed

## Step 1: Install Secrets Store CSI Driver

Install with rotation enabled:

```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update

helm install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system \
  --set enableSecretRotation=true \
  --set rotationPollInterval=30s
```

Note: `syncSecret.enabled` is not required for file-based delivery.

## Step 2: Enable OpenBao CSI Provider

```bash
helm upgrade openbao openbao/openbao \
  -n openbao \
  --set csi.enabled=true \
  --reuse-values
```

## Step 3: Configure OpenBao

> **Note:** All `bao` commands below assume `BAO_ADDR` and `BAO_TOKEN` are set from [README Step 3](../README.md#step-3-configure-openbao-cli).

### Create Read Policy

```bash
bao policy write myapp-read - <<EOF
path "secret/data/myapp" {
  capabilities = ["read"]
}
EOF
```

### Enable Kubernetes Auth

```bash
bao auth enable kubernetes

bao write auth/kubernetes/config \
    kubernetes_host='https://kubernetes.default.svc.cluster.local'
```

### Create Auth Role

```bash
bao write auth/kubernetes/role/openbao-csi-role \
    bound_service_account_names=openbao-csi-sa \
    bound_service_account_namespaces=openbao-csi-test \
    policies=myapp-read \
    ttl=1h
```

### Write Test Secret

```bash
bao kv put secret/myapp username=myuser password=mypassword
```

## Step 4: Create Application Namespace and ServiceAccount

```bash
kubectl create namespace openbao-csi-test
```

```yaml
# serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openbao-csi-sa
  namespace: openbao-csi-test
```

## Step 5: Create SecretProviderClass

File-based configuration without `secretObjects`:

```yaml
# secret-provider-class.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: openbao-secrets-file
  namespace: openbao-csi-test
spec:
  provider: openbao
  parameters:
    vaultAddress: "http://openbao.openbao.svc.cluster.local:8200"
    roleName: openbao-csi-role
    objects: |
      - objectName: "username"
        secretPath: "secret/data/myapp"
        secretKey: "username"
      - objectName: "password"
        secretPath: "secret/data/myapp"
        secretKey: "password"
```

**Key Differences from K8s Secret Sync:**

- No `secretObjects` section
- Secrets only exist as mounted files
- No Kubernetes Secret is created

## Step 6: Deploy Application

The deployment uses the CSI-specific Reloader annotation:

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openbao-csi-file-app
  namespace: openbao-csi-test
  annotations:
    # Reloader annotation for CSI-mounted secrets (file-based)
    secretproviderclass.reloader.stakater.com/reload: "openbao-secrets-file"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openbao-csi-file-app
  template:
    metadata:
      labels:
        app: openbao-csi-file-app
    spec:
      serviceAccountName: openbao-csi-sa
      containers:
        - name: app
          image: busybox:latest
          command:
            - "sh"
            - "-c"
            - |
              while true; do
                echo "=== Secrets from file ==="
                echo "Username: $(cat /mnt/secrets/username)"
                echo "Password: $(cat /mnt/secrets/password)"
                sleep 30
              done
          volumeMounts:
            - name: secrets-store
              mountPath: "/mnt/secrets"
              readOnly: true
      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: openbao-secrets-file
```

**Key Configuration:**

- `secretproviderclass.reloader.stakater.com/reload: "openbao-secrets-file"` -
  Tells Reloader to watch the named SecretProviderClass for version changes
- Secrets read directly from `/mnt/secrets/` files
- No environment variables referencing Kubernetes Secrets

## Step 7: Verify Setup

Apply manifests:

```bash
kubectl apply -f serviceaccount.yaml
kubectl apply -f secret-provider-class.yaml
kubectl apply -f deployment.yaml
```

Check pod is running:

```bash
kubectl get pods -n openbao-csi-test -l app=openbao-csi-file-app
```

Verify secrets are mounted:

```bash
kubectl exec -n openbao-csi-test deploy/openbao-csi-file-app -- cat /mnt/secrets/password
```

Check SecretProviderClassPodStatus:

```bash
kubectl get secretproviderclasspodstatus -n openbao-csi-test
```

View version information:

```bash
kubectl get secretproviderclasspodstatus -n openbao-csi-test -o yaml | grep -A5 "objects:"
```

Example output:

```yaml
status:
  objects:
    - id: username
      version: "u35OH4bBShH7wgv0YNyr1dzoZzJyKwDFq845rA6Ca_k="
    - id: password
      version: "hYds2SjGgvcyw2BIk9aYSJtxUV4hbIefYN3oPjO3WhA="
```

## Step 8: Test Secret Rotation

Record current versions:

```bash
kubectl get secretproviderclasspodstatus -n openbao-csi-test -o yaml | grep -A5 "objects:"
```

Update secret in OpenBao:

```bash
bao kv put secret/myapp username=myuser password=rotated-password
```

Wait for CSI rotation and check version change:

```bash
# After ~30-45 seconds (based on rotationPollInterval)
kubectl get secretproviderclasspodstatus -n openbao-csi-test -o yaml | grep -A5 "objects:"
```

The password version hash should change:

```yaml
status:
  objects:
    - id: username
      version: "u35OH4bBShH7wgv0YNyr1dzoZzJyKwDFq845rA6Ca_k="  # unchanged
    - id: password
      version: "yNvjDhGGwPLMPhAplHYNJ4eEWrq6zFzA7XGV7Oz6erQ="  # CHANGED
```

Reloader detects this change and triggers a pod restart.

## How It Works

1. **CSI Driver mounts secrets** - Secrets are mounted as files in the pod's
   volume
2. **SecretProviderClassPodStatus created** - CSI driver creates a status
   resource tracking mounted secrets and their versions
3. **Rotation polling** - CSI driver periodically checks OpenBao for changes
4. **Version update** - When secrets change, CSI driver updates the version
   hash in SecretProviderClassPodStatus
5. **Reloader detects change** - Reloader watches SecretProviderClassPodStatus
   for the named SecretProviderClass and triggers pod restart on version changes

## Reloader Annotation

For file-based CSI secrets, use the dedicated annotation on the Deployment:

```yaml
metadata:
  annotations:
    secretproviderclass.reloader.stakater.com/reload: "<secretproviderclass-name>"
```

This is different from the standard Secret/ConfigMap annotations. Reloader
watches the `SecretProviderClassPodStatus` resources and triggers restarts
when the version hashes change.

## Comparison: File-Based vs K8s Secret Sync

| Aspect | File-Based | K8s Secret Sync |
|--------|------------|-----------------|
| Secret storage | Mounted files only | Files + K8s Secret |
| Reloader annotation | `secretproviderclass...reload` | `reloader...match` on Secret |
| Security | Secrets never in etcd | Secrets stored in etcd |
| Env var support | Read from file | Native secretKeyRef |
| Complexity | Simpler | More configuration |

## Important Notes

### Provider Name

Use `openbao` as the provider name:

```yaml
spec:
  provider: openbao
```

### Rotation Must Be Enabled

The CSI driver must have rotation enabled to detect changes:

```bash
--set enableSecretRotation=true
--set rotationPollInterval=30s
```

### Application Must Read Files

Applications must be designed to read secrets from mounted files rather than
environment variables.

## Troubleshooting

### Version Not Changing

1. Verify CSI driver has rotation enabled
2. Check rotationPollInterval setting
3. Wait for the full poll interval after rotating secrets

### Secrets Not Mounting

Check OpenBao CSI provider logs:

```bash
kubectl logs -n openbao -l app.kubernetes.io/name=openbao-csi-provider
```

### Reloader Not Triggering Restart

1. Verify the annotation references the correct SecretProviderClass name
2. Check Reloader logs for errors
3. Ensure SecretProviderClassPodStatus exists and shows version changes

## Files

- [secret-provider-class.yaml](../manifests/csi-file/secret-provider-class.yaml)
- [deployment.yaml](../manifests/csi-file/deployment.yaml)
- [serviceaccount.yaml](../manifests/csi-file/serviceaccount.yaml)
