# Secrets: how they actually get into the pods

**There are no service-account JSON keys in this platform.** Not in the images,
not on the nodes, not in Git. That is deliberate and it is the single biggest
security difference between a learning project and a real one.

Three services read secrets:

| Service | Secret | What it is |
|---|---|---|
| `svc-payment` | `PAYMENT_GATEWAY_KEY` | Payment gateway API key |
| `svc-user-auth` | `JWT_SECRET` | Token signing secret |
| `svc-notification` | `SMTP_API_KEY` | Email provider key |

---

## How it works

```
Kubernetes SA (KSA)          GCP Service Account (GSA)         Secret Manager
  payment           ──────►    dev-payment@proj.iam...   ──────►  payment-gateway-key
       │                                  │
       │  annotation:                     │  role:
       │  iam.gke.io/gcp-service-account  │  roles/secretmanager.secretAccessor
       │                                  │
       └──── roles/iam.workloadIdentityUser ────┘
```

1. Terraform's `workload-identity` module creates the GSA and grants it
   `secretmanager.secretAccessor`.
2. It also grants the KSA permission to impersonate the GSA.
3. The pod's ServiceAccount carries the `iam.gke.io/gcp-service-account`
   annotation.
4. GKE's metadata server hands the pod a short-lived token. No key file, ever.

The credential is short-lived and automatically rotated. A leaked pod filesystem
gives an attacker nothing durable.

---

## Creating the secrets

Do this **once per environment**, after `terraform apply`:

```bash
export PROJECT_ID="your-project-id"
export ENV="dev"   # repeat for staging, prod

# Payment gateway key
echo -n "your-real-gateway-key" | \
  gcloud secrets create "${ENV}-payment-gateway-key" \
    --project="${PROJECT_ID}" \
    --replication-policy="automatic" \
    --data-file=-

# JWT signing secret - generate it, never invent it by hand
openssl rand -base64 48 | tr -d '\n' | \
  gcloud secrets create "${ENV}-jwt-secret" \
    --project="${PROJECT_ID}" \
    --replication-policy="automatic" \
    --data-file=-

# SMTP key
echo -n "your-smtp-key" | \
  gcloud secrets create "${ENV}-smtp-api-key" \
    --project="${PROJECT_ID}" \
    --replication-policy="automatic" \
    --data-file=-
```

**Verify:**
```bash
gcloud secrets list --project="${PROJECT_ID}"
```

---

## Getting them into the pod

Two options. Pick one per environment.

### Option A — Secret Manager CSI driver (recommended for prod)

Secrets are mounted as files and refreshed automatically. Nothing lands in etcd.

```bash
# Enable the add-on (one-off, per cluster)
gcloud container clusters update "${ENV}-gke" \
  --region=asia-south1 \
  --update-addons=SecretManagerConfig=ENABLED \
  --project="${PROJECT_ID}"
```

Then add a `SecretProviderClass` and mount it in the deployment. The pod reads
the file instead of an env var.

### Option B — sync into a K8s Secret (simpler, fine for dev/staging)

The deployments already reference `<service>-secrets` with `optional: true`, so
this drops straight in:

```bash
kubectl create secret generic payment-secrets \
  --namespace="${ENV}" \
  --from-literal=PAYMENT_GATEWAY_KEY="$(gcloud secrets versions access latest \
      --secret="${ENV}-payment-gateway-key" --project="${PROJECT_ID}")"

kubectl create secret generic user-auth-secrets \
  --namespace="${ENV}" \
  --from-literal=JWT_SECRET="$(gcloud secrets versions access latest \
      --secret="${ENV}-jwt-secret" --project="${PROJECT_ID}")"

kubectl create secret generic notification-secrets \
  --namespace="${ENV}" \
  --from-literal=SMTP_API_KEY="$(gcloud secrets versions access latest \
      --secret="${ENV}-smtp-api-key" --project="${PROJECT_ID}")"
```

**Be honest about the trade-off:** Option B writes the secret into etcd, and it
does not auto-rotate — you re-run the command after a rotation. That is
acceptable in dev. It is not what you want in prod.

---

## Why `optional: true` on the secretKeyRef

Without it, a missing Secret leaves the pod stuck in `CreateContainerConfigError`
forever, with an error message that does not obviously say "the secret is
missing". With it, the service starts using its dev fallback and you find out
from a log line instead of a mystery.

---

## Rotation

```bash
# Add a new version
echo -n "new-key-value" | \
  gcloud secrets versions add "${ENV}-payment-gateway-key" \
    --project="${PROJECT_ID}" --data-file=-

# CSI driver: picks it up on its own (default ~2 min)
# Option B: re-create the K8s secret, then restart
kubectl rollout restart deployment/payment -n "${ENV}"
```

---

## Things that will bite you

| Symptom | Cause |
|---|---|
| `PermissionDenied` reading a secret | GSA missing `secretmanager.secretAccessor`, or the KSA annotation is wrong |
| Pod gets the *node's* identity, not the GSA | Node pool missing `workload_metadata_config { mode = "GKE_METADATA" }` |
| Works in dev, 403 in prod | Secrets are per-environment. You created `dev-jwt-secret` and forgot `prod-jwt-secret` |
| Secret value has a trailing newline | Use `echo -n`, not `echo`. This one costs everyone an hour exactly once. |

**Verify Workload Identity is actually working:**
```bash
kubectl run wi-test -n dev --rm -it \
  --image=google/cloud-sdk:slim \
  --overrides='{"spec":{"serviceAccountName":"payment"}}' \
  --restart=Never -- gcloud auth list
```
It should print the GSA email, not the node's SA.
