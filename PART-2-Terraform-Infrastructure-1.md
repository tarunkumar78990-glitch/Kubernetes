# Part 2 — Terraform: Build the Infrastructure

**Before you start, you need:**
- Part 1 complete: gcloud, terraform, kubectl installed; project created; APIs enabled; `terraform-admin` SA key at `~/.gcp-keys/terraform-admin-key.json`; GCS state bucket created
- Part 1B complete: 11 repos exist on GitHub, cloned to `~/enterprise-platform`
- The generated project unzipped

**By the end of this part you'll have:** a running 2-node GKE cluster, an Artifact Registry, per-service identities, and four tooling VMs — all from code, all reproducible.

> **Cost reality:** this part creates a GKE cluster + 4 VMs. Roughly **₹15–20k/month if left running**. We build **dev only**. Section G shows you how to tear it down. Do that whenever you stop for the day.

---

## Section A — Get the code into your repo

### Why
The zip is a staging area. `platform-infrastructure/` is its own repo, and Terraform state is tied to it. Get it into Git before you apply anything — you want the "before" committed.

### Commands

```bash
$ export OWNER="your-github-username-or-org"
$ cd ~/Downloads
$ unzip -q enterprise-platform.zip
$ ls enterprise-platform/
```

**Expected output:**
```
platform-infrastructure  platform-ops  README.md  svc-cart  svc-checkout
svc-frontend  svc-notification  svc-order  svc-payment  svc-product-catalog
svc-recommendation  svc-shipping  svc-user-auth
```

Now copy the infrastructure code into the repo you cloned in Part 1B:

```bash
$ cd ~/enterprise-platform/platform-infrastructure
$ git branch --show-current
```

**Expected output:**
```
main
```

> If it says `develop`, that's fine too — for the infra repo we said `main` stays default. Use whichever branch you're on consistently.

```bash
$ cp -r ~/Downloads/enterprise-platform/platform-infrastructure/. .
$ ls
```

**Expected output:**
```
environments  modules  README.md
```

**Verify the `.gitignore` survived** — this is the one that keeps your key out of Git:

```bash
$ cat .gitignore | head -8
```

**Expected output:**
```
# Terraform
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
*.tfplan
crash.log
crash.*.log
```

### Common errors

| Symptom | Cause |
|---|---|
| `cp: cannot stat ...` | You unzipped somewhere else. Run `find ~ -name "platform-infrastructure" -type d 2>/dev/null` to find it. |
| `.gitignore` missing after copy | `cp -r src/. dst` copies hidden files; `cp -r src/* dst` does **not**. Note the `/.` |

---

## Section B — Point Terraform at your state bucket

### Why
Terraform state is the map between your code and the real resources. Local state on your laptop means: no teammate can apply, and a lost laptop means orphaned infrastructure you pay for and can't delete. Remote state in GCS fixes both.

**GCS locks state automatically** using object generation numbers. There's no DynamoDB table to create — that's an AWS-ism people carry over and then look for in vain.

### Commands

First, confirm your bucket name from Part 1:

```bash
$ gcloud storage buckets list --format="value(name)" | grep tfstate
```

**Expected output:** (yours will differ)
```
my-project-id-tfstate
```

> **No output?** You skipped Part 1 Section D. Create it now:
> ```bash
> $ export PROJECT_ID=$(gcloud config get-value project)
> $ gcloud storage buckets create gs://${PROJECT_ID}-tfstate \
>     --location=asia-south1 --uniform-bucket-level-access
> $ gcloud storage buckets update gs://${PROJECT_ID}-tfstate --versioning
> ```

Now set it once and use it everywhere:

```bash
$ export TFSTATE_BUCKET=$(gcloud storage buckets list --format="value(name)" | grep tfstate)
$ echo $TFSTATE_BUCKET
```

**Expected output:**
```
my-project-id-tfstate
```

Substitute it into all three backend files:

