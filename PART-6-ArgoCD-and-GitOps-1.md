# Part 6 — Argo CD and GitOps

**Before you start:**
- Part 5 complete: services running, Ingress live, alerts firing, budget proven
- The zip includes `platform-gitops/` (the 13th repo) and a `Jenkinsfile.gitops` per service.

**By the end:** Jenkins holds **zero cluster credentials**, Git is the source of truth, drift self-heals, and rollback is `git revert`.

---

## Section A — What actually changes, and the problem it creates

### The shift

**Before (Part 5) — push:**
```
Jenkins ──[kubectl apply]──► cluster
```
Jenkins holds `roles/container.developer`. **Your CI system is a path into production.** Compromise the build agent, own the cluster.

**After — pull:**
```
Jenkins ──[git commit]──► platform-gitops ◄──[pull]── Argo CD ──► cluster
```
Jenkins writes YAML to a repo. Argo CD, inside the cluster, pulls it.

> **This is the single biggest security win of GitOps**, and it's the one people undersell. Compromise the build agent now and the attacker can push an image and write to a Git repo — both reviewable, both revertible. **They cannot touch the cluster.** We revoke `container.developer` in Section G.

### The problem this creates for us

Argo CD renders manifests four ways: **Helm**, **Kustomize**, **plain directory**, or a **config management plugin**.

Our manifests are `envsubst` templates. Helm and Kustomize are forbidden by the project constraints. So "plain directory" it is — except:

```bash
$ grep -o '\${[A-Z_]*}' svc-cart/k8s/base/deployment.yaml | sort -u | head -3
```
```
${CPU_REQUEST}
${IMAGE_URL}
${REPLICAS}
```

Argo CD applying these as a plain directory would set `image:` to the **literal string** `${IMAGE_URL}`, and `replicas: ${REPLICAS}` — which isn't even an integer. Every deploy breaks.

### Two ways out

| | **Rendered manifests** (chosen) | Config management plugin |
|---|---|---|
| Where envsubst runs | Jenkins, at CI time | Argo CD sidecar, at sync time |
| Repo holds | Final YAML | Templates + env files |
| A PR diff shows | `image: ...:dev-42` → `:dev-43` | `IMAGE_TAG` changed — effect unknown |
| Argo complexity | None | Custom sidecar image + plugin config |
| Debug a bad render | `git diff` | Read sidecar logs |
| Downside | Repo churn — every build commits | Repo stays DRY |

**We render.** The reviewable diff is the point: a human approving a prod change sees the actual YAML, not a variable whose effect they must evaluate in their head.

The churn is real and it's the accepted cost of this pattern. In exchange, `git log envs/prod/cart/` becomes a perfect audit trail of what ran in prod and when.

---

## Section B — Create the GitOps repo

### B1 — On GitHub (UI, per Part 1B)

1. **`+`** → **New repository**
2. **Name:** `platform-gitops`
3. **Private**, tick **Add a README**
4. **Create**

> **Only `main`.** No develop/staging branches — the *directory* is the environment here, not the branch. `envs/dev/`, `envs/staging/`, `envs/prod/`.

**Branch protection?** Not yet. Jenkins pushes to `main` on every build; requiring a PR would block your own pipeline. Real orgs solve this with a bot account allowed to bypass, or by having Jenkins open PRs. Worth knowing you're skipping it.

### B2 — Push the skeleton

```bash
$ cd ~/enterprise-platform
$ export OWNER="your-github-username-or-org"
$ git clone https://github.com/${OWNER}/platform-gitops.git
$ cd platform-gitops
$ cp -r ~/Downloads/enterprise-platform/platform-gitops/. .
$ ls
```

**Expected output:**
```
README.md  argocd  envs
```

Point everything at your org:

```bash
$ sed -i "s|YOUR_ORG|${OWNER}|g" argocd/projects.yaml argocd/applicationsets/*.yaml
$ grep -m1 repoURL argocd/applicationsets/dev.yaml
```

**Expected output:**
```
      repoURL: https://github.com/your-org/platform-gitops.git
```

```bash
$ git add . && git commit -m "feat: gitops repo structure" && git push origin main
```

---

## Section C — Install Argo CD

