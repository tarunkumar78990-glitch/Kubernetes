# Part 4 — Deploy to Kubernetes

**Before you start:**
- Part 2 complete: cluster running, `kubectl get nodes` shows exactly 2
- Part 3 complete: Jenkins green on `svc-product-catalog`, image in Artifact Registry

---

## Section A — Bootstrap the foundations

### Why
Order is not cosmetic. Each step depends on the one before:

1. **Namespaces** — everything else lives in them
2. **Quotas** — before workloads, or a runaway dev HPA starves prod on your shared 2-node cluster
3. **Default-deny** — **before** services, or you retro-fit security into a running system
4. **Monitoring** — before services, so you see your first deploy happen

### A1 — Connect and confirm

```bash
$ cd ~/enterprise-platform/platform-infrastructure/environments/dev
$ eval "$(terraform output -raw kubectl_connect_command)"
$ kubectl get nodes --no-headers | wc -l
```

**Expected output:**
```
2
```

### A2 — Copy in the fixed ops code

```bash
$ cd ~/enterprise-platform
$ mkdir -p platform-ops
$ cp -r ~/Downloads/enterprise-platform/platform-ops/. platform-ops/
$ head -3 platform-ops/slo/recording-rules.yaml
```

**Expected output:**
```
# SLO recording rules - PLAIN Prometheus format.
#
# NOTE: raw rule groups, NOT PrometheusRule CRDs. We run plain Prometheus, not
```

**Verify you have the fixed version** — this is the check that matters:

```bash
$ grep -c "kind: PrometheusRule" platform-ops/slo/*.yaml
```

**Expected output:**
```
0
0
0
```

> **All three must return `0`.** These are plain Prometheus rule groups, not `PrometheusRule` CRDs — we deploy Prometheus directly, without the Operator, so the CRD form would never load.

```bash
$ head -1 platform-ops/slo/burn-rate-alerts.yaml && grep -c "alert:" platform-ops/slo/burn-rate-alerts.yaml
```

**Expected output:**
```
# Multi-window, multi-burn-rate alerts - PLAIN Prometheus format.
40
```

40 alerts = 4 per service × 10 services.

### A3 — Run bootstrap

```bash
$ cd platform-ops
$ ./scripts/bootstrap.sh
```

**Expected output:**
```
==> 1/5 Namespaces
namespace/dev created
namespace/staging created
namespace/prod created
namespace/monitoring created

==> 2/5 Resource quotas and limit ranges
resourcequota/dev-quota created
limitrange/dev-limits created
...

==> 3/5 Default-deny NetworkPolicies
    Applying default-deny BEFORE workloads exist. Doing this after
    means a window where everything can reach everything.
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/allow-dns created
...

==> 4/5 Monitoring stack
serviceaccount/prometheus created
clusterrole.rbac.authorization.k8s.io/prometheus created
configmap/prometheus-config created
configmap/prometheus-rules created
deployment.apps/prometheus created
persistentvolumeclaim/prometheus-data created
deployment.apps/alertmanager created
    Grafana admin password: xK9mP2vL8qR4tN6wY3zB1cD5
    (store this in Secret Manager, then forget it)
deployment.apps/grafana created

==> 5/5 Waiting for monitoring to come up
deployment "prometheus" successfully rolled out
deployment "alertmanager" successfully rolled out
deployment "grafana" successfully rolled out

==> Bootstrap complete.
```

**Copy the Grafana password** — it's printed once.

### A4 — Verify the foundations

```bash
$ kubectl get ns
```

**Expected output:**
```
NAME              STATUS   AGE
default           Active   34m
dev               Active   2m
kube-system       Active   34m
monitoring        Active   2m
prod              Active   2m
staging           Active   2m
```

**The default-deny must exist before any service:**

```bash
$ kubectl get networkpolicy -n dev
```

**Expected output:**
```
NAME               POD-SELECTOR   AGE
allow-dns          <none>         2m
default-deny-all   <none>         2m
```

