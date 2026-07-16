# Part 5 — Production, Alerting and the Last Mile

**Before you start:**
- Part 4 complete: 10 pods running in `dev`, NetworkPolicy proven to deny, checkout returns a real order

**By the end:** publicly reachable, alerts routed, dashboards live, promoted to prod through real gates, canary exercised — and you'll have **deliberately broken a service to watch a burn-rate alert fire.**

---

## Section A — Make it publicly reachable

### Why
Everything so far needed `port-forward`. Real users don't have kubectl.

### A1 — Redeploy the frontend with the new annotations

```bash
$ cd ~/enterprise-platform/svc-frontend
$ cp -r ~/Downloads/enterprise-platform/svc-frontend/. .
$ ls k8s/base/
```

**Expected output:**
```
backendconfig.yaml  deployment.yaml  hpa.yaml  networkpolicy.yaml
pdb.yaml  service.yaml  serviceaccount.yaml
```

**`backendconfig.yaml` is what makes the Ingress work.** Without it, GKE health-checks `/` — which our frontend doesn't serve — marks every backend UNHEALTHY, and returns 502 for everything. It's the single most common cause of "my GKE Ingress returns 502".

```bash
$ export PROJECT_ID=$(gcloud config get-value project)
$ export IMAGE_TAG="dev-manual-1"
$ export IMAGE_URL="asia-south1-docker.pkg.dev/${PROJECT_ID}/dev-microservices/svc-frontend:${IMAGE_TAG}"
$ ./scripts/deploy.sh dev
```

**Verify the annotations landed:**

```bash
$ kubectl get svc frontend -n dev -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
```

**Expected output:**
```json
{
    "cloud.google.com/backend-config": "{\"default\": \"frontend-backendconfig\"}",
    "cloud.google.com/neg": "{\"ingress\": true}"
}
```

```bash
$ kubectl get backendconfig -n dev
```

**Expected output:**
```
NAME                     AGE
frontend-backendconfig   30s
```

### A2 — Create the load balancer

```bash
$ cd ~/enterprise-platform/platform-ops
$ kubectl apply -f gateway/ingress-dev.yaml
```

**Expected output:**
```
ingress.networking.k8s.io/frontend created
```

> **This lives in `platform-ops`, not `svc-frontend/k8s/base/`, on purpose.** `deploy.sh` applies that entire directory to whatever environment you name — so an Ingress there would create **three external load balancers**, one per environment, and bill you for all three.

**Now wait. This genuinely takes 5–10 minutes.**

```bash
$ kubectl get ingress frontend -n dev -w
```

**Expected output:**
```
NAME       CLASS    HOSTS   ADDRESS         PORTS   AGE
frontend   <none>   *                       80      30s
frontend   <none>   *       34.117.42.180   80      6m
```

`Ctrl+C` once ADDRESS appears.

**A 502 during provisioning is normal.** The backends aren't healthy yet.

### A3 — Check the health check before blaming anything

```bash
$ export INGRESS_IP=$(kubectl get ingress frontend -n dev -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
$ echo $INGRESS_IP
$ kubectl describe ingress frontend -n dev | grep -A3 "Annotations:.*backends"
```

**Expected output:**
```
34.117.42.180
    ingress.kubernetes.io/backends: {"k8s1-a1b2c3d4-dev-frontend-8080-9e8f7a6b":"HEALTHY"}
```

**`HEALTHY` is what you're looking for.**

> **If it says `UNHEALTHY`,** the health check is hitting the wrong path. Verify:
> ```bash
> $ gcloud compute health-checks list --format="table(name,httpHealthCheck.requestPath)"
> ```
> It must show `/readyz`. If it shows `/`, your BackendConfig isn't attached — check the annotation names match exactly.

### A4 — Hit it for real

```bash
$ curl -s http://${INGRESS_IP}/api/home?userId=usr-demo | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{len(d['products'])} products, degraded={d['degraded']}\")"
```

**Expected output:**
```
6 products, degraded=False
```

**That's a real HTTP request from the public internet**, through a Google load balancer, into a pod on a private node, which called two other services. No port-forward.

**Prove the NetworkPolicy still holds:**

```bash
$ curl -s -m 5 http://${INGRESS_IP}/../payment/healthz -o /dev/null -w "%{http_code}\n"
```

**Expected output:**
```
404
```

The LB only routes to `frontend`. Nothing else is exposed, and the internal default-deny is still in force behind it.

### Common errors