### Why
Argo CD's upstream install is a single plain-YAML manifest — no Helm needed, which suits our constraints.

```bash
$ kubectl apply -f ~/enterprise-platform/platform-ops/namespaces/namespaces.yaml
$ kubectl get ns argocd
```

**Expected output:**
```
NAME     STATUS   AGE
argocd   Active   3s
```

> **`argocd` runs at PSA `baseline`, not `restricted`** — its repo-server needs more than restricted permits. Same reason as `monitoring`. Your app namespaces stay `restricted`.

```bash
$ kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.3/manifests/install.yaml
$ kubectl rollout status deploy/argocd-server -n argocd --timeout=5m
$ kubectl get pods -n argocd
```

**Expected output:**
```
NAME                                 READY   STATUS    RESTARTS   AGE
argocd-application-controller-0      1/1     Running   0          2m
argocd-applicationset-controller-0   1/1     Running   0          2m
argocd-dex-server-7d9c5b8f4-x2k9p    1/1     Running   0          2m
argocd-notifications-controller-0    1/1     Running   0          2m
argocd-redis-6b8d7c9f5-m3n2q         1/1     Running   0          2m
argocd-repo-server-5f8c9d7b6-p4r5s   1/1     Running   0          2m
argocd-server-9e8f7a6b5-z1a2b        1/1     Running   0          2m
```

> **`argocd-applicationset-controller` must be running** — it's what turns our ApplicationSets into 30 Applications. On older Argo versions it's a separate install.
>
> **This adds ~1.5GB of memory to a 2-node cluster.** Watch for `Pending` pods; you may need to scale `dev` down while you work.

**Log in:**

```bash
$ kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d; echo
$ kubectl port-forward svc/argocd-server -n argocd 8090:443 &
```

Open **https://localhost:8090** (accept the cert warning), username `admin`.

**Install the CLI:**

```bash
$ curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
$ sudo install -m 555 argocd /usr/local/bin/argocd && rm argocd
$ argocd login localhost:8090 --username admin --insecure
$ argocd version --client --short
```

### C1 — Give Argo CD read access to the repo

```bash
$ argocd repo add https://github.com/${OWNER}/platform-gitops.git \
    --username ${OWNER} \
    --password $(cat ~/.secrets/github-pat.txt)
$ argocd repo list
```

**Expected output:**
```
TYPE  NAME  REPO                                                 INSECURE  OCI    LFS    CREDS  STATUS      MESSAGE
git         https://github.com/your-org/platform-gitops.git      false     false  false  true   Successful
```

**`Successful` means Argo can read the repo.** Read-only — Argo never writes. Jenkins writes.

---

## Section D — Projects and ApplicationSets

### Why
Without an AppProject, every Application lands in `default`, which permits **any repo to deploy any resource to any namespace**. That's not a boundary, it's a suggestion.

```bash
$ cd ~/enterprise-platform/platform-gitops
$ kubectl apply -f argocd/projects.yaml
$ argocd proj list
```

**Expected output:**
```
NAME     DESCRIPTION                     DESTINATIONS                     SOURCES
dev      Development environment         https://kubernetes.default.svc,dev   https://github.com/...
prod     Production. Manual sync only.   https://kubernetes.default.svc,prod  https://github.com/...
staging  Staging environment             https://kubernetes.default.svc,staging  https://github.com/...
```

**Each project can only deploy to its own namespace.** A misconfigured Application in `dev` cannot write to `prod` — Argo refuses.

```bash
$ argocd proj get prod
```

**Expected output** (abridged):
```
Destinations:       https://kubernetes.default.svc,prod
Allowed Namespaced Resources:  Service, ServiceAccount, ConfigMap, Deployment, HorizontalPodAutoscaler, PodDisruptionBudget, NetworkPolicy, BackendConfig
Sync Windows:       DENY 0 10 * * 1-5 8h (manual sync allowed)
```

> **Two guard rails worth noticing.** The whitelist means an Application can't create a `ClusterRole` or a `Secret` even if someone commits one. The sync window blocks automated syncing 10:00–18:00 on weekdays — but `manualSync: true` means a human can still deliberately ship. It's a guard rail, not a lock.

### Deploy the ApplicationSets