```bash
$ cd ~/enterprise-platform/platform-infrastructure
$ sed -i "s/REPLACE_WITH_YOUR_TFSTATE_BUCKET/${TFSTATE_BUCKET}/" \
    environments/dev/backend.tf \
    environments/staging/backend.tf \
    environments/prod/backend.tf

$ cat environments/dev/backend.tf
```

**Expected output:**
```hcl
terraform {
  backend "gcs" {
    bucket = "my-project-id-tfstate"
    prefix = "env/dev"
  }
}
```

Notice `prefix = "env/dev"`. Each environment writes to its own path in the same bucket, so **a mistake in dev cannot corrupt prod state**.

### Common errors

| Symptom | Cause |
|---|---|
| `sed: no input files` | `$TFSTATE_BUCKET` was empty. `echo $TFSTATE_BUCKET` first. |
| Bucket name still shows `REPLACE_...` | You ran `sed` from the wrong directory. |
| Later: `Error 403 storage.objects.list` | Your SA lacks `roles/storage.admin`. Re-check Part 1 Section C. |

---

## Section C — Fill in your variables

### Why
Two things Terraform can't guess: your project ID, and **your public IP**. The GKE control plane is IP-restricted — if your IP isn't on the list, `kubectl` will hang and you'll blame the cluster.

### Commands

```bash
$ cd ~/enterprise-platform/platform-infrastructure/environments/dev
$ cp terraform.tfvars.example terraform.tfvars
```

Find your public IP:

```bash
$ curl -s ifconfig.me
```

**Expected output:** (yours will differ)
```
49.207.183.42
```

Get your project ID:

```bash
$ gcloud config get-value project
```

**Expected output:**
```
my-project-id
```

Now edit:

```bash
$ nano terraform.tfvars
```

Make it look like this, with **your** values:

```hcl
project_id = "my-project-id"
region     = "asia-south1"
zone       = "asia-south1-a"

authorized_cidrs = [
  {
    cidr_block   = "49.207.183.42/32"
    display_name = "my-workstation"
  },
  {
    cidr_block   = "10.10.16.0/24"
    display_name = "tooling-subnet"
  },
]
```

Save with `Ctrl+O`, `Enter`, then `Ctrl+X`.

> **The `/32` matters.** `49.207.183.42` alone is invalid; `49.207.183.42/32` means "exactly this one IP."
>
> **Keep the tooling-subnet entry.** That's how the Jenkins agent reaches the control plane to deploy. Delete it and your pipeline fails at the deploy stage with a timeout.

**Verify it's gitignored:**

```bash
$ git status --short
```

**Expected output:**
```
?? README.md
?? environments/
?? modules/
```

`terraform.tfvars` must **not** appear. If it does, your `.gitignore` is wrong — stop and fix it before committing.

### Common errors

| Symptom | Cause |
|---|---|
| `terraform.tfvars` shows in `git status` | `.gitignore` missing or wrong. It contains your project details — don't commit it. |
| Later: `kubectl` times out | Your home IP changed (most ISPs rotate them). Re-run `curl -s ifconfig.me`, update, re-apply. |
| `Invalid value for "cidr_block"` | You forgot `/32`. |

---

## Section D — Authenticate programmatically

### Why
You asked for programmatic auth with a service-account key — that's how CI systems authenticate, and it's worth doing the way you'll actually meet it.

Terraform reads the `GOOGLE_APPLICATION_CREDENTIALS` environment variable. This is **Application Default Credentials**, and it's the same mechanism every GCP SDK uses.

### Commands

```bash
$ export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.gcp-keys/terraform-admin-key.json"
$ ls -l $GOOGLE_APPLICATION_CREDENTIALS
```

**Expected output:**
```
-rw------- 1 you you 2373 Jul 10 14:22 /home/you/.gcp-keys/terraform-admin-key.json
```

> **Check the permissions.** `-rw-------` (600) means only you can read it. If you see `-rw-r--r--`, fix it now:
> ```bash
> $ chmod 600 $GOOGLE_APPLICATION_CREDENTIALS
> ```