**`<none>` as pod-selector means "every pod in this namespace".** That's the point.

**Prometheus actually loaded the rules** — this is the bug-1 check:

```bash
$ kubectl logs -n monitoring deploy/prometheus | grep -iE "error|rule" | head -5
```

**Expected output:**
```
ts=... level=info msg="Completed loading of configuration file" filename=/etc/prometheus/prometheus.yml
```

**No errors.** If you see `error loading rules` or `field record not found`, you have the old CRD version — go back to A2.

Confirm the count:

```bash
$ kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
$ sleep 3 && curl -s localhost:9090/api/v1/rules | python3 -c "import sys,json; d=json.load(sys.stdin); print('rule groups:', len(d['data']['groups'])); print('total rules:', sum(len(g['rules']) for g in d['data']['groups']))"
```

**Expected output:**
```
rule groups: 3
total rules: 129
```

**129 rules loaded.** That's your proof the fix worked.

### Common errors

| Symptom | Cause |
|---|---|
| `bootstrap.sh: Permission denied` | `chmod +x scripts/bootstrap.sh` |
| Prometheus `CrashLoopBackOff` | Almost always the old CRD rules. Check A2. |
| PVC stuck `Pending` | `kubectl get storageclass` — needs `standard-rwo`. |
| `error loading rules ... field 'record' not found` | Rule indentation is wrong — each `- record:` must be under a group's `rules:`, not a new group. |

---

## Section B — Create the secrets

### Why
Three services read secrets. **No JSON keys anywhere** — Workload Identity gives pods short-lived, auto-rotated credentials.

### Commands

```bash
$ export PROJECT_ID=$(gcloud config get-value project)
$ export ENV=dev

$ echo -n "fake-gateway-key-for-dev" | \
    gcloud secrets create "${ENV}-payment-gateway-key" \
      --project="${PROJECT_ID}" --replication-policy="automatic" --data-file=-

$ openssl rand -base64 48 | tr -d '\n' | \
    gcloud secrets create "${ENV}-jwt-secret" \
      --project="${PROJECT_ID}" --replication-policy="automatic" --data-file=-

$ echo -n "fake-smtp-key-for-dev" | \
    gcloud secrets create "${ENV}-smtp-api-key" \
      --project="${PROJECT_ID}" --replication-policy="automatic" --data-file=-
```

**Expected output:**
```
Created version [1] of the secret [dev-payment-gateway-key].
Created version [1] of the secret [dev-jwt-secret].
Created version [1] of the secret [dev-smtp-api-key].
```

> **`echo -n`, not `echo`.** Without `-n` you append a newline to your secret. Your JWT signing key becomes `abc123\n`, tokens fail to verify, and the error tells you nothing. This costs everyone exactly one hour, once.

Sync into Kubernetes (Option B from `README-SECRETS.md`):

```bash
$ kubectl create secret generic payment-secrets -n dev \
    --from-literal=PAYMENT_GATEWAY_KEY="$(gcloud secrets versions access latest --secret=${ENV}-payment-gateway-key --project=${PROJECT_ID})"

$ kubectl create secret generic user-auth-secrets -n dev \
    --from-literal=JWT_SECRET="$(gcloud secrets versions access latest --secret=${ENV}-jwt-secret --project=${PROJECT_ID})"

$ kubectl create secret generic notification-secrets -n dev \
    --from-literal=SMTP_API_KEY="$(gcloud secrets versions access latest --secret=${ENV}-smtp-api-key --project=${PROJECT_ID})"
```

**Verify:**
```bash
$ kubectl get secrets -n dev
```

**Expected output:**
```
NAME                    TYPE     DATA   AGE
notification-secrets    Opaque   1      5s
payment-secrets         Opaque   1      8s
user-auth-secrets       Opaque   1      6s
```