```bash
$ kubectl apply -f argocd/applicationsets/
$ kubectl get applicationset -n argocd
```

**Expected output:**
```
NAME                     AGE
dev-microservices        10s
prod-microservices       10s
staging-microservices    10s
```

```bash
$ argocd app list
```

**Expected output:**
```
NAME                       CLUSTER                         NAMESPACE  PROJECT  STATUS     HEALTH
argocd/dev-cart            https://kubernetes.default.svc  dev        dev      Unknown    Missing
argocd/dev-checkout        https://kubernetes.default.svc  dev        dev      Unknown    Missing
...
```

**Thirty Applications from three files.** The git generator scanned `envs/*/`, found the directories, and created one Application each. Nobody hand-wrote 30 manifests.

They're `Missing` because the directories are empty — no manifests yet. That's next.

---

## Section E — Jenkins renders and commits

### Why
This is the actual switch. Jenkins stops deploying.

### E1 — The new stages

```bash
$ cd ~/enterprise-platform/svc-cart
$ cp -r ~/Downloads/enterprise-platform/svc-cart/. .
$ grep -oP "stage\('\K[^']+" Jenkinsfile | nl
```

**Expected output:**
```
     1  Checkout
     2  Install
     3  Lint
     4  Unit tests
     5  SonarQube scan
     6  Quality gate
     7  Build image
     8  Trivy scan
     9  Push to Artifact Registry
    10  Render and commit manifests
    11  Production sync notice
```

**`Deploy to dev`, `Deploy to staging`, `Deploy to prod (canary)` and `Smoke test` are gone.**

**Prove Jenkins has no cluster access left:**

```bash
$ grep -l "kubectl\|get-credentials" svc-*/Jenkinsfile || echo "no kubectl, no get-credentials in any Jenkinsfile"
```

**Expected output:**
```
no kubectl, no get-credentials in any Jenkinsfile
```

**That's the security win, verified.**

### E2 — Swap in the GitOps Jenkinsfile

The zip ships **two** pipeline definitions per service:

| File | Used by |
|---|---|
| `Jenkinsfile` | Parts 3–5 — push-based, Jenkins runs `kubectl` |
| `Jenkinsfile.gitops` | **Part 6** — pull-based, Jenkins commits YAML |

Parts 1–5 are the default so they work as written. Part 6 is an opt-in swap you make deliberately — which is also how you'd do a real migration: visible and revertible, not a silently different starting point.

```bash
$ cd ~/enterprise-platform
$ export OWNER="your-github-username-or-org"

$ for svc in frontend product-catalog cart checkout order \
             payment shipping user-auth notification recommendation; do
    cd svc-$svc
    cp Jenkinsfile Jenkinsfile.push-based.bak   # keep the old one
    cp Jenkinsfile.gitops Jenkinsfile           # swap in GitOps
    sed -i "s|github.com/YOUR_ORG/platform-gitops.git|github.com/${OWNER}/platform-gitops.git|" Jenkinsfile
    cd ..
  done

$ grep GITOPS_REPO_URL svc-cart/Jenkinsfile
$ grep -l "kubectl" svc-*/Jenkinsfile || echo "no cluster access in any Jenkinsfile"
```

**Expected output:**
```
        GITOPS_REPO_URL = 'github.com/your-org/platform-gitops.git'
no cluster access in any Jenkinsfile
```

**That second line is the security win, verified.**

> **No credentials needed in Jenkins beyond what you already have.** `render-and-commit.sh` uses the existing `github-pat`. It needs **Contents: write** on `platform-gitops` — if you scoped your PAT to selected repos in Part 1B, add this repo now.

### E3 — Push and watch

```bash
$ cd svc-cart
$ git add . && git commit -m "feat: gitops delivery" && git push origin develop
```

Jenkins picks it up. The new stage:

```
[Pipeline] stage (Render and commit manifests)
==> Rendering cart for dev
==> Cloning GitOps repo
==> Diff being committed:
 envs/dev/cart/deployment.yaml    | 142 ++++++++++++++++
 envs/dev/cart/hpa.yaml           |  31 ++++
 envs/dev/cart/networkpolicy.yaml |  48 ++++++
 envs/dev/cart/pdb.yaml           |  12 ++
 envs/dev/cart/service.yaml       |  18 ++
 envs/dev/cart/serviceaccount.yaml|  11 ++
+      image: asia-south1-docker.pkg.dev/my-proj/dev-microservices/svc-cart:dev-12-9f2e1a8
==> Pushed to GitOps repo
==> Done. Argo CD will sync dev/cart within ~3 minutes.
Finished: SUCCESS
```