**Prove the key actually works** before Terraform tries to use it:

```bash
$ gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS
$ gcloud auth list
```

**Expected output:**
```
                   Credentialed Accounts
ACTIVE  ACCOUNT
*       terraform-admin@my-project-id.iam.gserviceaccount.com
        you@gmail.com

To set the active account, run:
    $ gcloud config set account `ACCOUNT`
```

The `*` should be on `terraform-admin@...`. That's your proof.

**Make it survive a new terminal:**

```bash
$ echo 'export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.gcp-keys/terraform-admin-key.json"' >> ~/.bashrc
```

> **Real enterprises don't do this.** They use Workload Identity Federation so no key file exists at all. You asked for the key-based flow, which is still common and worth understanding — but know that the key is the weakest link here. Anyone who gets that file becomes your Terraform admin. That's exactly why the *pods* in this platform use Workload Identity instead.

### Common errors

| Symptom | Cause |
|---|---|
| `No such file or directory` | Key not created, or in a different path. `find ~ -name "*.json" -path "*gcp*" 2>/dev/null` |
| `Invalid JWT Signature` | Key was revoked or the file is truncated. Generate a new one (Part 1 Section C). |
| Works now, fails tomorrow | You didn't add it to `~/.bashrc`. |

---

## Section E — Init, plan, apply

### Why
`init` downloads providers and connects to your backend. `plan` shows what will happen. `apply` does it. **Never skip plan.** It's a free dry run of an expensive, slow operation.

### E1 — Init

```bash
$ cd ~/enterprise-platform/platform-infrastructure/environments/dev
$ terraform init
```

**Expected output:** (abridged)
```
Initializing the backend...

Successfully configured the backend "gcs"! Terraform will automatically
use this backend unless the backend configuration changes.

Initializing modules...
- artifact_registry in ../../modules/artifact-registry
- gke in ../../modules/gke
- iam in ../../modules/iam
- tooling in ../../modules/tooling
- vpc in ../../modules/vpc
- workload_identity in ../../modules/workload-identity

Initializing provider plugins...
- Finding hashicorp/google versions matching "~> 5.40"...
- Installing hashicorp/google v5.44.0...

Terraform has been successfully initialized!
```

**The proof it worked:** all six modules listed, and "Successfully configured the backend".

**Verify formatting and validity:**

```bash
$ terraform fmt -recursive -check
$ terraform validate
```

**Expected output:**
```
Success! The configuration is valid.
```

> `terraform fmt -check` printing nothing means everything is formatted. If it lists files, run `terraform fmt -recursive` to fix them.

### E2 — Plan

```bash
$ terraform plan -out=tfplan
```

**Expected output:** (the last lines are what matter)
```
Plan: 68 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + artifact_registry_url  = (known after apply)
  + bastion_name           = "dev-bastion"
  + cluster_location       = "asia-south1"
  + cluster_name           = "dev-gke"
  ...

Saved the plan to: tfplan
```

**Read the number.** Around **65–70 resources** is right. If you see `0 to add`, something's wrong. If you see anything under `to destroy`, **stop** — on a first run that should be zero.

**Sanity-check the node count before you spend money:**

```bash
$ terraform plan -out=tfplan 2>/dev/null | grep -A2 "node_count"
```

**Expected output:**
```
      + node_count          = 2
```

**It must say 2.** This is the check worth doing. See the box below.

> ### ⚠️ The 2-node trap
>
> For a **regional** cluster, `node_count` on a node pool is **per zone**. A regional cluster spans 3 zones by default, so `node_count = 2` would silently give you **6 nodes** — and triple the bill.
>
> The `gke` module handles it:
> ```hcl
> location       = var.region              # regional control plane (HA)
> node_locations = ["${var.region}-a"]     # nodes in ONE zone only
> node_count     = 2                       # => 2 nodes total
> ```
>
> **What you keep:** an HA control plane, replicated across zones by Google.
> **What you give up:** your *nodes* are single-zone. A zone outage takes your workloads down.
>
> That's the honest cost of the 2-node requirement. There's also a `validation` block that rejects any value other than 2, so nobody quietly changes it later.