> **Be honest about this trade-off:** Option B writes the secret into etcd and doesn't auto-rotate. Fine for dev. For prod, use the Secret Manager CSI driver (Option A in `README-SECRETS.md`) — the pod reads a file, nothing lands in etcd, rotation is automatic.

---

## Section C — Prove Workload Identity works

### Why
This is the difference between "configured" and "working". If WI is broken, pods silently get the **node's** identity instead — and you won't find out until something fails in prod with a confusing 403.

### Commands

You need the ServiceAccount to exist first:

```bash
$ cd ~/enterprise-platform/svc-payment
$ export PROJECT_ID=$(gcloud config get-value project)
$ export NAMESPACE=dev ENVIRONMENT=dev
$ envsubst '${NAMESPACE} ${ENVIRONMENT} ${PROJECT_ID}' < k8s/base/serviceaccount.yaml | kubectl apply -f -
```

**Expected output:**
```
serviceaccount/payment created
```

**Check the annotation resolved:**

```bash
$ kubectl get sa payment -n dev -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
```

**Expected output:**
```json
{
    "iam.gke.io/gcp-service-account": "dev-payment@my-project-id.iam.gserviceaccount.com"
}
```

**No literal `${PROJECT_ID}`.** If you see one, envsubst didn't substitute.

Now the real test:

```bash
$ kubectl run wi-test -n dev --rm -it --restart=Never \
    --image=google/cloud-sdk:slim \
    --overrides='{"spec":{"serviceAccountName":"payment","securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"wi-test","image":"google/cloud-sdk:slim","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["gcloud","auth","list"]}]}}'
```

**Expected output:**
```
                Credentialed Accounts
ACTIVE  ACCOUNT
*       dev-payment@my-project-id.iam.gserviceaccount.com
pod "wi-test" deleted
```

**`dev-payment@...` is the proof.** The pod is authenticated as its own GCP identity with no key file.

> **If you see `dev-gke-node@...` instead**, Workload Identity is broken — the pod fell back to the node's identity. Check `workload_metadata_config { mode = "GKE_METADATA" }` in the GKE module.

**Note the `--overrides`.** A bare `kubectl run` would be rejected by PSA `restricted` — the same bug that was in the smoke test.

**Now prove it can actually read the secret:**

```bash
$ kubectl run wi-secret-test -n dev --rm -it --restart=Never \
    --image=google/cloud-sdk:slim \
    --overrides='{"spec":{"serviceAccountName":"payment","securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"t","image":"google/cloud-sdk:slim","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["sh","-c","gcloud secrets versions access latest --secret=dev-payment-gateway-key"]}]}}'
```

**Expected output:**
```
fake-gateway-key-for-dev
pod "wi-secret-test" deleted
```

**Least privilege check** — `cart` has no secret access, so this must **fail**:

```bash
$ envsubst '${NAMESPACE} ${ENVIRONMENT} ${PROJECT_ID}' < ../svc-cart/k8s/base/serviceaccount.yaml | kubectl apply -f -
$ kubectl run denied-test -n dev --rm -it --restart=Never \
    --image=google/cloud-sdk:slim \
    --overrides='{"spec":{"serviceAccountName":"cart","securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"t","image":"google/cloud-sdk:slim","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"command":["sh","-c","gcloud secrets versions access latest --secret=dev-payment-gateway-key"]}]}}'
```

**Expected output:**
```
ERROR: (gcloud.secrets.versions.access) PERMISSION_DENIED: Permission
'secretmanager.versions.access' denied for resource ...
```

**That error is the success condition.** `cart` cannot read the payment key. Least privilege is real, not aspirational.

---

## Section D — Deploy your first service by hand

### Why
Deploy manually **once** before automating. When the pipeline fails later, you'll know whether the problem is the pipeline or the manifests.

Start with `product-catalog`: **zero dependencies**. If it fails, the problem is your cluster, not your service graph.

### D1 — Dry run first