**Look at the diff line.** The commit shows the actual image change. That's what a reviewer sees.

**Check the repo:**

```bash
$ cd ~/enterprise-platform/platform-gitops && git pull -q
$ ls envs/dev/cart/
$ grep -E "^\s+(image|replicas):" envs/dev/cart/deployment.yaml
```

**Expected output:**
```
deployment.yaml  hpa.yaml  networkpolicy.yaml  pdb.yaml  service.yaml  serviceaccount.yaml
  replicas: 1
        image: asia-south1-docker.pkg.dev/my-proj/dev-microservices/svc-cart:dev-12-9f2e1a8
```

**Fully rendered.** No `${...}`, `replicas` is a real integer. Argo CD can apply this as a plain directory.

### E4 — Watch Argo CD pull

```bash
$ argocd app get dev-cart
```

**Expected output** (within ~3 min):
```
Name:               argocd/dev-cart
Project:            dev
Repo:               https://github.com/your-org/platform-gitops.git
Path:               envs/dev/cart
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME  STATUS  HEALTH
       Service     dev        cart  Synced  Healthy
apps   Deployment  dev        cart  Synced  Healthy
```

**`Synced` + `Healthy`.** Nobody ran kubectl.

> **~3 minutes?** Argo polls Git every 3 minutes by default. For instant sync you'd add a webhook — but your Argo is private, same problem as Jenkins in Part 3. Same trade-off, same honest answer.

Roll out the other nine the same way.

---

## Section F — Prove it: drift and rollback

### F1 — Drift self-heals

**This is the demo that makes GitOps click.**

```bash
$ kubectl scale deploy/cart -n dev --replicas=5
$ kubectl get deploy cart -n dev -o jsonpath='{.spec.replicas}{"\n"}'
```

**Expected output:**
```
5
```

Now wait ~30 seconds:

```bash
$ sleep 40 && kubectl get deploy cart -n dev -o jsonpath='{.spec.replicas}{"\n"}'
```

**Expected output:**
```
1
```

**Argo CD reverted you.** `selfHeal: true` means the cluster is continuously reconciled to Git. Your manual change lasted seconds.

```bash
$ argocd app history dev-cart | tail -2
```

> **This is what "Git is the source of truth" actually means.** Not a slogan — an enforcement mechanism. In Part 5, that `kubectl scale` would have silently persisted until the next deploy overwrote it, and nobody would know why prod had 5 replicas.
>
> **The flip side, honestly:** during an incident you cannot `kubectl scale` to buy time — Argo fights you. You either commit to Git, or `argocd app set dev-cart --sync-policy none` first. Real teams get bitten by this once.

### F2 — Prune

```bash
$ cd ~/enterprise-platform/platform-gitops
$ git rm -q envs/dev/cart/hpa.yaml && git commit -q -m "test: remove cart HPA" && git push -q origin main
$ sleep 200
$ kubectl get hpa cart -n dev
```

**Expected output:**
```
Error from server (NotFound): horizontalpodautoscalers.autoscaling "cart" not found
```

**Deleted from Git → deleted from the cluster.** That's `prune: true`. Without it, the HPA would linger forever, orphaned and invisible.

```bash
$ git revert --no-edit HEAD && git push -q origin main
```

### F3 — Rollback is `git revert`

Break something deliberately:

```bash
$ cd ~/enterprise-platform/platform-gitops
$ sed -i 's|image: .*svc-cart:.*|image: asia-south1-docker.pkg.dev/my-proj/dev-microservices/svc-cart:does-not-exist|' envs/dev/cart/deployment.yaml
$ git commit -aqm "break: bad image tag" && git push -q origin main
$ sleep 200
$ kubectl get pods -n dev -l app=cart
```

**Expected output:**
```
NAME                    READY   STATUS             RESTARTS   AGE
cart-6b9d7c8f4-m3n2q    1/1     Running            0          20m
cart-8f7e6d5c4-x9y8z    0/1     ImagePullBackOff   0          45s
```