### E3 — Apply

```bash
$ terraform apply tfplan
```

**Expected output:** (this takes a while)
```
module.iam.google_service_account.gke_node: Creating...
module.vpc.google_compute_network.vpc: Creating...
module.vpc.google_compute_network.vpc: Still creating... [10s elapsed]
...
module.gke.google_container_cluster.primary: Still creating... [8m20s elapsed]
module.gke.google_container_cluster.primary: Creation complete after 8m34s
module.gke.google_container_node_pool.primary: Creating...
...
module.tooling.google_compute_instance.jenkins_controller: Creation complete after 42s

Apply complete! Resources: 68 added, 0 changed, 0 destroyed.

Outputs:

artifact_registry_url = "asia-south1-docker.pkg.dev/my-project-id/dev-microservices"
bastion_name = "dev-bastion"
cluster_location = "asia-south1"
cluster_name = "dev-gke"
jenkins_agent_ip = "10.10.16.4"
jenkins_controller_ip = "10.10.16.3"
kubectl_connect_command = "gcloud container clusters get-credentials dev-gke --region asia-south1 --project my-project-id"
sonarqube_ip = "10.10.16.5"
workload_identity_service_accounts = {
  "cart" = "dev-cart@my-project-id.iam.gserviceaccount.com"
  "checkout" = "dev-checkout@my-project-id.iam.gserviceaccount.com"
  ...
}
```

**Realistic timing: 12–18 minutes.** The GKE cluster alone is 8–12 of that. Go make chai — this is genuinely how long it takes, not a hang.

> **After `apply` returns, the VMs are NOT ready.** Their startup scripts (installing Java, Jenkins, Docker, SonarQube) run for another **5–10 minutes**. Jenkins won't answer yet. That's expected — we verify in Section F.

### Common errors

| Symptom | Cause |
|---|---|
| `Error 403: Required 'compute.networks.create' permission` | terraform-admin SA missing a role. Re-check Part 1 Section C — it needs 7 roles. |
| `Error 409: Already exists` | You created something by hand earlier. Either `terraform import` it, or delete it in the console and re-apply. |
| `Error: Backend configuration changed` | You edited `backend.tf` after init. Run `terraform init -reconfigure`. |
| `Error 400: Master version ... unsupported` | The REGULAR release channel moved on. Usually resolves by re-running apply. |
| Apply fails halfway | **Normal and safe.** Terraform is idempotent — fix the cause and re-run `terraform apply`. It picks up where it stopped. |
| `Quota 'CPUS' exceeded` | New GCP projects have low quotas. Request an increase in IAM & Admin → Quotas, or use `e2-standard-2` in `terraform.tfvars`. |

---

## Section F — Verify what you built

### Why
"Apply complete" means Terraform is happy. It doesn't mean the thing works. Verify each layer.

### F1 — The cluster, and the node count

```bash
$ terraform output -raw kubectl_connect_command
```

**Expected output:**
```
gcloud container clusters get-credentials dev-gke --region asia-south1 --project my-project-id
```

Run that command, then:

```bash
$ kubectl get nodes
```

**Expected output:**
```
NAME                                      STATUS   ROLES    AGE   VERSION
gke-dev-gke-dev-pool-a1b2c3d4-x7k2        Ready    <none>   4m    v1.30.3-gke.1969001
gke-dev-gke-dev-pool-a1b2c3d4-p9m4        Ready    <none>   4m    v1.30.3-gke.1969001
```

**Exactly two lines. Count them.** This is the whole point of the trap in Section E2.

```bash
$ kubectl get nodes --no-headers | wc -l
```

**Expected output:**
```
2
```

**Confirm they're in one zone** (the trade-off we accepted):