```bash
$ cd ~/enterprise-platform/svc-product-catalog
$ export PROJECT_ID=$(gcloud config get-value project)
$ export IMAGE_TAG="dev-manual-1"
$ export IMAGE_URL="asia-south1-docker.pkg.dev/${PROJECT_ID}/dev-microservices/svc-product-catalog:${IMAGE_TAG}"
```

Use the image Jenkins already built in Part 3:

```bash
$ gcloud artifacts docker images list \
    asia-south1-docker.pkg.dev/${PROJECT_ID}/dev-microservices/svc-product-catalog \
    --include-tags --format="value(tags)" | head -1
```

**Expected output:**
```
dev-1-a1b2c3d,latest
```

```bash
$ export IMAGE_TAG="dev-1-a1b2c3d"   # use YOUR tag
$ export IMAGE_URL="asia-south1-docker.pkg.dev/${PROJECT_ID}/dev-microservices/svc-product-catalog:${IMAGE_TAG}"
$ ./scripts/deploy.sh dev --dry-run
```

**Expected output:**
```
==> Rendering manifests for dev
    rendered deployment.yaml
    rendered hpa.yaml
    rendered networkpolicy.yaml
    rendered pdb.yaml
    rendered service.yaml
    rendered serviceaccount.yaml
==> Validating against the live API server
serviceaccount/product-catalog configured (server dry run)
deployment.apps/product-catalog created (server dry run)
...
==> Dry run only. Rendered output:
[full YAML]
```

**Read the rendered YAML.** Confirm no `${...}` survived and the image URL is real. The script fails loudly if any variable is unsubstituted — that check exists because otherwise you apply a manifest with a literal `${IMAGE_URL}` as the image name and spend twenty minutes reading `ImagePullBackOff`.

### D2 — Deploy

```bash
$ ./scripts/deploy.sh dev
```

**Expected output:**
```
==> Rendering manifests for dev
==> Validating against the live API server
==> Applying to namespace dev
serviceaccount/product-catalog configured
deployment.apps/product-catalog created
service/product-catalog created
horizontalpodautoscaler.autoscaling/product-catalog created
poddisruptionbudget.policy/product-catalog created
networkpolicy.networking.k8s.io/product-catalog created
==> Waiting for rollout of product-catalog
deployment "product-catalog" successfully rolled out
==> Deployed product-catalog:dev-1-a1b2c3d to dev
NAME                               READY   STATUS    RESTARTS   AGE   NODE
product-catalog-7d4b8c9f5-x2k9p    1/1     READY     0          25s   gke-dev-gke-...-x7k2
```

**`1/1 READY`.** Your first service is live.

### D3 — Verify it works

```bash
$ kubectl port-forward -n dev svc/product-catalog 8080:8080 &
$ sleep 2
$ curl -s localhost:8080/healthz
$ curl -s localhost:8080/api/products | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d['count']} products\")"
$ curl -s localhost:8080/metrics | grep -c "^http_requests_total"
```

**Expected output:**
```
{"status":"alive","service":"product-catalog"}
3 products
1
```

**Metrics are flowing.** Confirm Prometheus found it:

```bash
$ curl -s localhost:9090/api/v1/query?query=up%7Bapp%3D%22product-catalog%22%7D \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print('scraped:', r[0]['value'][1] if r else 'NOT FOUND')"
```

**Expected output:**
```
scraped: 1
```

### Common errors

| Symptom | Cause |
|---|---|
| `ERROR: unsubstituted variables remain` | You forgot to `export` one. The script is telling you exactly which. |
| `ImagePullBackOff` | Wrong tag, or the node SA lacks `artifactregistry.reader`. `kubectl describe pod` shows the real reason. |
| Pod `Pending`, `0/2 nodes available` | Quota or node capacity. `kubectl describe pod` → Events. |
| `violates PodSecurity "restricted"` | Your manifests comply — if you see this you edited something. |
| Readiness never passes, liveness OK | Correct behaviour if a dependency is down. `product-catalog` has none, so check logs. |

