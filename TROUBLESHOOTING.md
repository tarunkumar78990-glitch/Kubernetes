# Troubleshooting

Every error this build actually produces, with the fix. **Use this when stuck — don't read it front to back.**

Grouped by where you'll hit it.

---

## Quick index

| Error text you see | Jump to |
|---|---|
| `Invalid for_each argument` | [T1](#t1) |
| `Variables not allowed` / `Unsuitable value type` | [T2](#t2) |
| `Quota 'SSD_TOTAL_GB' exceeded` | [T3](#t3) |
| `Quota 'CPUS' exceeded` | [T4](#t4) |
| `NO_PUBKEY` / `repository is not signed` | [T5](#t5) |
| `Running with Java 17 ... minimum required (Java 21)` | [T6](#t6) |
| `Listening on port [8080]` but browser times out | [T7](#t7) |
| `Start request repeated too quickly` | [T8](#t8) |
| Quality gate hangs 5 min then fails | [T9](#t9) |
| `violates PodSecurity "restricted"` | [T10](#t10) |
| GKE Ingress returns 502 | [T11](#t11) |
| Grafana: "Datasource prometheus was not found" | [T12](#t12) |
| `unzip: command not found` | [T13](#t13) |
| Cluster has 6 nodes, not 2 | [T14](#t14) |

---

## Terraform

### T1 — `Invalid for_each argument` {#t1}

```
Error: Invalid for_each argument
  35: for_each = toset(var.writer_members)
The "for_each" set includes values derived from resource attributes that
cannot be determined until apply...
```

**Cause.** With `toset()`, the **set values become the instance keys**. Those strings contain an SA email that doesn't exist until apply. Terraform requires `for_each` **keys** at plan time; values may be unknown.

**Fix.** A map with static keys — exactly what the error recommends:

```hcl
for_each = var.writer_members       # not toset(var.writer_members)
type     = map(string)              # not list(string)

writer_members = {
  "jenkins-agent" = "serviceAccount:${module.iam.jenkins_agent_sa_email}"
}
```

**Bonus:** the address becomes `writers["jenkins-agent"]` instead of `writers["serviceAccount:dev-jenkins-agent@..."]`. Rotate the SA email later and the binding updates **in place** rather than destroy-and-recreate. Keying on a value that can change is a bug even when it plans cleanly.

*Fixed in the current zip.*

---

### T2 — `Variables not allowed` / `Unsuitable value type` {#t2}

```
Error: Unsuitable value type ... value must be known
  on modules/artifact-registry/variables.tf line 20, in variable "writer_members"
Error: Variables not allowed
  "jenkins-agent" = "serviceAccount:${module.iam.jenkins_agent_sa_email}"
```

**Cause.** A documentation example containing `${...}` inside a heredoc `description`. **Terraform interpolates `${}` inside heredocs** — the example became live code. Variable descriptions must be *constant*.

**Fix.** Plain constant description; example in a `#` comment where interpolation never happens.

```hcl
# Caller passes: writer_members = { "jenkins-agent" = "serviceAccount:<email>" }
variable "writer_members" {
  description = "Who can push images. Map of static key to IAM member string."
  type        = map(string)
  default     = {}
}
```

**The rule:** never put `${...}` in a heredoc description. Use `#`, or escape as `$${...}`.

> **False-positive trap:** `description = "Docker images for ${var.env}"` inside a **resource** is legal — resource attributes interpolate by design. Only `variable` and `output` descriptions must be constant.

*Fixed in the current zip.*

---

### T3 — `Quota 'SSD_TOTAL_GB' exceeded` {#t3}

```
Error waiting for instance to create: Quota 'SSD_TOTAL_GB' exceeded.
Limit: 250.0 in region asia-south1.
```

**Cause.** `pd-balanced` and `pd-ssd` both count against `SSD_TOTAL_GB`. The default profile asks for **720GB**.

**Fix.** `pd-standard` counts against `DISKS_TOTAL_GB` instead, which is far larger. **720 → 0.**

```bash
cd environments/dev
cp terraform.tfvars.free-trial terraform.tfvars   # sets disk_type = "pd-standard"
```

**Cost:** HDD-backed. Builds and SonarQube's Elasticsearch feel sluggish. Everything works, just slowly.

**Verify before applying:**
```bash
terraform show -json tfplan | grep -o '"type":"pd-[a-z]*"' | sort | uniq -c
```
Any `pd-balanced` means the tfvars didn't take.

---

### T4 — `Quota 'CPUS' exceeded` {#t4}

The default profile needs **~16 vCPU**; free trial typically gives 8.

**Free Trial accounts cannot request quota increases** — a documented trial limitation. Two real options:

**A. Use the free-trial profile** — fits in **6.75 vCPU**:

```bash
cp terraform.tfvars.free-trial terraform.tfvars
```

It works because E2 shared-core types consume **fractional** vCPU quota:

| Type | vCPU quota | RAM |
|---|---|---|
| e2-micro | 0.25 | 1GB |
| e2-small | 0.50 | 2GB |
| e2-medium | 1.00 | 4GB |
| e2-standard-2 | 2.00 | 8GB |

GKE nodes stay `e2-standard-2` (4.00 total) deliberately — `e2-medium` would save 2 vCPU but leave only ~5.8GB allocatable across the cluster, not enough for 10 services + Prometheus + Argo CD.

**B. Upgrade to a Paid billing account.** You **keep your remaining credit** and stay on Free Tier — you're only billed past the credit. Then request the increase. Upgrading is not a charge.

**Still blocked at 8 vCPU?** Comment out the `module "tooling"` block — that drops you to 4.00 vCPU. You lose Part 3, but keep Parts 4–6.

---

### T14 — Cluster has 6 nodes, not 2 {#t14}

**Cause.** `node_count` on a regional cluster is **per zone**. Three zones × 2 = 6 nodes, and triple the bill.

**Fix.** `node_locations` pins to a single zone, so `node_count = 2` means 2. Already in the GKE module — this is why the count check is a proof test.

```bash
kubectl get nodes --no-headers | wc -l   # must be 2
```

**Trade-off:** regional control plane (HA), single-zone nodes. A zone outage takes the workloads down. That's the price of exactly 2 nodes.

---

## Jenkins

### T5 — `NO_PUBKEY` / `repository is not signed` {#t5}

```
W: GPG error: https://pkg.jenkins.io/debian-stable binary/ Release:
The following signatures couldn't be verified: NO_PUBKEY 7198F4B714ABFC68
E: The repository ... is not signed.
Script "startup-script" failed with error: exit status 100
```

**Cause.** Jenkins rotated their Debian signing keys in Dec 2025 (LTS 2.541.1). `jenkins.io-2023.key` is dead.

**Fix on a running VM:**

```bash
gcloud compute ssh dev-jenkins-controller --zone=asia-south1-a --tunnel-through-iap --command="
sudo curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  -o /usr/share/keyrings/jenkins-keyring.asc
sudo apt-get update && sudo apt-get install -y jenkins
sudo systemctl restart jenkins
"
```

**Keys rotate ~every 3 years — expect this again around 2029.** Check <https://www.jenkins.io/blog/> for the current filename.

> **Why the startup script died silently:** it runs `set -euxo pipefail`. Any failed command kills everything after it, and the Jenkins install is near the end. Check with `sudo journalctl -u google-startup-scripts.service | tail -25`.

*Fixed in the current zip.*

---

### T6 — `Running with Java 17 ... minimum required (Java 21)` {#t6}

```
Running with Java 17 from /usr/lib/jvm/java-17-openjdk-amd64, which is
older than the minimum required version (Java 21).
Supported Java versions are: [21, 25]
```

**Cause.** Jenkins raised its Java floor to 21 in the same Dec 2025 wave as the key rotation.

**Fix — controller and agent both:**

```bash
for VM in dev-jenkins-controller dev-jenkins-agent-01; do
  gcloud compute ssh $VM --zone=asia-south1-a --tunnel-through-iap --command="
    sudo apt-get update -qq && sudo apt-get install -y openjdk-21-jdk
    sudo update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java
    sudo mkdir -p /etc/systemd/system/jenkins.service.d
    printf '[Service]\nEnvironment=\"JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64\"\n' \
      | sudo tee /etc/systemd/system/jenkins.service.d/java21.conf
    sudo systemctl daemon-reload
    sudo systemctl reset-failed jenkins 2>/dev/null || true
    sudo systemctl restart jenkins 2>/dev/null || true
    java -version 2>&1 | head -1
  "
done
```

**Don't skip the agent.** It runs Jenkins' remoting JAR; on Java 17 it fails to connect in Part 3 §C with a much less obvious error.

**Or just run `fix-tooling.sh`** — it does both VMs, both fixes.

*Fixed in the current zip.*

---

### T8 — `Start request repeated too quickly` {#t8}

systemd gives up after repeated failures. **`restart` then silently does nothing** — which looks like your fix failed.

```bash
sudo systemctl reset-failed jenkins
sudo systemctl restart jenkins
```

Always `reset-failed` before restarting a service that's been crash-looping.

---

## Access

### T7 — `Listening on port [8080]` but the browser times out {#t7}

Two independent causes. Check both.

**Cause A — the firewall.** IAP's range was open for port **22 only**. `start-iap-tunnel` to 8080 still reports success (the tunnel only needs SSH to establish), but the HTTP traffic inside is dropped at the VM's NIC. **It looks exactly like a hung server.**

```bash
gcloud compute firewall-rules describe dev-allow-iap-web \
  --project=YOUR_PROJECT --format="value(sourceRanges[],allowed[].ports)"
```

Expect `['35.235.240.0/20']  ['8080', '9000']`. If missing:

```bash
gcloud compute firewall-rules create dev-allow-iap-web \
  --network=dev-vpc --allow=tcp:8080,tcp:9000 \
  --source-ranges=35.235.240.0/20 \
  --target-tags=jenkins-controller,sonarqube \
  --project=YOUR_PROJECT
```

*Now in the VPC module — `terraform apply` creates it.*

**Cause B — you tunnelled from the wrong machine.**

> **A tunnel opens a port on whichever machine runs the command.**

Run it on a headless VM you SSH'd into, and Jenkins is reachable — *from that VM's loopback*. Your browser is a different computer. `curl localhost:8080` there succeeds; your browser never will.

**Fix — use Cloud Shell.** It's the one place with both gcloud and a way to show its localhost to your browser:

1. Console → **`>_`** icon
2. ```bash
   gcloud compute start-iap-tunnel dev-jenkins-controller 8080 \
     --local-host-port=localhost:8080 \
     --zone=asia-south1-a --project=YOUR_PROJECT
   ```
3. **eye icon** (Web Preview) → **Preview on port 8080**

Opens at a Google-issued `https://8080-cs-....cloudshell.dev` URL. **No IP typed anywhere.**

Rides HTTPS/443, so corporate networks don't block it. See Part 3 §A for all three methods.

---

### T13 — `unzip: command not found` {#t13}

Not part of this platform — a bare Ubuntu image gap on your own workstation VM.

```bash
sudo apt-get update && sudo apt-get install -y unzip
```

The Jenkins **agent** installs `unzip` correctly before using it for the SonarQube scanner CLI. That one was never broken.

---

## SonarQube

### T9 — Quality gate hangs 5 minutes then fails {#t9}

**Nearly always the webhook (Part 3 §D4).**

`waitForQualityGate` does **not** poll SonarQube. It **waits for SonarQube to call Jenkins back.** No webhook, no callback, no gate — just a 5-minute timeout with no useful error.

**Check:** SonarQube → **Administration → Configuration → Webhooks**. Must be:

```
http://<YOUR-JENKINS-PRIVATE-IP>:8080/sonarqube-webhook/
```

Three ways to get this wrong:

| Mistake | Result |
|---|---|
| No trailing slash | Silently fails |
| `localhost` instead of the private IP | Points at SonarQube's own box |
| The IP from the guide (`10.10.16.3`) instead of **yours** | Points at nothing |

**Your IPs won't match the guide's** — GCP assigns from the subnet pool in creation order:

```bash
terraform output jenkins_controller_ip
```

**Verify the two VMs can reach each other:**

```bash
gcloud compute ssh dev-sonarqube --zone=asia-south1-a --tunnel-through-iap \
  --command="curl -s -o /dev/null -w '%{http_code}\n' http://<JENKINS-IP>:8080/login"
```

`200` means the webhook will work. Fix this now, not when a build hangs.

**Also check:** the **SonarQube Scanner** plugin is installed (Part 3 §B2) — it's what provides `waitForQualityGate` at all. Missing it gives `No such DSL method`.

---

### SonarQube restart-loops on 4GB

Its documented floor, and Elasticsearch will be unhappy. Add swap:

```bash
gcloud compute ssh dev-sonarqube --zone=asia-south1-a --tunnel-through-iap --command="
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
cd /opt && sudo docker compose up -d
"
```

Horrifying in production. Fine for learning.

---

## Kubernetes

### T10 — `violates PodSecurity "restricted"` {#t10}

The namespace enforces PSA `restricted`. A bare `kubectl run` sets no securityContext, so the API server rejects the pod — often *after* a successful deploy, which is a confusing place to fail.

The smoke-test stage passes compliant `--overrides`. If you're writing your own:

```bash
--overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,
"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"x",
"image":"curlimages/curl:8.9.1","securityContext":{"allowPrivilegeEscalation":false,
"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}}]}}'
```

---

### T11 — GKE Ingress returns 502 {#t11}

**The single most common cause:** GKE health-checks `/` by default. Our frontend has no `/` route → 404 → every backend marked `UNHEALTHY` → 502 for everything.

```bash
kubectl describe ingress frontend -n dev | grep backends
```

`UNHEALTHY` confirms it. The `BackendConfig` points the check at `/readyz`:

```bash
kubectl get backendconfig -n dev
gcloud compute health-checks list --format="table(name,httpHealthCheck.requestPath)"
```

Must show `/readyz`. If it shows `/`, the annotation isn't attached — check the names match exactly between `service.yaml` and `backendconfig.yaml`.

> **A 502 during the first 5–10 minutes is normal.** The LB is still provisioning.

---

### T12 — "Datasource prometheus was not found" {#t12}

The dashboard JSON pins `uid: prometheus`. Without an explicit uid, Grafana assigns a random one.

```bash
kubectl get cm grafana-datasources -n monitoring -o jsonpath='{.data.datasources\.yaml}' | grep uid
```

Must print `uid: prometheus`.

---

### Prometheus won't start / `field 'record' not found`

The SLO rules are **plain rule groups**, not `PrometheusRule` CRDs — we run Prometheus directly, without the Operator, so the CRD form would never load.

```bash
grep -c "kind: PrometheusRule" platform-ops/slo/*.yaml   # must be 0 0 0
```

Also check indentation: each `- record:` must sit under a group's `rules:`. Wrong indentation makes each rule its own group — **valid YAML, complete nonsense**, and Prometheus's error won't tell you that.

---

## GitOps

### Argo CD reverts my `kubectl` changes

Working as designed. `selfHeal: true` means the cluster is continuously reconciled to Git.

**During an incident this will fight you.** Either commit to Git, or pause it first:

```bash
argocd app set dev-cart --sync-policy none
```

Every team learns this once, usually at 3am.

---

### `terraform destroy` hangs on the argocd namespace

`resources-finalizer.argocd.argoproj.io` blocks deletion until Argo cleans up — and if the cluster is already gone, the finalizer can never complete.

**Always delete Applications before destroying:**

```bash
kubectl delete applicationset --all -n argocd
kubectl delete app --all -n argocd
kubectl delete ingress frontend -n dev
terraform destroy
```

---

## After `terraform destroy` — still being billed

Two resource types aren't in Terraform state, so it doesn't know to delete them:

```bash
gcloud compute forwarding-rules list   # created by your Ingress
gcloud compute disks list              # created by Kubernetes PVCs
```

Both should say `Listed 0 items.` This is the classic way a "destroyed" environment keeps costing money.

---

## The pattern worth remembering

Seven bugs were found in this codebase during development. **Four of them parsed as valid YAML or HCL and were wrong anyway:**

- SLO rules indented so each `- record:` became a new group
- ApplicationSet `syncPolicy` at column 0 — dev/staging errored, **prod parsed fine and was silently wrong**
- `${}` in a heredoc description — valid HCL, executed as code
- `for_each` over apply-time values — valid HCL, unknowable at plan

**Parseable ≠ correct.** Validate the schema and the semantics, not the syntax. The ones that pass silently are the dangerous ones — nothing tells you.
