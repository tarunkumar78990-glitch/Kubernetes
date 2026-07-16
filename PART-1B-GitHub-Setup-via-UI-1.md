# Part 1B — GitHub Setup via the Web UI (replaces Section E)

**This replaces the `gh` CLI section.** Everything here is done by clicking in a browser at https://github.com. Nothing in this file needs the GitHub CLI.

By the end you'll have:

- 11 repositories (10 services + 1 infrastructure)
- Three branches per service repo (`develop`, `staging`, `main`)
- Branch protection on `main` and `staging` (the enterprise gate)
- A `.gitignore` protecting your GCP key
- A Personal Access Token so your Linux box and Jenkins can talk to GitHub
- Webhooks ready for Jenkins (configured fully in Part 5)

> **Screen note:** GitHub changes its UI wording occasionally. Where a button name might have shifted, I describe *where* it lives so you can find it regardless.

---

## Section E1 — Create your GitHub account / organisation

### If you're using a personal account
Nothing to do — skip to E2. Your repos will live at `github.com/YOUR_USERNAME/repo-name`.

### If you want the realistic enterprise shape (recommended)
Real companies own repos in an **organisation**, not a personal account. It's free and it makes teams, permissions, and rulesets available — which is what you actually want to practise.

1. Click your **profile photo** (top-right) → **Your organizations**
2. Click the green **New organization** button
3. Choose the **Free** plan
4. **Organization account name:** something unique, e.g. `acme-platform-yourname`
5. **Contact email:** your email
6. Select **My personal account** when asked who it belongs to
7. Click **Next**, then **Skip this step** on the invite-members page

You now have `github.com/acme-platform-yourname`. Use this as the owner for all 11 repos below.

> **Throughout this guide, `OWNER` means either your username or your org name.**

---

## Section E2 — Create the 11 repositories

You will repeat this 11 times. It takes about 30 seconds each.

### The exact steps (do this once per repo)

1. Go to https://github.com
2. Click the **`+`** icon in the top-right corner → **New repository**
3. **Owner** dropdown: select your org (or your username)
4. **Repository name:** type the repo name from the list below — exactly as written
5. **Description:** optional, but good practice. e.g. `Product catalog microservice — Node.js`
6. **Visibility:** select **Private** (enterprise default — never start public)
7. **Initialize this repository with:** tick **Add a README file**
   - This matters: a repo with no commits has **no default branch**, and you can't set branch protection on a branch that doesn't exist. The README gives you a first commit.
8. **Add .gitignore:** select **Node** for Node.js services, **Python** for Python services, **Terraform** for the infrastructure repo (see the table below for which is which)
9. **Choose a license:** leave as **None** (internal/private code)
10. Click the green **Create repository** button

### The 11 repos to create

| # | Repository name | .gitignore template | What it is |
|---|---|---|---|
| 1 | `svc-frontend` | Node | Web UI / BFF |
| 2 | `svc-product-catalog` | Node | Product listings API |
| 3 | `svc-cart` | Node | Shopping cart |
| 4 | `svc-checkout` | Node | Checkout orchestration |
| 5 | `svc-payment` | Python | Payment processing |
| 6 | `svc-shipping` | Python | Shipping quotes |
| 7 | `svc-order` | Node | Order management |
| 8 | `svc-user-auth` | Python | Authentication |
| 9 | `svc-notification` | Python | Email/SMS notifications |
| 10 | `svc-recommendation` | Python | Product recommendations |
| 11 | `platform-infrastructure` | Terraform | All your Terraform |

**Verify:** go to `https://github.com/OWNER?tab=repositories` — you should see all 11 listed, each with a **Private** badge.

---

## Section E3 — Create the `develop` and `staging` branches

Each repo currently has only `main`. You need three branches, because branch = environment:

```
develop  ->  dev namespace
staging  ->  staging namespace
main     ->  prod namespace
```

### Steps (repeat per repo — all 11)

1. Open the repo, e.g. `github.com/OWNER/svc-frontend`
2. On the **Code** tab, click the **branch dropdown** (it says `main`, near the top-left of the file list)
3. In the **Find or create a branch...** text box, type `develop`
4. A row appears reading **Create branch: develop from 'main'** — click it
5. Repeat steps 2–4, this time typing `staging`

**Verify:** click the branch dropdown again — you should see `develop`, `main`, `staging`.

### Set `develop` as the default branch (recommended)

Day-to-day work lands on `develop`, so make it the default so PRs target it automatically.