---

## Section E — Deploy the rest, in dependency order

### Why
Deploy in the order that isolates failure. If `cart` fails and `catalog` is already green, the problem is `cart`.

### Commands

```bash
$ cd ~/enterprise-platform
$ export PROJECT_ID=$(gcloud config get-value project)

$ for svc in payment shipping user-auth notification \
             cart order recommendation checkout frontend; do
    echo "=== $svc ==="
    cd svc-$svc
    export IMAGE_TAG="dev-manual-1"
    export IMAGE_URL="asia-south1-docker.pkg.dev/${PROJECT_ID}/dev-microservices/svc-${svc}:${IMAGE_TAG}"
    # build+push locally since Jenkins hasn't run for these yet
    gcloud auth configure-docker asia-south1-docker.pkg.dev --quiet
    docker build -q -t "${IMAGE_URL}" . && docker push -q "${IMAGE_URL}"
    ./scripts/deploy.sh dev
    cd ..
  done
```

**This takes 15–25 minutes.** The Python images are slower (pip wheels).

**Verify everything is up:**

```bash
$ kubectl get pods -n dev -o wide
```

**Expected output:**
```
NAME                               READY   STATUS    RESTARTS   AGE   NODE
cart-6b9d7c8f4-m3n2q               1/1     Running   0          3m    ...-x7k2
checkout-5f8c9d7b6-p4r5s           1/1     Running   0          2m    ...-p9m4
frontend-7c6b5d4f3-t6u7v           1/1     Running   0          1m    ...-x7k2
notification-8d7e6f5a4-w8x9y       1/1     Running   0          5m    ...-p9m4
order-9e8f7a6b5-z1a2b              1/1     Running   0          3m    ...-x7k2
payment-4a3b2c1d0-c3d4e            1/1     Running   0          7m    ...-p9m4
product-catalog-7d4b8c9f5-x2k9p    1/1     Running   0          15m   ...-x7k2
recommendation-3f2e1d0c9-f5g6h     1/1     Running   0          2m    ...-p9m4
shipping-2b1a0c9d8-i7j8k           1/1     Running   0          6m    ...-x7k2
user-auth-1c0b9a8e7-l9m0n          1/1     Running   0          5m    ...-p9m4
```

**Ten pods, all `1/1 Running`.**

**Check they spread across both nodes** — that's `topologySpreadConstraints` working:

```bash
$ kubectl get pods -n dev -o json | python3 -c "
import sys, json, collections
c = collections.Counter(p['spec']['nodeName'] for p in json.load(sys.stdin)['items'])
for n, k in c.items(): print(f'{k} pods on {n}')"
```

**Expected output:**
```
5 pods on gke-dev-gke-dev-pool-a1b2c3d4-x7k2
5 pods on gke-dev-gke-dev-pool-a1b2c3d4-p9m4
```

**Roughly even.** If all 10 landed on one node, losing that node takes everything down — on a 2-node cluster that's the whole game.

---

## Section F — Prove the NetworkPolicy actually denies

### Why
**This is the most important test in this guide.**

Without default-deny, every per-service NetworkPolicy is decoration. Everyone writes these policies. Almost nobody tests them. Let's test.

### F1 — What SHOULD work

`cart` legitimately calls `product-catalog`:

```bash
$ kubectl exec -n dev deploy/cart -- \
    wget -qO- --timeout=5 http://product-catalog:8080/healthz
```

**Expected output:**
```
{"status":"alive","service":"product-catalog"}
```

### F2 — What should be DENIED

`recommendation` has no business calling `payment`:

```bash
$ kubectl exec -n dev deploy/recommendation -- \
    timeout 8 wget -qO- --timeout=5 http://payment:8080/healthz ; echo "exit=$?"
```

**Expected output:**
```
wget: download timed out
exit=1
```

**The timeout is the success condition.** Traffic was dropped at the eBPF layer before it reached `payment`.