**Note the old pod is still serving.** `maxUnavailable: 0` means the rollout never took down a healthy pod. The bad deploy is stuck, not live.

```bash
$ argocd app get dev-cart | grep Health
```

**Expected output:**
```
Health Status:      Degraded
```

**The rollback:**

```bash
$ git revert --no-edit HEAD && git push origin main
```

**That's it.** No kubectl, no Jenkins job, no `rollout undo`. Within ~3 minutes:

```bash
$ argocd app get dev-cart | grep -E "Health|Sync Status"
```

**Expected output:**
```
Sync Status:        Synced to main (7e8f9a0)
Health Status:      Healthy
```

> **Compare to Part 5.** There, rollback was `kubectl rollout undo` — which fixed the cluster but left Git *wrong*. The next deploy would have re-applied the broken version. Here, the fix and the record are the same action.

---

## Section G — Revoke Jenkins' cluster access

### Why
Jenkins hasn't used `container.developer` since Section E. An unused permission is a liability.

Open `platform-infrastructure/modules/iam/main.tf` and **delete this one line**:

```hcl
    "roles/container.developer",       # deploy to GKE, not admin it
```

Or do it in place:

```bash
$ cd ~/enterprise-platform/platform-infrastructure
$ sed -i '/roles\/container.developer/d' modules/iam/main.tf
$ sed -n '/jenkins_agent_roles/,/^  ]/p' modules/iam/main.tf
```

**Expected output** — three roles, none of them cluster access:
```hcl
  jenkins_agent_roles = [
    "roles/artifactregistry.writer",   # push images
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
```

```bash
$ cd environments/dev
$ terraform plan
```

**Expected output:**
```
Terraform will perform the following actions:

  # module.iam.google_project_iam_member.jenkins_agent["roles/container.developer"] will be destroyed

Plan: 0 to add, 0 to change, 1 to destroy.
```

**One permission destroyed.** That's the GitOps dividend, in a plan output.

```bash
$ terraform apply
```

**Verify:**

```bash
$ gcloud projects get-iam-policy $(gcloud config get-value project) \
    --flatten="bindings[].members" \
    --filter="bindings.members:dev-jenkins-agent@*" \
    --format="value(bindings.role)"
```

**Expected output:**
```
roles/artifactregistry.writer
roles/logging.logWriter
roles/monitoring.metricWriter
```

**No `container.developer`.** Your CI system can push an image and write to Git. It cannot touch the cluster.

> **The threat model, concretely.** Before: compromise the Jenkins agent → `kubectl` as `container.developer` → deploy anything to any namespace, silently.
>
> After: compromise the agent → push an image (visible in Artifact Registry) and commit to Git (visible in `git log`, revertible in one command). Both leave evidence. Neither reaches the cluster directly.

---

## Section H — Prod: the sync button is the gate

### Why
The Jenkins `input` step is gone. Argo CD replaces it — better.

PR `develop` → `staging` → `main` as in Part 5. When `main` merges:

```
[Pipeline] stage (Production sync notice)
    Manifests for PRODUCTION have been committed to GitOps.
    Argo CD will show prod-cart as OutOfSync.

    A human must review the diff and sync:
      argocd app diff prod-cart
      argocd app sync prod-cart
Finished: SUCCESS
```

**Jenkins is done.** Prod hasn't changed.

```bash
$ argocd app get prod-cart | grep -E "Sync Status|Sync Policy"
```

**Expected output:**
```
Sync Policy:        <none>
Sync Status:        OutOfSync from main (b2c3d4e)
```

**Review the actual diff:**

```bash
$ argocd app diff prod-cart
```

**Expected output:**
```
===== apps/Deployment prod/cart ======
23c23
<       image: asia-south1-docker.pkg.dev/my-proj/prod-microservices/svc-cart:prod-11-8e7d6c5
---
>       image: asia-south1-docker.pkg.dev/my-proj/prod-microservices/svc-cart:prod-12-9f2e1a8
```

> **This is strictly better than the Jenkins `input` step.** There, you approved a build number and trusted that the manifests were right. Here you see the exact YAML change before you approve it. If a bad env file doubled prod's replicas, you'd see it here — Jenkins' approval prompt would not have shown you.

