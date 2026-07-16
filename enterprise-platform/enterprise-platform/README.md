# Enterprise Microservices Platform on GCP

A complete, production-shaped e-commerce platform: **10 microservices**, each in
its own repo, deployed to a **2-node GKE cluster** across three environments, via
**Jenkins + SonarQube + Terraform**.

This is not a toy. The services make real calls to each other, the pipeline has
real gates that really block, and the SRE layer has real SLOs with burn-rate
alerts. Where a constraint forced a compromise, it's marked and explained rather
than hidden.

---

## ⚠️ Read this before anything else

**This directory is a staging area, not the final layout.** Each top-level folder
becomes its **own GitHub repository** — 11 repos + `platform-ops` = 12.

```bash
# For each folder:
cd svc-frontend
git init
git remote add origin https://github.com/YOUR_ORG/svc-frontend.git
git add . && git commit -m "feat: initial service"
git push -u origin develop
```

They are shipped together only so you can read them together.

**Cost:** three environments means three GKE clusters and twelve VMs. That is
real money — roughly ₹40–60k/month if you leave all three running.
**Build `dev` only.** Run `terraform destroy` when you stop for the day.

---

## What's here

```
platform-infrastructure/   Terraform: VPC, GKE (2 nodes), IAM, Artifact Registry,
                           Workload Identity, 4 tooling VMs
platform-ops/              SRE layer: namespaces, quotas, default-deny, Prometheus,
                           Grafana, Alertmanager, SLOs, burn-rate alerts, runbooks
svc-frontend/              Node.js  — BFF, the front door
svc-product-catalog/       Node.js  — products, prices, stock
svc-cart/                  Node.js  — shopping carts
svc-checkout/              Node.js  — the orchestrator; revenue happens here
svc-order/                 Node.js  — order creation and history
svc-payment/               Python   — authorise / capture / refund
svc-shipping/              Python   — shipping quotes
svc-user-auth/             Python   — register / login / verify
svc-notification/          Python   — transactional messages
svc-recommendation/        Python   — product suggestions
```

Every service repo contains:

```
src/                  application code
tests/                unit tests, wired to coverage
Dockerfile            multi-stage, non-root, correct PID 1
Jenkinsfile           full pipeline, no shared library
sonar-project.properties
k8s/base/*.yaml       plain YAML with ${VAR} placeholders
k8s/env/{dev,staging,prod}.env    the values
scripts/deploy.sh     envsubst render + apply + rollout gate + auto-rollback
scripts/canary.sh     manual canary for prod
README.md
```

---

## How the services actually talk

Not a diagram of boxes that never call each other — these are real HTTP calls
with timeouts, retries and dependency metrics.

```
                        browser
                           │
                      ┌────▼─────┐
                      │ frontend │  (BFF: aggregates, degrades gracefully)
                      └────┬─────┘
        ┌──────────┬───────┼────────┬──────────────┐
        ▼          ▼       ▼        ▼              ▼
    catalog      cart    order   recommendation  checkout
        ▲          │       │        │               │
        │          │       │        │        ┌──────┼───────┬─────────┐
        └──────────┴───────┴────────┘        ▼      ▼       ▼         ▼
              (everyone reads catalog)    payment shipping order  notification
```

**`checkout` is the interesting one.** It fans out: read cart → *(shipping quote
‖ payment authorise in parallel)* → create order → capture payment → clear cart →
notify. The notification step is wrapped in its own try/catch — **a failed email
must not fail a paid order.** That's a deliberate reliability decision, and it's
commented as one in the code.

**`recommendation` degrades.** If the catalog is unreachable it returns `[]` and
a `degraded: true` flag. The home page still renders. The unit test asserts this
— it's a contract, not an accident.

---

## Environments

One cluster, three namespaces, branch-driven promotion.

| Branch | Namespace | Gate |
|---|---|---|
| `develop` | `dev` | Automatic |
| `staging` | `staging` | PR + 1 approval to merge, then automatic |
| `main` | `prod` | PR + approval → **manual input gate in Jenkins** → canary |

---

## The pipeline

```
Checkout → Install → Lint → Unit tests
   → SonarQube scan → Quality gate ......... BLOCKS the build
   → Docker build
   → Trivy scan (HIGH/CRITICAL) ............ BLOCKS the build
   → Push to Artifact Registry
   → Deploy to branch-mapped namespace
   → [prod only] human approval → canary
   → Smoke test
```

Two of those stages are the difference between a real pipeline and a demo: the
**quality gate** and the **Trivy gate** stop the build. They don't print a
warning that everyone learns to ignore.

---

## Do this in order

### 1. Infrastructure
```bash
cd platform-infrastructure/environments/dev
# edit backend.tf (your state bucket) and terraform.tfvars (project + your IP)
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.gcp-keys/terraform-admin-key.json"
terraform init && terraform apply

terraform output kubectl_connect_command   # run it
kubectl get nodes                          # must show exactly 2
```

### 2. Platform foundations — **before any service**
```bash
cd ../../../platform-ops
./scripts/bootstrap.sh
```
Namespaces, quotas, **default-deny networking**, and monitoring. Doing this after
the services means retro-fitting security into a running system.