| Symptom | Cause |
|---|---|
| 502 after 15+ minutes | Backend `UNHEALTHY`. Check BackendConfig is attached and path is `/readyz`. |
| `default backend - 404` | Ingress created before the Service existed. Delete and re-apply the Ingress. |
| ADDRESS never appears | `http_load_balancing` addon disabled. It's enabled in our GKE module — check you're on the right cluster. |
| Works, but client IP is a node IP | NEG annotation missing → not container-native. |

> **HTTPS:** needs a real domain. `gateway/managed-cert-example.yaml` has the steps. Fair warning — managed certs take 15–60 minutes and **fail silently if DNS isn't already resolving.**

---

## Section B — Route the alerts

### Why
Alertmanager still has `REPLACE_WITH_SLACK_WEBHOOK`. Alerts fire into the void.

### B1 — Get a webhook

**Option A — real Slack:**
1. https://api.slack.com/apps → **Create New App** → **From scratch**
2. Name: `Platform Alerts`, pick your workspace
3. **Incoming Webhooks** → toggle **On** → **Add New Webhook to Workspace**
4. Choose `#platform-alerts` → **Allow**
5. Copy the `https://hooks.slack.com/services/T.../B.../xxx` URL

**Option B — no Slack?** Use https://webhook.site — it gives you a URL instantly and shows every payload. Perfect for testing the routing without a workspace.

### B2 — Wire it in

```bash
$ cd ~/enterprise-platform/platform-ops
$ export SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
$ sed -i "s|REPLACE_WITH_SLACK_WEBHOOK|${SLACK_WEBHOOK}|g" monitoring/alertmanager.yaml
$ grep -c "hooks.slack.com\|webhook.site" monitoring/alertmanager.yaml
```

**Expected output:**
```
4
```

Four receivers wired.

> **PagerDuty:** if you have an account, create a service → Integrations → Events API v2 → copy the routing key → `sed -i "s|REPLACE_WITH_PAGERDUTY_ROUTING_KEY|your-key|"`. No account? Point the `pagerduty` receiver at Slack too for now — the *routing logic* is what you're learning.

```bash
$ kubectl apply -f monitoring/alertmanager.yaml
$ kubectl rollout restart deploy/alertmanager -n monitoring
$ kubectl rollout status deploy/alertmanager -n monitoring
```

> **Don't commit that webhook.** It's a credential. In a real setup it comes from Secret Manager. Check: `git diff --stat` before committing, and consider `git checkout monitoring/alertmanager.yaml` after applying.

### B3 — Fix the runbook URLs

Every alert links to a runbook at `github.com/YOUR_ORG/...`:

```bash
$ export OWNER="your-github-username-or-org"
$ sed -i "s|YOUR_ORG|${OWNER}|g" slo/burn-rate-alerts.yaml
$ grep -m1 runbook_url slo/burn-rate-alerts.yaml
```

**Expected output:**
```
    runbook_url: https://github.com/your-org/platform-ops/blob/main/runbooks/frontend.md
```

Reload the rules:

```bash
$ kubectl create configmap prometheus-rules \
    --namespace monitoring \
    --from-file=slo/recording-rules.yaml \
    --from-file=slo/burn-rate-alerts.yaml \
    --from-file=slo/infrastructure-alerts.yaml \
    --dry-run=client -o yaml | kubectl apply -f -

$ kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
$ sleep 3
$ curl -s -X POST localhost:9090/-/reload && echo "reloaded"
```

**Expected output:**
```
reloaded
```

> ConfigMap changes take up to 60s to appear in the pod. `/-/reload` works because of `--web.enable-lifecycle` in the Prometheus args.

**Verify:**

```bash
$ curl -s localhost:9090/api/v1/rules | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']['groups']
print('groups:', len(d), '| rules:', sum(len(g['rules']) for g in d))"
```

**Expected output:**
```
groups: 3 | rules: 129
```

### B4 — Test the pipe end to end

Fire a fake alert straight at Alertmanager:

```bash
$ kubectl port-forward -n monitoring svc/alertmanager 9093:9093 &
$ sleep 2
$ curl -s -X POST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
    "labels": {"alertname":"PipeTest","severity":"warning","service":"frontend"},
    "annotations": {"summary":"Testing the alert pipeline end to end"}
  }]' && echo "sent"
```

**Expected output:**
```
sent
```

**Check Slack (or webhook.site) within ~30 seconds.** You should see the message in `#platform-warnings`.