```bash
$ argocd app sync prod-cart
```

**Expected output:**
```
Synced to main (b2c3d4e)
Health Status: Healthy
```

**Or click Sync in the UI.** That button is the gate.

---

## Section I — Checklist

- [ ] `ls platform-gitops/` exists in the zip
- [ ] `platform-gitops` repo created, skeleton pushed, `YOUR_ORG` replaced
- [ ] `argocd` namespace at PSA `baseline`
- [ ] All 7 Argo pods Running, **including `applicationset-controller`**
- [ ] `argocd repo list` → `Successful`
- [ ] 3 AppProjects; `argocd proj get prod` shows the resource whitelist + sync window
- [ ] `argocd app list` → **30 Applications** from 3 ApplicationSets
- [ ] `grep -l kubectl svc-*/Jenkinsfile` → **nothing**
- [ ] Pipeline commits rendered YAML; `envs/dev/cart/deployment.yaml` has a real image tag and `replicas: 1`
- [ ] `argocd app get dev-cart` → Synced + Healthy
- [ ] **`kubectl scale` to 5 → reverts to 1 within ~40s**
- [ ] `git rm` a manifest → resource pruned from the cluster
- [ ] Bad image → Degraded; `git revert` → Healthy
- [ ] `terraform plan` → **1 to destroy** (`container.developer`)
- [ ] Jenkins agent IAM: 3 roles, none of them cluster access
- [ ] `argocd app diff prod-cart` shows the real YAML change before sync

### The test that matters

**F1 — drift self-heals.** Scale to 5, watch it return to 1. If it stays at 5, `selfHeal` isn't on and Git isn't the source of truth — it's a suggestion, and you have Part 5 with extra steps.

---

## What GitOps cost us

Honest ledger:

| Gained | Lost |
|---|---|
| CI has zero cluster credentials | An extra repo and a moving part |
| Cluster state = Git, enforced | **Can't `kubectl` your way out of an incident** — Argo fights you |
| Rollback is `git revert` | Repo churn: every build commits |
| Full audit trail: `git log envs/prod/` | ~1.5GB memory on a 2-node cluster |
| Drift is impossible, not just discouraged | Prod sync is now two systems (Jenkins → Argo) |
| Prod approval shows real YAML | Argo polls every 3 min (private, so no webhook) |

**The incident one is the sharpest.** During an outage your instinct is `kubectl scale`. Argo will revert you in 30 seconds. Either commit to Git or `argocd app set <app> --sync-policy none` first. Every team learns this once, usually at 3am.

### Still open

| Gap | Why it matters |
|---|---|
| No Argo Rollouts | `canary.sh` is dead now — Argo owns the Deployment. Rollouts is the GitOps-native answer. |
| No image updater | Jenkins commits the tag. Argo CD Image Updater would watch the registry instead. |
| GitOps repo unprotected | Jenkins pushes to `main` directly. Real orgs use a bot with bypass, or have CI open PRs. |
| Argo CD self-managed? | It isn't managing itself yet. "App of apps" would put Argo's own config under GitOps. |
| Everything in-memory | Still no real database. This is the biggest *architectural* gap, not tooling. |

---

## Tear down

```bash
$ gcloud compute disks snapshot dev-jenkins-home --zone=asia-south1-a \
    --snapshot-names=jenkins-home-$(date +%Y%m%d)

# Finalizers will hang the delete if you skip this
$ kubectl delete applicationset --all -n argocd
$ kubectl delete app --all -n argocd
$ kubectl delete ingress frontend -n dev

$ cd ~/enterprise-platform/platform-infrastructure/environments/dev
$ terraform destroy
```

**Verify nothing lingers:**
```bash
$ gcloud compute instances list && gcloud container clusters list
$ gcloud compute forwarding-rules list && gcloud compute disks list
```

**Expected:** `Listed 0 items.` four times.

> **Delete the Applications before destroying.** `resources-finalizer.argocd.argoproj.io` blocks namespace deletion until Argo cleans up — and if the cluster is already gone, the finalizer can never complete and the delete hangs forever. You'd then be editing finalizers out by hand.