1. In the repo, click **Settings** (tab across the top, needs admin rights)
2. Left sidebar → **General** (it's the default page)
3. Find the **Default branch** section
4. Click the **⇄ switch** icon next to `main`
5. Choose `develop` from the dropdown → **Update**
6. Confirm **I understand, update the default branch**

> Do this for all 10 service repos. For `platform-infrastructure`, leave `main` as default — infra usually promotes via directories, not branches.

---

## Section E4 — Branch protection (the enterprise gate)

This is what makes it "enterprise": nobody, including you, pushes straight to prod.

GitHub now offers **Rulesets** (newer) and **Branch protection rules** (classic). Rulesets are what modern orgs use. I'll give you Rulesets, with the classic path noted.

### Steps (per repo — do the 10 service repos)

1. Repo → **Settings**
2. Left sidebar → **Rules** → **Rulesets**
3. Click **New ruleset** → **New branch ruleset**
4. **Ruleset Name:** `protect-main`
5. **Enforcement status:** switch to **Active**
6. Under **Target branches** → click **Add target** → **Include by pattern** → type `main` → **Add Inclusion pattern**
7. Under **Rules**, tick these boxes:
   - ✅ **Restrict deletions**
   - ✅ **Require a pull request before merging**
     - Set **Required approvals** to `1`
     - ✅ **Dismiss stale pull request approvals when new commits are pushed**
   - ✅ **Block force pushes**
   - ✅ **Require status checks to pass** — leave the check list empty for now; you'll add the Jenkins check in Part 5 once it has reported once
   - ✅ **Require linear history** (optional, keeps history clean)
8. Click **Create**

### Repeat for `staging`

Same steps, but:
- **Ruleset Name:** `protect-staging`
- **Target branches** pattern: `staging`
- Same rules, approvals = `1`

### Leave `develop` unprotected
Developers need to move fast on dev. That's intentional and matches real practice.

> **Classic path instead:** Settings → **Branches** → **Add branch protection rule** → Branch name pattern `main` → tick *Require a pull request before merging*, *Require status checks to pass before merging*, *Do not allow bypassing the above settings*.

> **Common errors**
> - **You can't find Settings** → you're not an admin of that repo/org, or you're looking at someone else's fork.
> - **Ruleset saves but doesn't block you** → Enforcement status was left on *Evaluate*. Set it to **Active**.
> - **"Require status checks" shows no checks to pick** → normal. Jenkins hasn't reported a check yet. Come back in Part 5.

---

## Section E5 — Protect your GCP key in `.gitignore`

Your `terraform-admin-key.json` must never reach GitHub. Even though it lives in `~/.gcp-keys`, one careless `cp` into a repo would leak it.

### Steps (do this on `platform-infrastructure` at minimum, ideally all 11)

1. Open the repo → **Code** tab
2. Make sure the branch dropdown shows `develop` (or `main` for infra)
3. Click the **`.gitignore`** file
4. Click the **pencil ✏️ icon** (top-right of the file view) to edit
5. Scroll to the bottom and paste:

```gitignore
# --- GCP / Terraform secrets — never commit ---
*.json
!package.json
!package-lock.json
!tsconfig.json
.gcp-keys/
*-key.json
credentials.json
service-account*.json

# Terraform local state and vars
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!example.tfvars
crash.log
.terraform.lock.hcl

# Environment files
.env
*.env
!example.env
```

6. Scroll down to **Commit changes**
7. **Commit message:** `chore: ignore GCP keys and terraform state`
8. Select **Commit directly to the `develop` branch**
9. Click **Commit changes**

> **Why the `!package.json` lines:** `*.json` would otherwise ignore your Node service's `package.json`, and your build would break in a very confusing way. The `!` lines re-include the files you *do* need.

---

## Section E6 — Create a Personal Access Token (PAT)

Your Linux machine and Jenkins both need to authenticate to GitHub. GitHub removed password auth, so you use a token.

### Steps

1. Click your **profile photo** (top-right) → **Settings** (this is *account* settings, not repo settings)
2. Scroll the left sidebar to the very bottom → **Developer settings**
3. Left sidebar → **Personal access tokens** → **Fine-grained tokens**
4. Click **Generate new token**
5. **Token name:** `linux-workstation-and-jenkins`
6. **Expiration:** 90 days (enterprise practice — never "no expiration")
7. **Resource owner:** select your **organisation** (or your username)
8. **Repository access:** select **All repositories**
   - *(Stricter alternative: "Only select repositories" and pick your 11. More realistic, more clicking.)*
9. **Permissions** → expand **Repository permissions** and set:
   - **Contents:** `Read and write` (clone and push)
   - **Metadata:** `Read-only` (auto-selected, required)
   - **Pull requests:** `Read and write`
   - **Commit statuses:** `Read and write` ← **critical**, this is how Jenkins reports pass/fail back onto your PRs
   - **Webhooks:** `Read and write`
10. Click **Generate token**
11. **Copy the token now** — it starts `github_pat_...` and GitHub will never show it again

### Store it safely on your Linux box

```bash
$ mkdir -p ~/.secrets && chmod 700 ~/.secrets
$ echo "github_pat_PASTE_YOURS_HERE" > ~/.secrets/github-pat.txt
$ chmod 600 ~/.secrets/github-pat.txt
```

> If your org requires it: some orgs must **approve** fine-grained tokens. Settings → your org → Personal access tokens → Pending requests. If your token seems to have no access, check there.

---

## Section E7 — Configure Git on your Linux machine

```bash
$ git config --global user.name "Your Name"
$ git config --global user.email "your-email@example.com"
$ git config --global init.defaultBranch main
$ git config --global credential.helper store
```

**Verify:**
```bash
$ git config --global --list
```
**Expected output:**
```
user.name=Your Name
user.email=your-email@example.com
init.defaultBranch=main
credential.helper=store
```

> `credential.helper store` saves your PAT in plaintext at `~/.git-credentials` after the first push. Fine for a learning box you control; a real workstation would use `libsecret` instead:
> `sudo apt-get install -y libsecret-1-0 libsecret-1-dev && sudo make -C /usr/share/doc/git/contrib/credential/libsecret && git config --global credential.helper /usr/share/doc/git/contrib/credential/libsecret/git-credential-libsecret`

---

## Section E8 — Clone all 11 repos

Replace `OWNER` with your username or org name:

```bash
$ export OWNER="your-github-username-or-org"

$ mkdir -p ~/enterprise-platform && cd ~/enterprise-platform

$ for REPO in svc-frontend svc-product-catalog svc-cart svc-checkout \
    svc-payment svc-shipping svc-order svc-user-auth svc-notification \
    svc-recommendation platform-infrastructure
  do
    git clone "https://github.com/${OWNER}/${REPO}.git"
  done
```

The **first** clone prompts for credentials:
- **Username:** your GitHub username
- **Password:** paste your **PAT** (not your GitHub password)

Thanks to `credential.helper store`, the remaining 10 clone silently.

**Verify:**
```bash
$ ls ~/enterprise-platform
```
**Expected output:**
```
platform-infrastructure  svc-cart      svc-checkout  svc-frontend
svc-notification         svc-order     svc-payment   svc-product-catalog
svc-recommendation       svc-shipping  svc-user-auth
```

**Verify branches came down:**
```bash
$ cd ~/enterprise-platform/svc-frontend
$ git branch -a
```
**Expected output:**
```
* develop
  remotes/origin/HEAD -> origin/develop
  remotes/origin/develop
  remotes/origin/main
  remotes/origin/staging
```

> **Common errors**
> - `Authentication failed` → you pasted your GitHub *password* instead of the PAT, or the PAT lacks **Contents: Read and write**.
> - `remote: Repository not found` on a private repo → same cause; GitHub hides private repos from unauthorised requests rather than saying "denied".
> - Wrong token cached → `rm ~/.git-credentials` and clone again.

---

## Section E9 — Webhook placeholder (finish in Part 5)

Jenkins needs GitHub to notify it on every push. You can't complete this yet — Jenkins has no URL until Part 3. Here's where it lives so you know the path:

1. Repo → **Settings** → **Webhooks** (left sidebar) → **Add webhook**
2. **Payload URL:** `http://JENKINS_URL/github-webhook/` ← the trailing slash matters
3. **Content type:** `application/json`
4. **Secret:** a random string you'll also paste into Jenkins
5. **Which events:** select **Let me select individual events** → tick **Pushes** and **Pull requests**
6. ✅ **Active** → **Add webhook**

Leave this until Part 5.

> **SRE note you'll appreciate:** your Jenkins controller will be private (no public IP, reached via bastion), so GitHub's webhook can't reach it. Real enterprises solve this three ways: a private GitHub runner, an internal load balancer + VPN/Interconnect, or polling. We'll use **SCM polling** as the pragmatic default and I'll flag it as the deliberate trade-off it is.

---

## Section E10 — Checklist

- [ ] Org created (or personal account chosen)
- [ ] All 11 repos exist, all **Private**, all with a README
- [ ] Each of the 10 service repos has `develop`, `staging`, `main`
- [ ] `develop` is the default branch on the 10 service repos
- [ ] `protect-main` ruleset **Active** on all 10 (PR + 1 approval + no force push)
- [ ] `protect-staging` ruleset **Active** on all 10
- [ ] `.gitignore` updated to block `*.json` keys and tfstate
- [ ] Fine-grained PAT created with Contents/PRs/Commit statuses = write, stored at `~/.secrets/github-pat.txt`
- [ ] Git configured globally on Linux
- [ ] All 11 repos cloned to `~/enterprise-platform`
- [ ] `git branch -a` shows all three branches

### Proof test — confirm protection actually works

Try to push straight to `main` on one repo. It **must fail**:

```bash
$ cd ~/enterprise-platform/svc-frontend
$ git checkout main
$ echo "test" >> README.md
$ git commit -am "test: should be rejected"
$ git push origin main
```

**Expected output:**
```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - Changes must be made through a pull request.
! [remote rejected] main -> main (push declined due to repository rule violations)
```

That rejection is your proof the enterprise gate is live. Clean up:
```bash
$ git reset --hard origin/main
$ git checkout develop
```

If the push **succeeded**, your ruleset is on *Evaluate* instead of **Active**, or the pattern didn't match `main`. Go back to E4.

---

## Next: Part 2 — Terraform

Module structure (`vpc`, `gke`, `artifact-registry`, `iam`, `workload-identity`, `tooling`), per-environment root configs wired to your GCS backend, the **2-node GKE cluster**, and the four tooling VMs (bastion, Jenkins controller, Jenkins agent, SonarQube).