> **Nothing arrived?** `kubectl logs -n monitoring deploy/alertmanager | grep -i error`. Usually a malformed webhook URL.
>
> **Why 30s and not instant?** `group_wait: 30s`. During a real incident this bundles related alerts so you get **one** page listing five services, not five pages. That's deliberate.

---

## Section C — Dashboards

### Why
Your Grafana has a datasource and nothing else.

```bash
$ cd ~/enterprise-platform/platform-ops
$ ls monitoring/dashboards/
```

**Expected output:**
```
platform-overview.json
```

Apply the provisioning:

```bash
$ kubectl apply -f monitoring/grafana-dashboards.yaml
$ kubectl create configmap grafana-dashboards \
    --namespace monitoring \
    --from-file=monitoring/dashboards/ \
    --dry-run=client -o yaml | kubectl apply -f -
$ kubectl apply -f monitoring/grafana.yaml
$ kubectl rollout status deploy/grafana -n monitoring
```

**Confirm the datasource uid** — this is the fix from the box at the top:

```bash
$ kubectl get cm grafana-datasources -n monitoring -o jsonpath='{.data.datasources\.yaml}' | grep uid
```

**Expected output:**
```
  uid: prometheus
```

> **The `uid` matters.** The dashboard JSON pins `uid: prometheus`. Without it, Grafana assigns a random uid and every panel reads *"Datasource prometheus was not found"*.

```bash
$ kubectl port-forward -n monitoring svc/grafana 3000:3000 &
```

Open **http://localhost:3000** → **Dashboards** → **Platform** → **Platform Overview**.

Generate traffic so it isn't empty:

```bash
$ for i in $(seq 1 300); do curl -s http://${INGRESS_IP}/api/home?userId=usr-$i > /dev/null; done
```

**You should see:** error budget bars near 100% green, request rate climbing, p99 latency, dependency calls.

The **Error budget remaining** panel at the top is the one that matters. It answers "can we ship?" in one glance — which is the entire point of an error budget.

---

## Section D — Promote to staging and prod

### Why
Time to use the gates you built in Part 1B.

### D1 — develop → staging

```bash
$ cd ~/enterprise-platform/svc-product-catalog
$ git checkout staging && git merge develop --no-edit && git push origin staging
```

**Expected output:**
```
remote: error: GH013: Repository rule violations found for refs/heads/staging.
remote: - Changes must be made through a pull request.
! [remote rejected] staging -> staging
```

**That rejection is your branch protection working.** Do it properly:

```bash
$ git reset --hard origin/staging
$ git checkout develop
```

On GitHub: **Pull requests** → **New pull request** → base `staging` ← compare `develop` → **Create** → **Merge** (approve first if needed).

Jenkins picks up `staging` within ~2 minutes and deploys to the `staging` namespace.

**But it will fail** — and for a reason worth understanding:

```bash
$ kubectl get pods -n staging
```

**Expected output:**
```
No resources found in staging namespace.
```

**Staging has no secrets and no ServiceAccounts.** Create them:

```bash
$ export PROJECT_ID=$(gcloud config get-value project)
$ for ENV in staging prod; do
    echo -n "fake-gateway-key-${ENV}" | gcloud secrets create "${ENV}-payment-gateway-key" \
      --project=$PROJECT_ID --replication-policy=automatic --data-file=- 2>/dev/null
    openssl rand -base64 48 | tr -d '\n' | gcloud secrets create "${ENV}-jwt-secret" \
      --project=$PROJECT_ID --replication-policy=automatic --data-file=- 2>/dev/null
    echo -n "fake-smtp-${ENV}" | gcloud secrets create "${ENV}-smtp-api-key" \
      --project=$PROJECT_ID --replication-policy=automatic --data-file=- 2>/dev/null

    kubectl create secret generic payment-secrets -n $ENV \
      --from-literal=PAYMENT_GATEWAY_KEY="$(gcloud secrets versions access latest --secret=${ENV}-payment-gateway-key)" 2>/dev/null
    kubectl create secret generic user-auth-secrets -n $ENV \
      --from-literal=JWT_SECRET="$(gcloud secrets versions access latest --secret=${ENV}-jwt-secret)" 2>/dev/null
    kubectl create secret generic notification-secrets -n $ENV \
      --from-literal=SMTP_API_KEY="$(gcloud secrets versions access latest --secret=${ENV}-smtp-api-key)" 2>/dev/null
    echo "$ENV secrets ready"
  done
```