> **Why a timeout, not "connection refused"?** Because the packet is silently dropped, not rejected. An attacker probing your network learns nothing — not even that the service exists. That's default-deny working as intended.

**If this returns `{"status":"alive"}`, stop.** Your default-deny didn't apply, and every NetworkPolicy in this project is doing nothing. Go back to Section A3.

### F3 — Prove DNS still works

DNS is the classic thing default-deny breaks:

```bash
$ kubectl exec -n dev deploy/cart -- nslookup product-catalog.dev.svc.cluster.local
```

**Expected output:**
```
Server:    10.12.0.10
Address:   10.12.0.10:53

Name:      product-catalog.dev.svc.cluster.local
Address:   10.11.0.15
```

> **The single most common NetworkPolicy mistake** is forgetting the DNS egress rule. Every outbound call then fails as a mystery timeout, and you spend an afternoon blaming the application. The `allow-dns` policy in `platform-ops` is why this works.

### F4 — The full matrix

```bash
$ for src in cart recommendation frontend checkout; do
    for dst in product-catalog payment; do
      r=$(kubectl exec -n dev deploy/$src -- timeout 6 wget -qO- --timeout=4 \
           http://$dst:8080/healthz 2>/dev/null && echo ALLOW || echo DENY)
      printf "%-16s -> %-16s %s\n" "$src" "$dst" "$r"
    done
  done
```

**Expected output:**
```
cart             -> product-catalog  ALLOW
cart             -> payment          DENY
recommendation   -> product-catalog  ALLOW
recommendation   -> payment          DENY
frontend         -> product-catalog  ALLOW
frontend         -> payment          DENY
checkout         -> product-catalog  DENY
checkout         -> payment          ALLOW
```

**Read that last pair carefully.** `checkout` can reach `payment` but **not** `product-catalog` — because checkout never calls the catalog directly; it goes through `cart` and `order`. The policy encodes the real architecture, not a guess.

Blast radius: compromise `recommendation` — your least critical, most exposed service — and the attacker reaches `product-catalog` and nothing else. Not payment. Not auth.

---

## Section G — End-to-end: buy something

### Why
Ten healthy pods doesn't mean the system works. The fan-out is where it gets real.

### Commands

```bash
$ kubectl port-forward -n dev svc/frontend 8080:8080 &
$ sleep 2
```

**Home page** (catalog + recommendations aggregated):

```bash
$ curl -s localhost:8080/api/home?userId=usr-demo | python3 -m json.tool | head -20
```

**Expected output:**
```json
{
    "products": [
        {
            "id": "p-1001",
            "name": "Aeron Chair",
            "price": 89000,
            "currency": "INR",
            "stock": 12,
            "category": "furniture"
        },
        ...
    ],
    "recommendations": [...],
    "degraded": false
}
```

**`"degraded": false`** — recommendations came back. If the recommendation service were down you'd get `true` and an empty list, but the page would still render.

**Add to cart** (cart → catalog):

```bash
$ kubectl port-forward -n dev svc/cart 8081:8080 &
$ sleep 2
$ curl -s -X POST localhost:8081/api/carts/usr-demo/items \
    -H 'Content-Type: application/json' \
    -d '{"productId":"p-1002","quantity":2}' | python3 -m json.tool
```

**Expected output:**
```json
{
    "userId": "usr-demo",
    "items": [
        {
            "productId": "p-1002",
            "name": "Mechanical Keyboard",
            "quantity": 2,
            "priceSnapshot": 8900
        }
    ],
    "total": 17800
}
```

**The `name` and `priceSnapshot` came from `product-catalog`.** That's a real inter-service call.

**Checkout — the full fan-out:**

```bash
$ curl -s -X POST localhost:8080/api/checkout \
    -H 'Content-Type: application/json' \
    -d '{"userId":"usr-demo","address":{"line1":"1 MG Rd","city":"Bengaluru","pincode":"560001"},"paymentMethod":"card"}' \
    | python3 -m json.tool
```