```bash
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.'topology\.kubernetes\.io/zone'
```

**Expected output:**
```
NAME                                 ZONE
gke-dev-gke-dev-pool-a1b2c3d4-x7k2   asia-south1-a
gke-dev-gke-dev-pool-a1b2c3d4-p9m4   asia-south1-a
```

Both in `asia-south1-a`. That's by design.

### F2 — Workload Identity is actually on

This is the difference between "configured" and "working":

```bash
$ kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' | tr ',' '\n' | grep -i metadata
```

**Expected output:**
```
"cloud.google.com/gke-metadata-server-enabled":"true"
```

If that's missing, Workload Identity won't work and every pod will silently get the *node's* identity instead. We test this properly in Part 4 when pods exist.

### F3 — Dataplane V2 (eBPF/Cilium)

This is what enforces your NetworkPolicies:

```bash
$ kubectl get pods -n kube-system | grep -i anetd
```

**Expected output:**
```
anetd-4k2mp    1/1     Running   0    5m
anetd-x9p3l    1/1     Running   0    5m
```

One per node. `anetd` is GKE's Cilium agent. **No output means NetworkPolicies won't be enforced** — and every policy in `platform-ops` becomes decoration.

### F4 — The four tooling VMs

```bash
$ gcloud compute instances list
```

**Expected output:**
```
NAME                    ZONE            MACHINE_TYPE    INTERNAL_IP  EXTERNAL_IP  STATUS
dev-bastion             asia-south1-a   e2-micro        10.10.16.2                RUNNING
dev-jenkins-agent-01    asia-south1-a   e2-standard-4   10.10.16.4                RUNNING
dev-jenkins-controller  asia-south1-a   e2-standard-2   10.10.16.3                RUNNING
dev-sonarqube           asia-south1-a   e2-standard-2   10.10.16.5                RUNNING
```

**The `EXTERNAL_IP` column is empty for all four.** That's the security model working — no public IPs anywhere. You reach them through IAP only.

### F5 — Get into the bastion

```bash
$ gcloud compute ssh dev-bastion --zone=asia-south1-a --tunnel-through-iap
```

**Expected output (first time):**
```
WARNING: The private SSH key file for gcloud does not exist.
WARNING: The public SSH key file for gcloud does not exist.
WARNING: You do not have an SSH key for gcloud.
WARNING: SSH keygen will be executed to generate a key.
Generating public/private rsa key pair.
Enter passphrase (empty for no passphrase):
```

Press Enter twice (or set a passphrase). Then:

```
you@dev-bastion:~$
```

**You're in.** That prompt is your proof that IAP + OS Login + the firewall rule all work together.

Check the startup script finished:

```bash
you@dev-bastion:~$ cat /var/log/startup-complete.log
```

**Expected output:**
```
bastion ready
```

Exit:
```bash
you@dev-bastion:~$ exit
```

### F6 — Are Jenkins and SonarQube up yet?

Give the startup scripts 5–10 minutes after apply, then:

```bash
$ gcloud compute ssh dev-jenkins-controller --zone=asia-south1-a --tunnel-through-iap \
    --command="sudo systemctl is-active jenkins"
```

**Expected output:**
```
active
```

**If you get `activating` or `inactive`**, the startup script is still running. Watch it:

```bash
$ gcloud compute ssh dev-jenkins-controller --zone=asia-south1-a --tunnel-through-iap \
    --command="sudo tail -20 /var/log/syslog | grep startup-script"
```

Confirm the controller **cannot** build — this is the security boundary, and it's worth seeing:

```bash
$ gcloud compute ssh dev-jenkins-controller --zone=asia-south1-a --tunnel-through-iap \
    --command="which docker || echo 'no docker — correct'"
```

**Expected output:**
```
no docker — correct
```

And that the agent **can**:

```bash
$ gcloud compute ssh dev-jenkins-agent-01 --zone=asia-south1-a --tunnel-through-iap \
    --command="docker --version && trivy --version | head -1 && sonar-scanner --version 2>&1 | grep -i version | head -1"
```