> **This is a genuine lesson, not a detour.** Secrets are per-environment and Terraform doesn't create their *values* — deliberately, because Terraform state would then contain your secrets in plaintext. "Works in dev, 403 in prod" is nearly always this.
>
> **Workload Identity, however, is already done.** Terraform created `staging-payment@...` and `prod-payment@...` SAs for all three environments in Part 2. Only the secret *values* are manual.

Re-run the Jenkins build → **SUCCESS**.

### D2 — staging → prod

PR from `staging` → `main` on GitHub. Merge.

Jenkins now hits something new:

```
[Pipeline] stage (Approve production release)
Deploy svc-product-catalog:prod-7-9f2e1a8 to PRODUCTION?
Proceed or Abort
```

**It stops and waits for a human.** Click **Deploy**.

> **Notice what just happened.** Three gates, each a different kind:
> - **PR + approval** — a human read the diff
> - **Quality gate + Trivy** — machines checked the code and the image
> - **Manual input** — a human chose the moment
>
> No single one is sufficient. Together they're why prod doesn't break on a Friday.

**Verify prod is genuinely different:**

```bash
$ kubectl get deploy product-catalog -n prod -o jsonpath='{.spec.replicas}{"\n"}'
$ kubectl get deploy product-catalog -n dev -o jsonpath='{.spec.replicas}{"\n"}'
$ kubectl get pdb -n prod
```

**Expected output:**
```
2
1
NAME              MIN AVAILABLE   ALLOWED DISRUPTIONS   AGE
product-catalog   1               1                     2m
```

**Same manifests, different values.** That's `k8s/env/prod.env` vs `dev.env` — the envsubst mechanism doing exactly what Helm values would.

> **`PDB_MIN_AVAILABLE=0` in dev is deliberate.** With 1 replica and `minAvailable: 1`, a node drain would block **forever** — the PDB would never allow the only pod to be evicted. In dev that's a self-inflicted outage during routine maintenance.

---

## Section E — Watch a canary

### Why
`canary.sh` has never run. Let's use it — and be honest about what it is.

```bash
$ cd ~/enterprise-platform/svc-product-catalog
$ export PROJECT_ID=$(gcloud config get-value project)
$ export IMAGE="asia-south1-docker.pkg.dev/${PROJECT_ID}/prod-microservices/svc-product-catalog:$(kubectl get deploy product-catalog -n prod -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -d: -f2)"
$ export BAKE_SECONDS=60      # 300 in reality; shortened so you can watch
$ export CANARY_PERCENT=50    # 2 replicas -> 1 canary pod
$ ./scripts/canary.sh prod product-catalog "${IMAGE}"
```

**Expected output:**
```
==> Deploying canary product-catalog-canary at 50%
deployment.apps/product-catalog-canary created
deployment "product-catalog-canary" successfully rolled out
==> Baking for 60s, watching error rate
    canary error rate: 0% (threshold 1.0%)
==> Canary healthy. Promoting to stable.
deployment.apps/product-catalog image updated
deployment "product-catalog" successfully rolled out
==> Removing canary deployment
==> Promotion complete
```

**While it bakes**, in another terminal:

```bash
$ kubectl get pods -n prod -l app=product-catalog
```

**Expected output:**
```
NAME                                      READY   STATUS    AGE
product-catalog-7d4b8c9f5-x2k9p           1/1     Running   10m
product-catalog-7d4b8c9f5-m3n2q           1/1     Running   10m
product-catalog-canary-6c5b4d3f2-p9r8s    1/1     Running   30s
```

**Three pods, one is the canary.** The Service selects on `app: product-catalog`, **not** on `version` — so all three receive traffic. That's how a canary gets real traffic with no service mesh.

> ### What this actually is, honestly
>
> This is **not** what a real enterprise uses. Argo Rollouts or Flagger do this properly.
>
> | | `canary.sh` | Argo Rollouts |
> |---|---|---|
> | Traffic split | By **replica count** — 50% means 1 of 3 pods, roughly 33% of traffic | Precise, via mesh/ingress weights |
> | Analysis | One Prometheus query, once, after the bake | Continuous, multiple metrics, configurable |
> | Abort | Delete the deployment | Automatic rollback mid-rollout |
> | Progressive | No — one step | 10% → 25% → 50% → 100% with gates |
>
> It was excluded by the project constraints. The script does the closest safe thing. **Knowing why the real tool exists is worth more than pretending you don't need it** — and that's a good interview answer.

---

## Section F — Break something on purpose

### Why
**This is the most valuable section in all five parts.**

You have SLOs, burn-rate alerts, and runbooks. None of it is proven. An alert you've never seen fire is a hypothesis.

