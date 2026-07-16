# platform-infrastructure

All GCP infrastructure for the platform. Terraform, modules, three environments.

---

## What it builds

| Module | What you get |
|---|---|
| `vpc` | Custom VPC, GKE subnet with secondary ranges, tooling subnet, Cloud NAT, firewall (IAP-only SSH) |
| `iam` | One service account per host and per role. Least privilege. No `roles/editor`. |
| `gke` | Regional control plane, **exactly 2 nodes**, private, Workload Identity, Dataplane V2 |
| `artifact-registry` | Docker repo, immutable tags on prod, cleanup policies |
| `workload-identity` | A GSA per microservice + the KSA impersonation binding |
| `tooling` | 4 VMs: bastion, Jenkins controller, Jenkins agent, SonarQube |

```
environments/dev|staging|prod/   <- root configs, one per environment
modules/                         <- reusable, no hardcoded env
```

---

## First run

```bash
cd environments/dev

# 1. Point the backend at YOUR state bucket (created in Part 1 Section D)
#    Edit backend.tf and replace REPLACE_WITH_YOUR_TFSTATE_BUCKET
vim backend.tf

# 2. Fill in your project and your public IP
cp terraform.tfvars.example terraform.tfvars
curl -s ifconfig.me   # <- put this in authorized_cidrs
vim terraform.tfvars

# 3. Programmatic auth, as required — the SA key from Part 1
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.gcp-keys/terraform-admin-key.json"

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**Expected:** roughly 60–70 resources. The GKE cluster alone takes 8–12 minutes.
The tooling VMs' startup scripts run for another 5–10 minutes after `apply`
returns, so Jenkins won't answer immediately.

**Then connect:**
```bash
terraform output kubectl_connect_command   # copy and run it
kubectl get nodes                          # must show exactly 2
```

---

## Why "exactly 2 nodes" needs care

For a **regional** cluster, `node_count` on a node pool is **per zone**. A
regional cluster spans 3 zones by default, so `node_count = 2` would give you
**6 nodes** and a surprising bill.

The `gke` module pins `node_locations` to a single zone:

```hcl
location       = var.region        # regional control plane (HA)
node_locations = ["${var.region}-a"]  # nodes in ONE zone
node_count     = 2                 # => 2 nodes total
```

You keep the HA control plane; you get the 2 nodes you asked for. The honest
cost: your **nodes** are single-zone, so a zone outage takes the workloads down.
That is the trade-off the 2-node requirement forces, and it is worth saying out
loud rather than pretending otherwise.

There is also a `validation` block on `node_count` that rejects anything but 2,
so nobody quietly changes it later.

---

## Identity model

Nothing shares an identity. This is the part most learning projects skip.

| Identity | Can do | Explicitly cannot |
|---|---|---|
| `gke-node` | Write logs/metrics, **pull** images | Push images, deploy |
| `jenkins-controller` | Write logs/metrics | **Build, push, or deploy anything** |
| `jenkins-agent` | `container.developer`, **push** images | Admin the cluster |
| `sonarqube` | Write logs/metrics | Touch the cluster |
| `bastion` | Write logs/metrics | Anything else |
| per-service GSAs | Only what that service needs | Everything else |

The Jenkins controller deliberately cannot deploy. If it's compromised, the
attacker gets an orchestrator with no permissions. The **agent** holds the
deploy rights, and the agent is rebuildable.

---

## The four tooling hosts

Per the "different hosts" requirement, and matching how real orgs separate these:

| Host | Size | Public IP | Why separate |
|---|---|---|---|
| `bastion` | e2-micro | No | The only door. Reached via IAP tunnel only. |
| `jenkins-controller` | e2-standard-2 | No | Holds credentials. **No Docker installed**, so it cannot build. |
| `jenkins-agent-01` | e2-standard-4 | No | Untrusted code runs here. Disposable by design. |
| `sonarqube` | e2-standard-2 | No | Stateful (Postgres + Elasticsearch), own disk, own lifecycle. |

**None have public IPs.** Egress via Cloud NAT, ingress via IAP:

```bash
gcloud compute ssh dev-bastion --zone=asia-south1-a --tunnel-through-iap
```

Jenkins home and Sonar data live on **separate persistent disks**, so you can
delete and rebuild either VM without losing state.

---

## Per-environment isolation

Each environment is a separate root config with separate state:

```
gs://your-bucket/env/dev/default.tfstate
gs://your-bucket/env/staging/default.tfstate
gs://your-bucket/env/prod/default.tfstate
```

A mistake in dev cannot touch prod state. CIDRs don't overlap either:

| Env | Nodes | Pods | Services | Control plane |
|---|---|---|---|---|
| dev | 10.10.0.0/20 | 10.11.0.0/16 | 10.12.0.0/20 | 172.16.0.0/28 |
| staging | 10.20.0.0/20 | 10.21.0.0/16 | 10.22.0.0/20 | 172.16.1.0/28 |
| prod | 10.30.0.0/20 | 10.31.0.0/16 | 10.32.0.0/20 | 172.16.2.0/28 |

> **Cost warning:** three environments = three GKE clusters = three sets of 4
> VMs. That is real money. **Build `dev` first.** Only apply staging/prod when
> you actually need them, and `terraform destroy` when you stop working.
>
> Note `prod` has `deletion_protection = true` on the cluster — you must set it
> false and apply before a destroy will work. That is intentional.

---

## State locking

GCS handles locking natively via object generation numbers. There is **no
DynamoDB equivalent to configure** — that's an AWS-ism. Versioning on the bucket
(enabled in Part 1) is your undo button.

---

## Common errors

| Error | Cause |
|---|---|
| `Error 403: Required 'compute.networks.create'` | Your terraform-admin SA is missing a role. Re-check Part 1 Section C. |
| `googleapi: Error 409: Already exists` | Something was created by hand. Either `terraform import` it or delete it. |
| `Error: Backend configuration changed` | You edited `backend.tf` after init. Run `terraform init -reconfigure`. |
| Cluster creates but `kubectl` times out | Your IP isn't in `authorized_cidrs`. Re-run `curl -s ifconfig.me` — home IPs change. |
| `deletion_protection` blocks destroy on prod | Working as designed. Set it false, apply, then destroy. |