**Expected output:**
```
Docker version 27.1.2, build d01f264
Version: 0.54.1
INFO: SonarScanner 5.0.1.3006
```

SonarQube takes the longest (Elasticsearch is slow to start):

```bash
$ gcloud compute ssh dev-sonarqube --zone=asia-south1-a --tunnel-through-iap \
    --command="sudo docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

**Expected output:**
```
NAMES       STATUS
sonarqube   Up 6 minutes
sonar-db    Up 6 minutes
```

### F7 — Artifact Registry

```bash
$ terraform output -raw artifact_registry_url
```

**Expected output:**
```
asia-south1-docker.pkg.dev/my-project-id/dev-microservices
```

```bash
$ gcloud artifacts repositories list
```

**Expected output:**
```
REPOSITORY          FORMAT  MODE                 LOCATION       CREATE_TIME
dev-microservices   DOCKER  STANDARD_REPOSITORY  asia-south1    2026-07-15T09:14:22
```

### F8 — Per-service identities

```bash
$ terraform output workload_identity_service_accounts
```

**Expected output:**
```
{
  "cart" = "dev-cart@my-project-id.iam.gserviceaccount.com"
  "checkout" = "dev-checkout@my-project-id.iam.gserviceaccount.com"
  "frontend" = "dev-frontend@my-project-id.iam.gserviceaccount.com"
  "notification" = "dev-notification@my-project-id.iam.gserviceaccount.com"
  "order" = "dev-order@my-project-id.iam.gserviceaccount.com"
  "payment" = "dev-payment@my-project-id.iam.gserviceaccount.com"
  "product-catalog" = "dev-product-catalog@my-project-id.iam.gserviceaccount.com"
  "recommendation" = "dev-recommendation@my-project-id.iam.gserviceaccount.com"
  "shipping" = "dev-shipping@my-project-id.iam.gserviceaccount.com"
  "user-auth" = "dev-user-auth@my-project-id.iam.gserviceaccount.com"
}
```

**Ten service accounts, one per microservice.** The `serviceaccount.yaml` in each service repo already references these by the exact pattern `${ENVIRONMENT}-<name>@${PROJECT_ID}...` — which is why they match without you editing anything.

**Prove least privilege is real** — the Jenkins *controller* must not be able to deploy:

```bash
$ gcloud projects get-iam-policy $(gcloud config get-value project) \
    --flatten="bindings[].members" \
    --filter="bindings.members:dev-jenkins-controller@*" \
    --format="value(bindings.role)"
```

**Expected output:**
```
roles/logging.logWriter
roles/monitoring.metricWriter
```

**Two roles. That's it.** No `container.developer`, no `artifactregistry.writer`. Compromise the controller and the attacker gets an orchestrator that can write logs. Compare the agent:

```bash
$ gcloud projects get-iam-policy $(gcloud config get-value project) \
    --flatten="bindings[].members" \
    --filter="bindings.members:dev-jenkins-agent@*" \
    --format="value(bindings.role)"
```

**Expected output:**
```
roles/artifactregistry.writer
roles/container.developer
roles/logging.logWriter
roles/monitoring.metricWriter
```

The agent holds the power — and the agent is the disposable one.

---

## Section G — Commit, and tear down

### G1 — Commit your work

```bash
$ cd ~/enterprise-platform/platform-infrastructure
$ git status --short
```

**Expected output:**
```
?? README.md
?? environments/
?? modules/
```

**`terraform.tfvars` must not be listed. Nor `.terraform/`, nor `tfplan`.** Check before every commit — this is the habit that keeps keys out of Git.

```bash
$ git add .
$ git commit -m "feat: terraform infrastructure for dev/staging/prod"
$ git push -u origin main
```

**Expected output:**
```
Enumerating objects: 48, done.
...
To https://github.com/your-org/platform-infrastructure.git
 * [new branch]      main -> main