**Expected output:**
```json
{
    "orderId": "ord-3f8a2b1c",
    "status": "CONFIRMED",
    "total": 17849,
    "paymentId": "pay-9d4c7e2a1b",
    "shipping": {
        "zone": "metro",
        "cost": 49.0,
        "estimatedDays": 2,
        "freeShippingApplied": false
    }
}
```

**That single call traversed six services**: frontend → checkout → (cart ‖ shipping ‖ payment) → order → catalog → notification.

> **~3% of the time you'll get `402 payment_declined`.** That's deliberate — the payment service simulates real declines so your error budget actually moves. Retry.

**Prove the notification fired:**

```bash
$ kubectl logs -n dev deploy/notification --tail=5 | grep -i queued
```

**Expected output:**
```
{"severity":"INFO","service":"notification","message":"notification queued","template":"order_confirmation"}
```

**Prove stock was reserved:**

```bash
$ curl -s localhost:8081/../api/products/p-1002 2>/dev/null || \
  kubectl exec -n dev deploy/cart -- wget -qO- http://product-catalog:8080/api/products/p-1002
```

**Expected output:**
```json
{"id":"p-1002","name":"Mechanical Keyboard","price":8900,"currency":"INR","stock":138,"category":"peripherals"}
```

**Stock dropped from 140 to 138.** The order genuinely reserved it.

### Test graceful degradation

Kill recommendations and confirm the home page survives:

```bash
$ kubectl scale deploy/recommendation -n dev --replicas=0
$ sleep 5
$ curl -s localhost:8080/api/home?userId=usr-demo | python3 -c "import sys,json; d=json.load(sys.stdin); print('products:', len(d['products']), '| degraded:', d['degraded'])"
```

**Expected output:**
```
products: 6 | degraded: true
```

**The page still works.** `degraded: true`, empty recommendations, products intact. That's the graceful-degradation contract the unit test asserts.

```bash
$ kubectl scale deploy/recommendation -n dev --replicas=1
```

---

## Section H — Let the pipeline do it

### Why
You've proven the manifests work. Now hand it to Jenkins.

### Commands

Push the remaining 9 repos and create their jobs (Part 3 §G2):

```bash
$ cd ~/enterprise-platform
$ for svc in cart checkout frontend order payment shipping user-auth notification recommendation; do
    cd svc-$svc
    cp -r ~/Downloads/enterprise-platform/svc-$svc/. .
    git add . && git commit -q -m "feat: $svc service" && git push -q origin develop
    cd ..
    echo "pushed svc-$svc"
  done
```

Then in Jenkins, create a Multibranch Pipeline for each (same steps as Part 3 §G2).

**Watch a pipeline deploy:**

```
[Pipeline] stage (Deploy to dev)
+ gcloud container clusters get-credentials dev-gke --region asia-south1
+ ./scripts/deploy.sh dev
==> Rendering manifests for dev
==> Applying to namespace dev
deployment.apps/cart configured
==> Waiting for rollout of cart
deployment "cart" successfully rolled out
[Pipeline] stage (Smoke test)
+ kubectl run smoke-cart-4 --namespace=dev --overrides=...
{"status":"ready","service":"cart"}
Finished: SUCCESS
```

**`{"status":"ready"}` from the smoke test.** Note the `--overrides` in that stage: the namespace enforces PSA `restricted`, and a bare `kubectl run` sets no securityContext, so the API server rejects it outright — *after* a successful deploy, which is a confusing place to fail.

**Verify the pipeline's image is what's running:**

```bash
$ kubectl get deploy cart -n dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
$ kubectl get deploy cart -n dev -o jsonpath='{.metadata.annotations.platform/git-commit}{"\n"}'
```

**Expected output:**
```
asia-south1-docker.pkg.dev/my-project-id/dev-microservices/svc-cart:dev-4-9f2e1a8
9f2e1a8
```