### 3. Secrets
```bash
# See svc-payment/README-SECRETS.md
gcloud secrets create dev-jwt-secret --replication-policy=automatic --data-file=-
```

### 4. One service, by hand, to prove the path
```bash
cd ../svc-product-catalog
docker build -t test .
export IMAGE_URL="asia-south1-docker.pkg.dev/PROJECT/dev-microservices/svc-product-catalog:v1"
export IMAGE_TAG=v1 PROJECT_ID=your-project
./scripts/deploy.sh dev --dry-run    # look at the rendered YAML first
./scripts/deploy.sh dev
```

Start with `product-catalog`: it has **no dependencies**, so if it fails the
problem is your cluster, not your service graph. Then `cart` (needs catalog),
then `checkout` (needs everything).

### 5. Jenkins, then the rest
Only automate a path you've already walked manually.

---

## The decisions worth understanding

These come up in interviews, and more importantly they're the ones that bite.

**Exactly 2 nodes, on a regional cluster.** `node_count` is **per zone**. A
regional cluster spans 3 zones, so `node_count = 2` naively gives you **6 nodes**.
The module pins `node_locations` to one zone. You keep an HA control plane but
your nodes are single-zone — a zone outage takes the workloads down. That's the
cost of the 2-node requirement, stated plainly.

**No CPU limits. Memory limits only.** CPU is compressible; a limit causes
throttling that looks exactly like a latency bug and burns days of debugging.
Memory isn't compressible, so it's capped — one pod OOMKilled beats a node dying
and taking half a 2-node cluster with it.

**Liveness never checks dependencies.** If the catalog is down, restarting the
cart pod fixes nothing and turns a partial outage into a total one. Liveness asks
"am I wedged?"; readiness asks "should I get traffic right now?". Conflating them
causes restart storms during exactly the incident you least want them.

**The Jenkins controller cannot deploy.** It has no Docker and no deploy roles.
Compromise it and you get an orchestrator with no permissions. The **agent** holds
the rights, and the agent is disposable.

**No JSON keys anywhere.** Workload Identity means pods get short-lived,
auto-rotated GCP credentials from the metadata server. The only key that exists
is your local Terraform admin key — and `.gitignore` blocks `*.json` to keep it
out of Git.

---

## Where the constraints forced a compromise

Stated honestly, because knowing *why* the real tool exists is worth more than
pretending you don't need it.

| Constraint | What we did instead | What it actually costs |
|---|---|---|
| **No Helm / Kustomize** | `envsubst` + plain YAML + `deploy.sh` | No packaging, no dependency management, no `helm rollback`, no chart ecosystem. `deploy.sh` compensates with a rollout gate and auto-`rollout undo`. Honestly? envsubst covers most of what teams actually use Helm's values for. |
| **No Jenkins shared library** | Jenkinsfile duplicated ×10 | A pipeline change is a 10-repo change. This pain *is* the argument for a shared library — now you've felt it. |
| **No Argo Rollouts / Flagger** | `canary.sh` with plain kubectl | No automated traffic shifting, no proper metric analysis, no clean abort. The script does the closest safe thing: run canary pods, bake, query Prometheus, promote or delete. Real orgs use Argo Rollouts. |
| **No GitOps / Argo CD** | Jenkins pushes with `kubectl apply` | Cluster state can drift from Git and nothing notices. GitOps is the industry default now. |
| **Private Jenkins controller** | SCM polling every 2 min | Up to 2 min latency and constant polling load. Real fix: internal LB + VPN, or a self-hosted runner. |
| **2 nodes, 3 envs, 1 cluster** | Namespace isolation + quotas | Namespaces are a soft boundary. Prod should be its own cluster. Quotas stop dev starving prod, but a node failure hits all three. |

---

## Verify it works

```bash
kubectl get nodes                              # exactly 2
kubectl get pods -A | grep -E "dev|monitoring"
kubectl get networkpolicy -n dev               # default-deny present?

# End to end
kubectl port-forward -n dev svc/frontend 8080:8080
curl localhost:8080/api/home | jq

# Prove the NetworkPolicy actually denies
kubectl run probe -n dev --rm -it --image=curlimages/curl --restart=Never -- \
  curl -m 5 http://payment:8080/healthz    # should TIME OUT — recommendation
                                           # has no business calling payment
```

That last one is the test worth running. If it succeeds, your default-deny didn't
apply and every per-service NetworkPolicy in this repo is decoration.

---

## Reference

| Doc | What's in it |
|---|---|
| `platform-infrastructure/README.md` | Terraform, the 2-node trap, identity model, tooling hosts |
| `platform-ops/README.md` | Bootstrap order, SLO table, burn-rate maths, alert routing |
| `platform-ops/runbooks/*.md` | One per service. Linked from every page. |
| `svc-*/README.md` | API, local dev, deploy, the k8s decisions |
| `svc-payment/README-SECRETS.md` | Workload Identity, Secret Manager, rotation, gotchas |
