# Part 1 — Foundations & GCP Setup (Linux, beginner edition)

This version assumes **Ubuntu/Debian** (the `apt` commands). If you're on **RHEL/Fedora/CentOS**, use the `dnf` notes marked **[RHEL]**.

Every step shows the **command**, the **expected result**, and a **common errors** box. Do the sections in order. Don't skip the "verify" checks.

> **Convention:** `$` at the start of a line means "type this in your terminal" (don't type the `$`). Lines without `$` under "Expected output" are what you should roughly see back.

---

## Section A — Install your local tools

You'll install: `gcloud`, `kubectl`, `terraform`, `docker`, `git`, and `gh` (GitHub CLI).

### A0. Update your package list first

```bash
$ sudo apt-get update
$ sudo apt-get install -y apt-transport-https ca-certificates gnupg curl wget lsb-release
```

**[RHEL]** `sudo dnf install -y ca-certificates gnupg curl wget`

---

### A1. Install gcloud (Google Cloud CLI)

```bash
$ curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

$ echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list

$ sudo apt-get update && sudo apt-get install -y google-cloud-cli
```

Install the **GKE auth plugin** (kubectl needs this to talk to GKE — the #1 thing beginners forget):
```bash
$ sudo apt-get install -y google-cloud-cli-gke-gcloud-auth-plugin
```

**Verify:**
```bash
$ gcloud version
```
**Expected output** (versions will differ):
```
Google Cloud SDK 490.0.0
bq 2.1.9
core 2024.xx.xx
gcloud-crx-python 3.11
```

> **Common errors**
> - `curl: command not found` → run A0 first.
> - `NO_PUBKEY` / signature errors on `apt-get update` → the keyring step failed; re-run the first `curl ... gpg` line.
> **[RHEL]:** use the dnf repo instead:
> ```bash
> sudo tee /etc/yum.repos.d/google-cloud-sdk.repo << 'EOF'
> [google-cloud-cli]
> name=Google Cloud CLI
> baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
> enabled=1
> gpgcheck=1
> repo_gpgcheck=0
> gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
> EOF
> sudo dnf install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
> ```

---

### A2. Install kubectl

```bash
$ sudo apt-get install -y kubectl
```

**Verify:**
```bash
$ kubectl version --client
```
**Expected output:**
```
Client Version: v1.30.x
Kustomize Version: v5.x.x
```
(Ignore the "Kustomize Version" line — that's just bundled in kubectl; we are not using Kustomize.)

> **Common errors**
> - `Unable to locate package kubectl` → the Google Cloud apt repo from A1 isn't set up. Redo A1's `echo ... tee` line, then `sudo apt-get update`.

---

### A3. Install Terraform

```bash
$ wget -O- https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

$ echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list

$ sudo apt-get update && sudo apt-get install -y terraform
```

**Verify:**
```bash
$ terraform version
```
**Expected output:**
```
Terraform v1.9.x
on linux_amd64
```

> **Common errors**
> - `E: Unable to locate package terraform` → the `lsb_release -cs` returned a codename the repo doesn't have. Run `lsb_release -cs` — if it prints something unusual, replace it manually with `jammy` (Ubuntu 22.04) or `noble` (24.04) in the echo line.
> **[RHEL]:**
> ```bash
> sudo dnf install -y dnf-plugins-core
> sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
> sudo dnf install -y terraform
> ```

---

### A4. Install Docker Engine

```bash
$ sudo install -m 0755 -d /etc/apt/keyrings
$ curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
$ sudo chmod a+r /etc/apt/keyrings/docker.gpg

$ echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

$ sudo apt-get update
$ sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**Let your user run docker without `sudo`** (important — otherwise every docker command needs sudo):
```bash
$ sudo groupadd docker 2>/dev/null; sudo usermod -aG docker $USER
$ newgrp docker
```

**Verify:**
```bash
$ docker run hello-world
```
**Expected output** (near the top):
```
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

> **Common errors**
> - `permission denied while trying to connect to the Docker daemon socket` → you skipped the `usermod -aG docker` step, or you need to **log out and back in** (the `newgrp docker` only fixes the current shell).
> - `Cannot connect to the Docker daemon` → the service isn't running: `sudo systemctl enable --now docker`.
> **[RHEL]:** use `https://download.docker.com/linux/centos/docker-ce.repo` via `dnf config-manager`, then `sudo dnf install docker-ce ...` and `sudo systemctl enable --now docker`.

---

### A5. Install Git and the GitHub CLI (gh)

```bash
$ sudo apt-get install -y git
```

GitHub CLI (makes creating 11 repos painless):
```bash
$ wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
$ sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
$ echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
$ sudo apt-get update && sudo apt-get install -y gh
```

**Verify:**
```bash
$ git --version
$ gh --version
```
**Expected output:**
```
git version 2.4x.x
gh version 2.xx.x (2024-xx-xx)
```

---

### A6. Final tool check (all at once)

```bash
$ gcloud version && kubectl version --client && terraform version && docker version && git --version && gh --version
```
If every one prints a version and none says "command not found," Section A is done.

---

## Section B — Bootstrap your GCP project

### B1. Log in (you, the human — one time)

```bash
$ gcloud auth login
```
A browser opens. Sign in with the Google account that has billing. After it succeeds the terminal prints:
```
You are now logged in as [you@gmail.com].
```

> **Common errors**
> - Headless server with no browser? Use `gcloud auth login --no-launch-browser` and paste the code it gives you into a browser on any machine.

### B2. Set your variables (once — everything reuses these)

```bash
$ export PROJECT_ID="ent-microsvc-platform-01"     # MUST be globally unique — change it
$ export REGION="asia-south1"                        # Mumbai (closest to Bangalore)
$ export ZONE="asia-south1-a"
```

Find your billing account ID:
```bash
$ gcloud billing accounts list
```
**Expected output:**
```
ACCOUNT_ID            NAME                OPEN
XXXXXX-XXXXXX-XXXXXX  My Billing Account  True
```
Copy the `ACCOUNT_ID` and set it:
```bash
$ export BILLING_ACCOUNT_ID="XXXXXX-XXXXXX-XXXXXX"
```

> **Tip:** These `export`s vanish when you close the terminal. Keep this terminal open for all of Part 1, or paste them into a scratch file you re-source.

### B3. Create the project + link billing

```bash
$ gcloud projects create "$PROJECT_ID" --name="Enterprise Microservices Platform"
$ gcloud config set project "$PROJECT_ID"
$ gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"
```
**Verify:**
```bash
$ gcloud config get-value project
```
**Expected output:** your `PROJECT_ID`.

> **Common errors**
> - `The project ID ... is already in use` → someone worldwide took that ID. Pick a more unique one (add random digits) and redo B3.
> - `FAILED_PRECONDITION: Billing account ... is not open` → your billing account isn't active; fix it in the Cloud Console → Billing.

### B4. Enable all required APIs

```bash
$ gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    artifactregistry.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com \
    serviceusage.googleapis.com \
    secretmanager.googleapis.com \
    storage.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com
```
Takes 1–3 minutes. **Verify:**
```bash
$ gcloud services list --enabled --format="value(config.name)" | sort
```
**Expected output** includes `container.googleapis.com`, `artifactregistry.googleapis.com`, etc.

> **Common errors**
> - `PERMISSION_DENIED: ... serviceusage.services.enable` → billing isn't linked (redo B3) or your login lacks rights on the project.

---

## Section C — Terraform service account (programmatic auth)

### C1. Create the service account

```bash
$ export TF_SA_NAME="terraform-admin"
$ export TF_SA_EMAIL="${TF_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

$ gcloud iam service-accounts create "$TF_SA_NAME" \
    --display-name="Terraform Admin (programmatic)"
```
**Verify:**
```bash
$ gcloud iam service-accounts list
```
**Expected output** shows a row with `terraform-admin@...iam.gserviceaccount.com`.

### C2. Grant the roles Terraform needs

`roles/editor` does most things but **cannot manage IAM**, and Terraform must create service accounts + IAM bindings (for your services and Workload Identity). So we add IAM-admin roles explicitly.
```bash
$ for ROLE in \
    roles/editor \
    roles/resourcemanager.projectIamAdmin \
    roles/iam.serviceAccountAdmin \
    roles/container.admin \
    roles/artifactregistry.admin \
    roles/secretmanager.admin \
    roles/storage.admin
  do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${TF_SA_EMAIL}" \
      --role="$ROLE" --condition=None
  done
```
**Verify** the bindings exist:
```bash
$ gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:${TF_SA_EMAIL}" \
    --format="value(bindings.role)"
```
**Expected output:** the 7 roles above, one per line.

> **SRE honesty note:** this is a broad set to keep you unblocked while learning. In production you'd scope Terraform to least-privilege roles and ideally use Workload Identity Federation from CI instead of a downloaded key. I'll show the least-privilege path in Part 2.

### C3. Generate the JSON key

```bash
$ mkdir -p ~/.gcp-keys && chmod 700 ~/.gcp-keys
$ gcloud iam service-accounts keys create ~/.gcp-keys/terraform-admin-key.json \
    --iam-account="$TF_SA_EMAIL"
$ chmod 600 ~/.gcp-keys/terraform-admin-key.json
```
**Expected output:**
```
created key [....] of type [json] as [/home/you/.gcp-keys/terraform-admin-key.json] for [terraform-admin@...]
```

### C4. Point Terraform at the key (and make it stick)

```bash
$ export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.gcp-keys/terraform-admin-key.json"
$ echo 'export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.gcp-keys/terraform-admin-key.json"' >> ~/.bashrc
```
(Use `~/.zshrc` if you use zsh.)

### C5. Security rules (do not skip)

- **Never** commit the key. You'll add `*.json` and `.gcp-keys/` to every repo's `.gitignore`.
- `chmod 600` (done above) keeps it readable only by you.
- Treat it like a root password.

---

## Section D — Remote Terraform state bucket (GCS)

GCS handles **state locking automatically** — unlike AWS, there's no DynamoDB step.

### D1. Create the bucket

```bash
$ export TF_STATE_BUCKET="${PROJECT_ID}-tfstate"
$ gcloud storage buckets create "gs://${TF_STATE_BUCKET}" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access
```

### D2. Enable versioning (recover from bad state)

```bash
$ gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning
```
**Verify:**
```bash
$ gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" --format="value(versioning.enabled)"
```
**Expected output:** `True`

> **Common errors**
> - `HTTPError 409: ... bucket already exists` → bucket names are global; append random digits to `TF_STATE_BUCKET` and retry.

Write the bucket name down — Part 2's backend config uses it.

---

## Section E — Create your 11 GitHub repos

### E1. Authenticate gh

```bash
$ gh auth login
```
Choose: **GitHub.com** → **HTTPS** → **Login with a web browser**. Paste the one-time code shown. Success prints:
```
✓ Logged in as YOUR_USERNAME
```

### E2. Create all 11 repos at once

Replace `YOUR_GITHUB_USERNAME` first:
```bash
$ export GH_OWNER="YOUR_GITHUB_USERNAME"

$ for REPO in svc-frontend svc-product-catalog svc-cart svc-checkout \
    svc-payment svc-shipping svc-order svc-user-auth svc-notification \
    svc-recommendation platform-infrastructure
  do
    gh repo create "${GH_OWNER}/${REPO}" --private --add-readme
  done
```
**Expected output:** 11 lines like `✓ Created repository YOUR_USERNAME/svc-frontend on GitHub`.

**Verify:**
```bash
$ gh repo list "$GH_OWNER" --limit 20
```
You should see all 11.

### E3. Branch → environment mapping (know this now)

Each service repo will use:
```
develop  -> dev namespace
staging  -> staging namespace
main     -> prod namespace
```
We wire this in Part 5 (Jenkins) and add branch protection on `main` then.

---

## Section F — Clone everything into one workspace

```bash
$ mkdir -p ~/enterprise-platform && cd ~/enterprise-platform

$ for REPO in svc-frontend svc-product-catalog svc-cart svc-checkout \
    svc-payment svc-shipping svc-order svc-user-auth svc-notification \
    svc-recommendation platform-infrastructure
  do
    git clone "https://github.com/${GH_OWNER}/${REPO}.git"
  done
```
**Verify:**
```bash
$ ls ~/enterprise-platform
```
**Expected output:** all 11 directories.

---

## Section G — Final checklist + proof test

- [ ] `gcloud kubectl terraform docker git gh` all print versions
- [ ] `gke-gcloud-auth-plugin` installed (A1)
- [ ] `docker run hello-world` works without sudo
- [ ] Project created + billing linked (`gcloud config get-value project`)
- [ ] All APIs enabled
- [ ] `terraform-admin` SA exists with 7 roles (C2 verify)
- [ ] JSON key created, `GOOGLE_APPLICATION_CREDENTIALS` in `~/.bashrc`, `chmod 600`
- [ ] GCS state bucket created, versioning = True
- [ ] 11 repos created and cloned

### Proof your programmatic auth actually works

```bash
$ gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
$ gcloud projects describe "$PROJECT_ID" --format="value(projectId,lifecycleState)"
```
**Expected output:** `ent-microsvc-platform-01   ACTIVE`

Switch back to your human login for everyday gcloud use:
```bash
$ gcloud config set account YOUR_EMAIL@gmail.com
```

If that `projects describe` returned your project as ACTIVE **while authenticated as the service account**, your programmatic credentials are correct and Part 2 will run cleanly.

---

## Next: Part 2

Terraform module structure (`vpc`, `gke`, `artifact-registry`, `iam`, `workload-identity`), per-environment root configs wired to your GCS bucket, and the **2-node regional GKE cluster** on GCP.

Tell me when Part 1 is green — or paste any error and I'll debug it with you.