### F1 — Set up the watch

Terminal 1:
```bash
$ kubectl port-forward -n monitoring svc/prometheus 9090:9090
```

Terminal 2 — generate steady traffic:
```bash
$ while true; do curl -s http://${INGRESS_IP}/api/home?userId=usr-$RANDOM > /dev/null; sleep 0.2; done
```

Terminal 3 — watch the SLO:
```bash
$ watch -n 10 'curl -s "localhost:9090/api/v1/query?query=slo:frontend:success_ratio5m" | python3 -c "import sys,json; r=json.load(sys.stdin)[\"data\"][\"result\"]; print(\"success ratio:\", round(float(r[0][\"value\"][1]),4) if r else \"no data\")"'
```

**Expected output** (after ~2 min):
```
success ratio: 1.0
```

### F2 — Break it

Take down `product-catalog`. The frontend depends on it and **cannot** degrade — unlike recommendations, the catalog is load-bearing.

```bash
$ kubectl scale deploy/product-catalog -n dev --replicas=0
```

**Watch terminal 3:**
```
success ratio: 0.94
success ratio: 0.71
success ratio: 0.23
success ratio: 0.0
```

**The error budget is burning in real time.**

### F3 — Watch the alert fire

```bash
$ watch -n 15 'curl -s localhost:9090/api/v1/alerts | python3 -c "
import sys,json
a=json.load(sys.stdin)[\"data\"][\"alerts\"]
[print(x[\"labels\"][\"alertname\"], \"|\", x[\"state\"], \"|\", x[\"labels\"].get(\"severity\")) for x in a] or print(\"none firing\")"'
```

**Expected output** after ~2–4 minutes:
```
FrontendErrorBudgetFastBurn | pending | critical
```

Then after `for: 2m`:
```
FrontendErrorBudgetFastBurn | firing | critical
```

**Check Slack.** The alert should arrive with a runbook link.

> **Why ~5 minutes and not instant?** The alert needs **both** the 5m *and* 1h windows above 14.4× budget, then `for: 2m`. That two-window `and` is what stops a 30-second blip paging you at 3am. You're watching the design work.

### F4 — Use the runbook

The alert links to `runbooks/frontend.md`. Follow it:

```bash
# 1. Is it one pod or all of them?
$ kubectl get pods -n dev -l app=frontend -o wide

# 2. What changed?
$ kubectl rollout history deployment/frontend -n dev

# 3. What do the logs say?
$ kubectl logs -n dev -l app=frontend --tail=20 | grep -i error
```

**Expected output:**
```
{"severity":"WARN","service":"frontend","dependency":"product-catalog","status":"network_error","msg":"dependency call failed"}
```

**The runbook said check dependencies.** The logs name the dependency. Confirm with the metric the runbook gives you:

```bash
$ curl -s 'localhost:9090/api/v1/query?query=sum+by+(dependency,status)+(rate(dependency_requests_total{app="frontend"}[5m]))' \
  | python3 -c "
import sys,json
for r in json.load(sys.stdin)['data']['result']:
    print(r['metric']['dependency'], r['metric']['status'], round(float(r['value'][1]),3))"
```

**Expected output:**
```
product-catalog failure 4.8
recommendation success 4.8
```

**`product-catalog` is failing, `recommendation` is fine.** Instrumentation you wrote in Part 0 telling you exactly where to look — no guessing.

### F5 — Fix and watch it resolve

```bash
$ kubectl scale deploy/product-catalog -n dev --replicas=1
$ kubectl rollout status deploy/product-catalog -n dev
```

Terminal 3:
```
success ratio: 0.0
success ratio: 0.35
success ratio: 0.88
success ratio: 1.0
```

The alert moves to `resolved` and Slack gets a resolution message.

**Now look at the damage:**

```bash
$ curl -s "localhost:9090/api/v1/query?query=slo:frontend:error_budget_remaining" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print('budget remaining:', round(float(r[0]['value'][1])*100,2), '%')"
```

**Expected output:**
```
budget remaining: 71.34 %
```

**A ~4-minute outage cost ~29% of your 30-day budget.** That's the number that makes SLOs real. Not "we should have less downtime" — *"we have 43 minutes for the month and just spent 12 of them."*

Stop the traffic loop (`Ctrl+C` in terminal 2).

### F6 — The error budget policy

That's the whole point. Not a dashboard — a **decision rule**:

| Budget remaining | What happens |
|---|---|
| > 50% | Ship freely. You have room. |
| 25–50% | Ship, but be careful. No risky changes on a Friday. |
| < 25% | Reliability work only. Feature work pauses. |
| 0% | **Freeze.** `FrontendErrorBudgetExhausted` fires and pages. |

`ErrorBudgetExhausted` isn't punishment — it's the policy executing itself. And if it fires constantly, either the SLO is wrong or the service genuinely needs investment. **Both are worth knowing**, and both are conversations the budget lets you have with data instead of opinions.

---

## Section G — Final checklist

- [ ] `ls svc-frontend/k8s/base/backendconfig.yaml` exists
- [ ] Ingress has an ADDRESS, backends `HEALTHY`
- [ ] `curl http://$INGRESS_IP/api/home` returns products — no port-forward
- [ ] Alertmanager wired; test alert reached Slack/webhook.site
- [ ] Runbook URLs point at your real org
- [ ] Prometheus: 3 groups, **129 rules**
- [ ] Grafana datasource has `uid: prometheus`; dashboard panels render
- [ ] Direct push to `staging` **rejected** by branch protection
- [ ] staging + prod secrets created
- [ ] Prod deploy **paused for human approval**
- [ ] prod has 2 replicas, dev has 1 — same manifests, different env files
- [ ] Canary ran: 3 pods, promoted, cleaned up
- [ ] **Deliberately broke `product-catalog` and watched `FrontendErrorBudgetFastBurn` fire**
- [ ] Followed the runbook; `dependency_requests_total` named the culprit
- [ ] Saw the error budget drop and recover

---

## What you actually built

Twelve repos. 344 files. A 2-node GKE cluster running 10 services across 3 environments, with:

- **Zero JSON keys** in any pod — Workload Identity throughout
- **Default-deny networking**, proven: `recommendation → payment` times out
- **Least privilege**, proven: `cart` reading the payment secret is `PERMISSION_DENIED`; the Jenkins controller cannot deploy
- **Gates that actually block** — quality gate, Trivy HIGH/CRITICAL, PR approval, manual prod input
- **SLOs with burn-rate alerts**, proven by breaking something on purpose
- **Runbooks** linked from every page, that name the culprit

### The compromises, stated plainly

Worth being able to say out loud:

| Constraint | What it cost |
|---|---|
| No Helm/Kustomize | No packaging, no `helm rollback`, no charts. envsubst covers most of what teams use Helm values for. |
| No shared library | Jenkinsfile ×10. A pipeline change is a 10-repo change. **That pain is the argument for a shared library** — you've now felt it. |
| No Argo Rollouts | `canary.sh` splits by replica count, analyses once. No progressive steps, no auto-rollback mid-rollout. |
| No GitOps | Cluster can drift from Git and nothing notices. GitOps is the default now. |
| Private Jenkins | SCM polling. 2-min latency, constant API calls. Fine at 10 repos, breaks at 200. |
| 2 nodes, 3 envs, 1 cluster | Namespaces are a soft boundary. Prod should be its own cluster. Node failure hits all three. |
| Regional cluster, single-zone nodes | HA control plane, but a zone outage takes the workloads down. |

### What I'd add next, in order

1. **Argo CD** — the single biggest gap. Git as the source of truth.
2. **Argo Rollouts** — replace `canary.sh` with the real thing.
3. **A real database** — everything is in-memory. Cloud SQL + connection pooling changes the whole reliability story.
4. **Distributed tracing** — you have metrics and logs. When checkout is slow across 6 services, you'll want traces.
5. **Prod in its own cluster and project** — the real blast-radius boundary.

---

## Tear it down

```bash
$ gcloud compute disks snapshot dev-jenkins-home --zone=asia-south1-a \
    --snapshot-names=jenkins-home-$(date +%Y%m%d)

$ kubectl delete ingress frontend -n dev    # or the LB may orphan

$ cd ~/enterprise-platform/platform-infrastructure/environments/dev
$ terraform destroy
```

**Verify nothing is still billing you:**

```bash
$ gcloud compute instances list
$ gcloud container clusters list
$ gcloud compute forwarding-rules list
$ gcloud compute disks list
```

**Expected output:**
```
Listed 0 items.
Listed 0 items.
Listed 0 items.
Listed 0 items.
```

> **Check `disks` and `forwarding-rules` specifically.** PVCs created *by Kubernetes* and load balancers created *by Ingress* aren't in Terraform state — Terraform doesn't know to delete them. This is the classic way a "destroyed" environment keeps costing money. Delete them by hand if they linger.

Rebuild tomorrow with `terraform apply`. That's the whole point.