```

**Final safety check** — make sure nothing sensitive got in:

```bash
$ git log --all --full-history -- "*.json" "*.tfvars" | head
```

**Expected output:** (nothing)

If that prints commits, you committed a key. Rotate it immediately — deleting the file isn't enough, Git keeps history.

### G2 — Destroy when you're done for the day

### Why
An idle dev cluster costs the same as a busy one. Terraform makes rebuilding it a 15-minute command, so there's no reason to leave it running overnight.

```bash
$ cd ~/enterprise-platform/platform-infrastructure/environments/dev
$ terraform destroy
```

**Expected output:**
```
Plan: 0 to add, 0 to change, 68 to destroy.

Do you really want to destroy all resources?
  Terraform will destroy all your managed infrastructure, as shown above.
  There is no undo. Only 'yes' will be accepted to confirm.

  Enter a value:
```

Type `yes`. Takes 8–12 minutes.

**Verify nothing is left billing you:**

```bash
$ gcloud compute instances list
$ gcloud container clusters list
```

**Expected output:**
```
Listed 0 items.
Listed 0 items.
```

Rebuild tomorrow with `terraform apply`. That's the whole point of infrastructure as code.

> **On prod:** the cluster has `deletion_protection = true`. `terraform destroy` will refuse. That's intentional — you must consciously set it to `false` and apply before prod can be destroyed. A guard rail, not a bug.

### Common errors

| Symptom | Cause |
|---|---|
| Destroy hangs on the VPC | Something outside Terraform is using it (a manually-created LB or forwarding rule). Delete it in the console. |
| `Error: Cannot destroy cluster: deletion_protection` | Working as designed on prod. Set it false → apply → destroy. |
| Destroy leaves orphaned disks | PVCs created *by Kubernetes* aren't in Terraform state. `gcloud compute disks list` and delete manually. |

---

## Section H — Checklist

- [ ] Infra code copied into the `platform-infrastructure` repo
- [ ] `backend.tf` points at your real state bucket, all three envs
- [ ] `terraform.tfvars` has your project ID and **current** public IP with `/32`
- [ ] `GOOGLE_APPLICATION_CREDENTIALS` exported and in `~/.bashrc`
- [ ] `terraform validate` → "Success!"
- [ ] `terraform plan` shows ~68 to add, **0 to destroy**
- [ ] `terraform apply` → "Apply complete!"
- [ ] `kubectl get nodes --no-headers | wc -l` → **exactly 2**
- [ ] Both nodes in `asia-south1-a`
- [ ] `anetd` pods running (Dataplane V2 enforcing policies)
- [ ] All 4 VMs `RUNNING` with **empty** EXTERNAL_IP
- [ ] IAP SSH into the bastion works
- [ ] Jenkins controller has **no** Docker; agent has Docker + Trivy + sonar-scanner
- [ ] 10 Workload Identity SAs in the output
- [ ] Jenkins controller has exactly 2 IAM roles
- [ ] `git status` does **not** show `terraform.tfvars`
- [ ] Code pushed to GitHub

### Proof test — state is genuinely remote

The real test of the backend isn't that `apply` worked. It's that state survives your machine:

```bash
$ rm -rf .terraform
$ terraform init
$ terraform plan
```

**Expected output:**
```
No changes. Your infrastructure matches the configuration.
```

You deleted your local Terraform directory and it still knows about all 68 resources — because state lives in GCS, not on your laptop. **That's the proof.**

If instead it says `Plan: 68 to add`, your backend isn't configured and Terraform thinks nothing exists. Go back to Section B before you do anything else — applying now would create a duplicate set of everything.

---

## Next: Part 3 — Jenkins and SonarQube

The VMs are running but empty. Part 3 covers: unlocking Jenkins through the IAP tunnel, plugins, connecting the static agent over SSH, the credentials store, SonarQube's quality gate, and wiring the two together so a failing gate actually blocks a build.