**You can trace a running pod back to a commit.** That's the annotation the pipeline injects, and it's what you'll want at 3am.

---

## Section I — See your SLOs

```bash
$ kubectl port-forward -n monitoring svc/grafana 3000:3000 &
```

Open **http://localhost:3000**, log in with the password from A3.

Generate traffic so the SLOs have something to measure:

```bash
$ for i in $(seq 1 200); do
    curl -s localhost:8080/api/home?userId=usr-$i > /dev/null
  done
```

Then in Prometheus (**localhost:9090**), try:

```promql
slo:frontend:success_ratio5m
```

**Expected output:** a value near `1`.

```promql
slo:frontend:error_budget_remaining
```

**Expected output:** a value near `1` (budget untouched).

> **Seeing `NaN` or "empty result"?** Expected until traffic flows. The rules divide by request rate — no requests, no ratio. That's correct behaviour, not a broken install.

**Check no alerts are firing:**

```bash
$ curl -s localhost:9090/api/v1/alerts | python3 -c "import sys,json; a=json.load(sys.stdin)['data']['alerts']; print(f'{len(a)} firing')"
```

**Expected output:**
```
0 firing
```

---

## Section J — Checklist

- [ ] `grep -c "kind: PrometheusRule" platform-ops/slo/*.yaml` returns `0 0 0`
- [ ] `bootstrap.sh` ran clean; Grafana password saved
- [ ] `kubectl get networkpolicy -n dev` shows `default-deny-all` and `allow-dns`
- [ ] Prometheus loaded **129 rules** across 3 groups
- [ ] Three secrets in Secret Manager (created with `echo -n`)
- [ ] **WI test prints `dev-payment@...`**, not the node SA
- [ ] **`cart` reading the payment secret is `PERMISSION_DENIED`**
- [ ] 10 pods `1/1 Running`, spread ~5/5 across both nodes
- [ ] **`recommendation → payment` TIMES OUT**
- [ ] `cart → product-catalog` succeeds
- [ ] DNS resolves from inside a pod
- [ ] Checkout returns a real `orderId` and stock decrements
- [ ] Scaling recommendation to 0 gives `degraded: true`, page still renders
- [ ] Pipeline deploys and the smoke test returns `{"status":"ready"}`
- [ ] `slo:frontend:success_ratio5m` returns a value

### The two tests that matter most

**1. NetworkPolicy actually denies** (F2). If `recommendation → payment` succeeds, every policy here is decoration.

**2. Workload Identity gives the right identity** (C). If the pod shows the node SA, you have no per-service isolation — one compromised pod has every permission every pod has.

Everything else is comfort. These two are the security model.

---

## What's still not connected

| Gap | Part |
|---|---|
| Alertmanager: `REPLACE_WITH_SLACK_WEBHOOK`, `REPLACE_WITH_PAGERDUTY_ROUTING_KEY` | 5 |
| Runbook URLs point at `github.com/YOUR_ORG/...` | 5 |
| No Ingress/Gateway — nothing publicly reachable, port-forward only | 5 |
| No Grafana dashboards (datasource wired, panels empty) | 5 |
| `staging` and `prod` namespaces exist but are empty | 5 |
| Prod canary (`canary.sh`) never exercised | 5 |

---

## Next: Part 5 — Production, alerting and the last mile

Wire Alertmanager to Slack/PagerDuty, build Grafana dashboards, add a Gateway so the frontend is actually reachable, promote `develop` → `staging` → `main` through the real gates, watch the canary run, and **deliberately break a service to watch a burn-rate alert fire and a runbook get used**.

> **Before you stop:** `terraform destroy` in `environments/dev`. Snapshot Jenkins first:
> ```bash
> $ gcloud compute disks snapshot dev-jenkins-home --zone=asia-south1-a \
>     --snapshot-names=jenkins-home-$(date +%Y%m%d)
> ```
