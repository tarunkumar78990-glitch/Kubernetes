# Part 0 — Start Here

**What this is:** a production-shaped microservices platform on GCP, built by hand so you understand every layer. 10 services, 14 repos, real CI/CD, real SLOs, real GitOps.

**Time:** ~20 hours across 7 guides. **Cost:** see below — this matters.

---

## Read in this order

| # | Guide | You build | Time |
|---|---|---|---|
| **1** | `PART-1-Foundations-Linux-Detailed.md` | Ubuntu tooling, GCP project, terraform-admin SA, state bucket | 1–2h |
| **1B** | `PART-1B-GitHub-Setup-via-UI.md` | 11 repos, branches, branch protection, PAT — all browser | 1h |
| **2** | `PART-2-Terraform-Infrastructure.md` | VPC, **2-node GKE**, IAM, Artifact Registry, 4 tooling VMs | 2–3h |
| **3** | `PART-3-Jenkins-and-SonarQube.md` | Jenkins + agent + SonarQube, quality gate that **blocks** | 3–4h |
| **4** | `PART-4-Deploy-to-Kubernetes.md` | Bootstrap, secrets, Workload Identity, 10 services live | 3–4h |
| **5** | `PART-5-Production-and-Alerting.md` | Ingress, alerts, dashboards, prod gates, break something on purpose | 3–4h |
| **6** | `PART-6-ArgoCD-and-GitOps.md` | Argo CD; Jenkins loses all cluster access | 2–3h |

**Also:**
- `TROUBLESHOOTING.md` — every error this build actually hits, with fixes. **Read it when stuck, not before.**
- `enterprise-platform.zip` — the code. 14 repos, 403 files.
- `setup-dev.sh` — optional one-shot automation for Part 2
- `fix-tooling.sh` — repairs the tooling VMs if Jenkins won't start

> **Parts 1–5 are a complete, working platform.** Part 6 is a genuine architectural upgrade, not a bonus — but you can stop at 5 and have something real.

---

## Before Part 1

### Replace these six placeholders

Nothing runs until they're your values.

| Placeholder | Files | Covered in |
|---|---|---|
| `YOUR_ORG` | 16 | 1B, 5 §B3, 6 §B2 |
| `REPLACE_WITH_YOUR_TFSTATE_BUCKET` | 4 | 2 §B |
| `REPLACE_WITH_SLACK_WEBHOOK` | 2 | 5 §B2 |
| `REPLACE_WITH_PAGERDUTY_ROUTING_KEY` | 2 | 5 §B2 |
| `CHANGE_ME_IN_SECRET_MANAGER` | 1 | SonarQube's Postgres password |
| `yourdomain.com` | 1 | 5 §A (HTTPS — optional) |

```bash
grep -rl "YOUR_ORG\|REPLACE_WITH\|CHANGE_ME" ~/enterprise-platform | sort
```

### Check your quota

The default profile needs **~16 vCPU and 720GB SSD**. A free-trial project gives you 8 vCPU / 250GB and **cannot request an increase** — that's a documented trial limitation, not a bug.

```bash
gcloud compute regions describe asia-south1 \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep -E "CPUS|SSD_TOTAL|DISKS_TOTAL"
```

**On a free trial**, use the included profile — it fits in **6.75 vCPU / 0 SSD**:

```bash
cd environments/dev
cp terraform.tfvars.free-trial terraform.tfvars
# fill in project_id and your IP
```

The trick is one line: `disk_type = "pd-standard"`. `pd-balanced` counts against `SSD_TOTAL_GB`; `pd-standard` counts against `DISKS_TOTAL_GB`, which is far larger. 720GB → 0.

---

## Cost — read this one

Three environments = **three GKE clusters + twelve VMs ≈ ₹40–60k/month.**

**Build `dev` only.** Every part ends with the same instruction and it isn't decoration:

```bash
cd ~/enterprise-platform/platform-infrastructure/environments/dev
terraform destroy
```

**Snapshot Jenkins first** or you'll redo Part 3 tomorrow:

```bash
gcloud compute disks snapshot dev-jenkins-home --zone=asia-south1-a \
  --snapshot-names=jenkins-home-$(date +%Y%m%d)
```

**After destroy, check these two** — they're not in Terraform state, so it doesn't know to delete them:

```bash
gcloud compute forwarding-rules list   # created by your Ingress
gcloud compute disks list              # created by Kubernetes PVCs
```

This is the classic way a "destroyed" environment keeps billing you.

---

## The tests that actually matter

Everything else is comfort. These seven prove the system is real:

| Test | Where | Pass means |
|---|---|---|
| Push to `main` is **rejected** | 1B §E10 | Branch protection is live |
| `kubectl get nodes` = **exactly 2** | 2 §F1 | You dodged the per-zone `node_count` trap |
| Quality gate **fails a build on purpose** | 3 §H2 | Sonar blocks, not just reports |
| WI test prints `dev-payment@...`, not the node SA | 4 §C | Per-service identity is real |
| **`recommendation → payment` times out** | 4 §F2 | Default-deny works — otherwise every NetworkPolicy is decoration |
| Break catalog → burn-rate alert fires | 5 §F | Your SLOs aren't a hypothesis |
| `kubectl scale` to 5 → reverts to 1 | 6 §F1 | Git is the source of truth, enforced |

---

## Known gaps — architecture, not wiring

Each is a stated trade-off, not an oversight. Being able to say **why the real tool exists** is worth more than pretending you don't need it.

| Gap | Why it matters |
|---|---|
| **Everything is in-memory** | The biggest one. Restart a pod, lose the carts. Cloud SQL changes the whole reliability story. |
| **No Argo Rollouts** | After Part 6, `canary.sh` is dead — Argo owns the Deployment. Rollouts is the GitOps-native answer. |
| **No distributed tracing** | When checkout is slow across six services, metrics won't tell you which one. |
| **Prod shares a cluster** | Namespaces are a soft boundary. Prod should be its own cluster and project. |
| **Nodes are single-zone** | HA control plane, but a zone outage takes the workloads down. The cost of "exactly 2 nodes". |
| **GitOps repo unprotected** | Jenkins pushes to `main` directly. Real orgs use a bot with bypass, or have CI open PRs. |

### The constraints, and what they cost

| Constraint | What it cost |
|---|---|
| No Helm/Kustomize | No packaging, no `helm rollback`. `envsubst` covers most of what teams use Helm values for. |
| No shared library | Jenkinsfile ×10. A pipeline change is a 10-repo change. **That pain is the argument for a shared library** — you'll feel it. |
| No Argo Rollouts | `canary.sh` splits by replica count, analyses once. |
| Private Jenkins | SCM polling, 2-min latency. Fine at 10 repos, breaks at 200. |
| 2 nodes, 3 envs, 1 cluster | Namespaces are a soft boundary. |

---

## Versions that will rot

Pinned deliberately — reproducible builds beat "latest" — but they age.

| Pin | Where | Expect trouble |
|---|---|---|
| `jenkins.io-2026.key` | controller startup | ~2029 (keys rotate ~3yrs) |
| `openjdk-21` | controller + agent | When Jenkins raises its floor again |
| `SONAR_SCANNER_VERSION=5.0.1.3006` | agent startup | When SonarQube rejects old clients |
| `sonarqube:10-community`, `postgres:15` | sonarqube startup | Support windows |
| Node 20 (`setup_20.x`) | agent startup | EOL |

When Jenkins breaks after a long gap, it's almost always one of the first two. See `TROUBLESHOOTING.md`.
