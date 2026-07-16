# Part 3 — Jenkins and SonarQube

**Before you start:**
- Part 2 complete: `terraform apply` succeeded, 4 VMs `RUNNING`, cluster has exactly 2 nodes
- The startup scripts have finished (5–10 min after apply). Verify:

```bash
$ gcloud compute ssh dev-jenkins-controller --zone=asia-south1-a --tunnel-through-iap \
    --command="sudo systemctl is-active jenkins"
```
**Expected output:**
```
active
```

**By the end of this part:** Jenkins reachable, agent connected, SonarQube gating builds, and one real pipeline that fails a build on purpose to prove the gate works.

---

## Section A — Reach the private Jenkins

### Why
Your Jenkins controller has **no public IP**. That's deliberate — it's the box holding every credential you own. There is no address the internet could even send a packet to.

That means every access method is some form of **tunnel**: an authenticated pipe from somewhere-with-a-browser to the private VM. Which method you use depends on where your browser actually is — and getting that mismatched is the single most common failure in this whole section.

### The one rule that explains every failure in this section

**A tunnel opens a port on whichever machine runs the tunnel command — not on your laptop, and not automatically anywhere useful.**

```
gcloud compute start-iap-tunnel ... --local-host-port=localhost:8080
                                                        ^^^^^^^^^
                                          this "localhost" belongs to
                                          whatever machine typed the command
```

Run that command **on a headless GCE VM you SSH'd into**, and you've made Jenkins reachable — from that VM's own loopback interface. Nothing else. Your Windows or Mac browser is a completely different computer and has no path to it. `curl localhost:8080` on that VM will succeed; your browser will not, no matter how long you wait.

So before touching any command below, answer one question: **where is my browser?** Then use the matching method.

### Method 1 — Cloud Shell (recommended; nothing to install)

Cloud Shell is a small Linux VM Google runs for you, with one feature none of your other VMs have: **Web Preview**, which proxies its `localhost` straight out to a tab in your actual browser. That's the missing piece every other method has to work around.

1. Google Cloud Console → click the **`>_`** icon, top-right → Cloud Shell opens
2. ```bash
   gcloud compute start-iap-tunnel dev-jenkins-controller 8080 \
     --local-host-port=localhost:8080 \
     --zone=asia-south1-a --project=YOUR_PROJECT_ID
   ```
3. **Expected output:**
   ```
   Testing if tunnel connection works.
   Listening on port [8080].
   ```
   Leave this terminal running — closing it kills the tunnel. Open a `+` tab for anything else.
4. Click the **eye icon** (Web Preview) in the Cloud Shell toolbar → **Preview on port 8080**

A new browser tab opens at a Google-generated `https://8080-cs-....cloudshell.dev` URL. **That's your Jenkins UI.** Not an IP, not `localhost` — a proxied URL Google issues per-session.

For SonarQube, open a second Cloud Shell tab (`+`) and repeat with `dev-sonarqube` / port `9000` / Web Preview on port 9000.

> **Why this is the recommended method:** it rides over HTTPS/443 through the Console, which essentially no corporate or mobile network blocks. Every other method depends on port 8080 or 22 making it out of *your* network, which is exactly the kind of thing IT departments lock down.

### Method 2 — your own laptop

If you'd rather have gcloud installed locally (you'll want this again for Grafana in Part 5 and Argo CD in Part 6):

1. Install: <https://cloud.google.com/sdk/docs/install-sdk>
2. In a terminal **on your laptop**:
   ```bash
   gcloud auth login
   gcloud config set project YOUR_PROJECT_ID
   gcloud compute start-iap-tunnel dev-jenkins-controller 8080 \
     --local-host-port=localhost:8080 \
     --zone=asia-south1-a
   ```
3. Browse to **http://localhost:8080** — this time `localhost` really is your machine, because your machine ran the command.

### Method 3 — through the bastion, manually (what earlier drafts of this guide showed)

```bash
$ gcloud compute ssh dev-bastion --zone=asia-south1-a --tunnel-through-iap -- \
    -L 8080:10.10.16.3:8080 \
    -L 9000:10.10.16.5:9000 \
    -o ServerAliveInterval=30 -N
```

This forwards through the bastion by IP rather than by instance name. It works identically to Method 2 once you substitute **your real private IPs** — see the warning below. Functionally it's the same tunnel; Methods 1 and 2 are simpler because `start-iap-tunnel` addresses the instance by name and doesn't need the bastion hop at all.

### Verify, from wherever you actually tunnelled

```bash
$ curl -s -o /dev/null -w "jenkins:%{http_code}\n" http://localhost:8080/login
$ curl -s -o /dev/null -w "sonar:%{http_code}\n"   http://localhost:9000
```

**Expected output:**
```
jenkins:200
sonar:200
```

`000` or a hang means one of two things — a firewall gap (see below) or you're checking `localhost` on the wrong machine (see the rule above).

### ⚠️ Before any of this works: the firewall

`start-iap-tunnel` to port 8080 will report `Listening on port [8080]` **even if the firewall blocks it** — the tunnel only needs SSH to establish itself. The actual HTTP request riding inside then hits the VM's firewall and is dropped silently. It looks exactly like a hung server.

Confirm the rule exists:

```bash
$ gcloud compute firewall-rules describe dev-allow-iap-web \
    --project=YOUR_PROJECT_ID --format="value(sourceRanges[],allowed[].ports)"
```

**Expected output:**
```
['35.235.240.0/20']    ['8080', '9000']
```

If that errors with `was not found`, create it (this is now baked into the Terraform VPC module — re-run `terraform apply`, or create it directly if you don't want to re-apply):

```bash
$ gcloud compute firewall-rules create dev-allow-iap-web \
    --network=dev-vpc --allow=tcp:8080,tcp:9000 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=jenkins-controller,sonarqube \
    --project=YOUR_PROJECT_ID
```

> **Why not just give Jenkins a public IP and skip all of this?** A public Jenkins is a public credential store. This is genuinely how it's done in real environments — one hardened, authenticated door (IAP), everything else with no address the internet can reach at all. The cost is exactly the friction you just worked through, plus two webhook workarounds later — SonarQube→Jenkins in Section D4, and GitHub→Jenkins in Section G.

### Your real internal IPs — different from what this guide hardcodes

GCP assigns internal IPs from the subnet pool in creation order, so yours won't match the ones printed in this document (`10.10.16.3/4/5`). Get your real ones:

```bash
$ cd ~/enterprise-platform/platform-infrastructure/environments/dev
$ terraform output jenkins_controller_ip
$ terraform output jenkins_agent_ip
$ terraform output sonarqube_ip
```

**Substitute your real values everywhere this guide shows an IP** — the Jenkins URL setting (Section B3), the agent host (Section C5), and especially the **SonarQube webhook** (Section D4). Getting the webhook IP wrong is what makes the quality gate hang for 5 minutes with no useful error later.

### Common errors

| Symptom | Cause |
|---|---|
| `Listening on port [8080]` but browser/curl times out | **Firewall.** See the box above — `dev-allow-iap-web` missing or wrong ports. |
| Tunnel command hangs, `curl localhost:8080` works, but your browser shows nothing | **You tunnelled from the wrong machine.** The port only exists on whatever ran the command. Use Method 1 or 2. |
| `bind: Address already in use` | Something local is already on 8080. Use a different local port: `--local-host-port=localhost:8081`. |
| `Permission denied (publickey)` | Your gcloud SSH key isn't provisioned yet. Run a plain `gcloud compute ssh dev-bastion --tunnel-through-iap` once to generate and push one. |
| `[4033: not authorized]` | You need `roles/iap.tunnelResourceAccessor` on your **user** account, not just the VM's service account. |
| Tunnel dies after a few idle minutes | Add `-o ServerAliveInterval=30` (SSH form) — `start-iap-tunnel` doesn't need this. |
| `unzip: command not found` on your own workstation VM | Not part of this platform — a bare Ubuntu image gap. `sudo apt-get update && sudo apt-get install -y unzip`. |

## Section B — Unlock Jenkins and install plugins

### Why
Jenkins ships locked. The initial password lives on disk on the controller, which proves you have access to the machine before you can configure it.

### B1 — Get the unlock password

```bash
$ gcloud compute ssh dev-jenkins-controller --zone=asia-south1-a --tunnel-through-iap \
    --command="sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
```

**Expected output:**
```
a1b2c3d4e5f64789abcdef0123456789
```

Copy it, paste it into the browser at **http://localhost:8080**, click **Continue**.

### B2 — Install plugins

1. Click **Select plugins to install** (not "Install suggested plugins")
2. Click **None** at the top to clear everything
3. Tick exactly these:

| Plugin | Why you need it |
|---|---|
| **Folders** | Organising jobs |
| **Pipeline** | Runs your Jenkinsfile at all |
| **Pipeline: Stage View** | The visual pipeline graph |
| **Git** | Clones your repos |
| **GitHub Branch Source** | Multibranch — discovers `develop`/`staging`/`main` |
| **SSH Build Agents** | Connects your agent VM |
| **Credentials Binding** | Makes `credentials('gcp-project-id')` work |
| **SonarQube Scanner** | Provides `withSonarQubeEnv` and `waitForQualityGate` |
| **Workspace Cleanup** | Provides `cleanWs()` |
| **Timestamper** | Provides `timestamps()` |
| **Build Timeout** | Provides the `timeout()` option |

4. Click **Install**

**Wait 2–5 minutes.** Every one of those maps to something your Jenkinsfile actually calls — miss one and you get a cryptic "No such DSL method" error at runtime.

### B3 — Create your admin user

Fill in username, password, name, email → **Save and Continue**.

**Jenkins URL:** it will suggest `http://localhost:8080/`. **Change it to:**

```
http://10.10.16.3:8080/
```

> **This matters more than it looks.** SonarQube will call back to Jenkins at this URL from *inside the VPC*. `localhost` means nothing to SonarQube — that's your laptop, not Jenkins. Get this wrong and your quality gate hangs forever in Section F.

Click **Save and Finish** → **Start using Jenkins**.

### Common errors

| Symptom | Cause |
|---|---|
| `sudo: a password is required` | Add `--command="sudo -n cat ..."` or SSH in interactively first. |
| Plugin install fails / hangs | The controller reaches the internet via Cloud NAT. Verify: `gcloud compute ssh dev-jenkins-controller --tunnel-through-iap --command="curl -sI https://updates.jenkins.io \| head -1"` |
| Password file not found | Jenkins hasn't finished first boot. `sudo systemctl status jenkins` and wait. |

---

## Section C — Connect the build agent

### Why
Your Jenkinsfile starts with:

```groovy
agent { label 'linux-docker' }
```

Nothing has that label yet, so **every build would queue forever**. This section fixes that.

Remember the boundary you built in Terraform: the **controller has no Docker and no deploy permissions**. The agent has both. If the controller is compromised, the attacker gets an orchestrator that can write logs. The agent holds the power — and the agent is disposable.

### C1 — Generate an SSH key for Jenkins

The controller SSHes into the agent as the `jenkins` user. Make the key **on the controller**:

```bash
$ gcloud compute ssh dev-jenkins-controller --zone=asia-south1-a --tunnel-through-iap
```

Then, on the controller:

```bash
you@dev-jenkins-controller:~$ sudo -u jenkins ssh-keygen -t ed25519 -f /var/lib/jenkins/.ssh/agent_key -N "" -C "jenkins-controller-to-agent"
```

**Expected output:**
```
Generating public/private ed25519 key pair.
Your identification has been saved in /var/lib/jenkins/.ssh/agent_key
Your public key has been saved in /var/lib/jenkins/.ssh/agent_key.pub
```

Print both — you'll need them:

```bash
you@dev-jenkins-controller:~$ sudo cat /var/lib/jenkins/.ssh/agent_key.pub
you@dev-jenkins-controller:~$ sudo cat /var/lib/jenkins/.ssh/agent_key
```

**Expected output:**
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample... jenkins-controller-to-agent
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
...
-----END OPENSSH PRIVATE KEY-----
```

Copy **both** to a scratch file. Then `exit`.

### C2 — Authorise the key on the agent

```bash
$ gcloud compute ssh dev-jenkins-agent-01 --zone=asia-south1-a --tunnel-through-iap
```

On the agent, paste the **public** key (the `ssh-ed25519 AAAA...` one):

```bash
you@dev-jenkins-agent-01:~$ sudo mkdir -p /home/jenkins/.ssh
you@dev-jenkins-agent-01:~$ echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample... jenkins-controller-to-agent" \
    | sudo tee -a /home/jenkins/.ssh/authorized_keys
you@dev-jenkins-agent-01:~$ sudo chmod 700 /home/jenkins/.ssh
you@dev-jenkins-agent-01:~$ sudo chmod 600 /home/jenkins/.ssh/authorized_keys
you@dev-jenkins-agent-01:~$ sudo chown -R jenkins:jenkins /home/jenkins/.ssh
```

**Verify the agent has everything the pipeline needs:**

```bash
you@dev-jenkins-agent-01:~$ sudo -u jenkins docker ps
you@dev-jenkins-agent-01:~$ java -version 2>&1 | head -1
you@dev-jenkins-agent-01:~$ node --version && python3 --version
you@dev-jenkins-agent-01:~$ which kubectl trivy sonar-scanner envsubst
```

**Expected output:**
```
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
openjdk version "21.0.5" 2024-10-15
v20.17.0
Python 3.12.3
/usr/bin/kubectl
/usr/bin/trivy
/usr/local/bin/sonar-scanner
/usr/bin/envsubst
```

> **`docker ps` working as the `jenkins` user is the check that matters.** It proves the startup script's `usermod -aG docker jenkins` took effect. If you get `permission denied`, run `sudo usermod -aG docker jenkins` and reboot the VM.

`exit`.

### C3 — Test the connection controller → agent

Back on the controller:

```bash
$ gcloud compute ssh dev-jenkins-controller --zone=asia-south1-a --tunnel-through-iap \
    --command="sudo -u jenkins ssh -i /var/lib/jenkins/.ssh/agent_key -o StrictHostKeyChecking=no jenkins@10.10.16.4 'hostname && whoami && docker --version'"
```

**Expected output:**
```
Warning: Permanently added '10.10.16.4' (ED25519) to the list of known hosts.
dev-jenkins-agent-01
jenkins
Docker version 27.1.2, build d01f264
```

**That's the proof.** The controller can reach the agent, as `jenkins`, with Docker. If this fails, Jenkins will fail the same way — fix it here, not in the UI.

### C4 — Add the credential in Jenkins

In the browser:

1. **Manage Jenkins** → **Credentials** → **System** → **Global credentials (unrestricted)**
2. **+ Add Credentials**
3. Fill in:
   - **Kind:** `SSH Username with private key`
   - **Scope:** `Global`
   - **ID:** `jenkins-agent-ssh` ← exact
   - **Description:** `SSH key for build agent`
   - **Username:** `jenkins`
   - **Private Key:** select **Enter directly** → **Add** → paste the **private** key
     - Include `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END...-----`
   - **Passphrase:** leave empty
4. **Create**

### C5 — Register the agent

1. **Manage Jenkins** → **Nodes** → **+ New Node**
2. **Node name:** `linux-docker-01` → select **Permanent Agent** → **Create**
3. Configure:

| Field | Value |
|---|---|
| Description | `Build agent — Docker, Node, Python, Trivy, Sonar` |
| Number of executors | `2` |
| Remote root directory | `/home/jenkins/agent` |
| **Labels** | `linux-docker` ← **must match the Jenkinsfile exactly** |
| Usage | `Only build jobs with label expressions matching this node` |
| Launch method | `Launch agents via SSH` |
| Host | `10.10.16.4` |
| Credentials | `jenkins (SSH key for build agent)` |
| Host Key Verification Strategy | `Non verifying Verification Strategy` |

4. **Save**

> **The label is the whole point.** `linux-docker` is what `agent { label 'linux-docker' }` looks for. A typo here means every build queues forever with "no nodes with label" — and Jenkins won't tell you loudly.
>
> **2 executors, not more.** The agent is `e2-standard-4` (4 vCPU). Two concurrent Docker builds will use it fully. Set it to 8 and builds will thrash and time out.

### C6 — Confirm it connected

**Manage Jenkins** → **Nodes**. Within ~30 seconds:

```
Name              Architecture     Free Disk Space    Response Time
linux-docker-01   Linux (amd64)    182.41 GB          43ms
```

Click the node → **Log**:

**Expected output:**
```
SSHLauncher{host='10.10.16.4', port=22, ...}
[SSH] Opening SSH connection to 10.10.16.4:22.
[SSH] Authentication successful.
[SSH] The remote user's environment is:
...
Agent successfully connected and online
```

**"Agent successfully connected and online" is your proof.**

### Common errors

| Symptom | Cause |
|---|---|
| `Server rejected the 1 private key(s)` | Public key not in `/home/jenkins/.ssh/authorized_keys` on the agent, or permissions wrong (must be 700/600, owned by `jenkins`). |
| `java.io.IOException: Java not found` | Java missing, or Java 17. Jenkins needs **21+**: `sudo apt-get install -y openjdk-21-jdk && sudo update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java` |
| `Connection refused` | Wrong IP, or the agent VM is stopped. Re-check `terraform output jenkins_agent_ip`. |
| Agent connects, builds still queue | Label typo. Must be exactly `linux-docker`. |
| `Permission denied` running docker in a build | `usermod -aG docker jenkins` didn't apply. Reboot the agent VM. |

---

## Section D — Set up SonarQube

### Why
SonarQube is what makes your quality gate real. Right now it has no projects, no token, and no gate — so `waitForQualityGate` in your Jenkinsfile would fail.

### D1 — First login

Browse to **http://localhost:9000** (via the tunnel from Section A).

**Default credentials:**
```
Username: admin
Password: admin
```

It forces a password change immediately. Set a strong one and **store it** — you'll want it in Secret Manager later.

### D2 — Generate a token for Jenkins

Jenkins authenticates to SonarQube with a token, never a password.

1. Click your **avatar** (top right) → **My Account**
2. **Security** tab
3. Under **Generate Tokens**:
   - **Name:** `jenkins`
   - **Type:** `Global Analysis Token`
   - **Expires in:** `90 days`
4. **Generate**

**Expected output:**
```
squ_a1b2c3d4e5f6789012345678901234567890abcd
```

**Copy it now.** SonarQube shows it exactly once.

### D3 — Create the quality gate

This is the thing that actually blocks builds.

1. **Quality Gates** (top nav) → **Create**
2. **Name:** `Platform Gate` → **Save**
3. Click **Unlock editing**
4. **Add Condition** for each of these — all on **On New Code**:

| Metric | Operator | Value |
|---|---|---|
| Coverage | is less than | `60` |
| Duplicated Lines (%) | is greater than | `5` |
| Maintainability Rating | is worse than | `A` |
| Reliability Rating | is worse than | `A` |
| Security Rating | is worse than | `A` |
| Security Hotspots Reviewed | is less than | `100` |

5. Click **Set as Default** (top right)

> **Why "On New Code" and not overall?** Gate on total coverage on day one and every legacy repo fails instantly — so everyone disables the gate, and you've achieved nothing. Gate on *new* code and the codebase improves with every commit while old debt stays visible but non-blocking.
>
> This is the single most common reason quality gates get abandoned in real orgs. Your `sonar-project.properties` already sets `sonar.newCode.referenceBranch=develop` to match.
>
> **60% coverage, not 80%.** A number people can actually hit is a number people don't route around.

### D4 — The webhook back to Jenkins ← don't skip this

**This is the step everyone misses**, and the symptom is maddening: your build hangs at "Quality gate" for 5 minutes, then times out with no useful error.

Here's why. `waitForQualityGate` doesn't poll SonarQube. It **waits for SonarQube to call Jenkins back.** No webhook, no callback, no gate.

1. **Administration** → **Configuration** → **Webhooks**
2. **Create**
3. Fill in:
   - **Name:** `jenkins`
   - **URL:** `http://10.10.16.3:8080/sonarqube-webhook/`
   - **Secret:** leave empty
4. **Create**

> **The trailing slash is required.** `/sonarqube-webhook` (no slash) silently fails.
>
> **Use the internal IP, not localhost.** SonarQube runs on its own VM. `localhost` there means the SonarQube box. The two VMs talk over the VPC — which your `allow_internal` firewall rule already permits, because both are in the tooling subnet.

**Verify the two VMs can actually reach each other:**

```bash
$ gcloud compute ssh dev-sonarqube --zone=asia-south1-a --tunnel-through-iap \
    --command="curl -s -o /dev/null -w '%{http_code}\n' http://10.10.16.3:8080/login"
```

**Expected output:**
```
200
```

**`200` means the webhook will work.** If you get `000`, the firewall or Jenkins is the problem — fix it now, not when a build hangs.

### Common errors

| Symptom | Cause |
|---|---|
| Can't reach `localhost:9000` | SonarQube still starting. `sudo docker logs sonarqube` on the VM. Elasticsearch takes minutes. |
| `sonarqube` container restarting | `vm.max_map_count` too low. The startup script sets it; verify with `sysctl vm.max_map_count` (needs ≥ 262144). |
| Token lost | Can't recover it. Revoke and generate a new one. |
| Gate exists but never applies | You forgot **Set as Default**. |

---

## Section E — Add Jenkins credentials

### Why
Your Jenkinsfiles reference credentials **by exact ID**:

```groovy
GCP_PROJECT = credentials('gcp-project-id')
SONAR_HOST  = credentials('sonarqube-url')
```

If an ID doesn't exist, the build fails immediately with `Could not find credentials entry with ID`.

### Commands

Get your project ID:

```bash
$ gcloud config get-value project
```

**Expected output:**
```
my-project-id
```

Now in Jenkins: **Manage Jenkins** → **Credentials** → **System** → **Global credentials** → **+ Add Credentials**.

Add these four:

| # | Kind | ID (exact) | Value |
|---|---|---|---|
| 1 | Secret text | `gcp-project-id` | your project ID, e.g. `my-project-id` |
| 2 | Secret text | `sonarqube-url` | `http://10.10.16.5:9000` |
| 3 | Secret text | `sonarqube-token` | the `squ_...` token from D2 |
| 4 | Username with password | `github-pat` | Username: your GitHub username · Password: your `github_pat_...` from Part 1B |

> **IDs are case-sensitive and must match the Jenkinsfile character for character.** `gcp-project-id`, not `gcp_project_id`.
>
> **`sonarqube-url` uses the internal IP.** The *agent* calls SonarQube from inside the VPC. `localhost:9000` only works from your laptop through the tunnel.

**Verify:**

**Manage Jenkins** → **Credentials**. You should see:

```
ID                    Name                              Kind
gcp-project-id        gcp-project-id                    Secret text
github-pat            your-username/******              Username with password
jenkins-agent-ssh     jenkins (SSH key for build agent) SSH Username with private key
sonarqube-token       sonarqube-token                   Secret text
sonarqube-url         sonarqube-url                     Secret text
```

**Five credentials.** That's the set.

---

## Section F — Wire Jenkins to SonarQube

### Why
Your Jenkinsfile calls:

```groovy
withSonarQubeEnv('sonarqube') { ... }
```

That name — `sonarqube` — must match a server configured in Jenkins **exactly**.

### Commands

1. **Manage Jenkins** → **System**
2. Scroll to **SonarQube servers**
3. Tick **Environment variables** (this injects `SONAR_HOST_URL` and `SONAR_AUTH_TOKEN`)
4. **Add SonarQube**:

| Field | Value |
|---|---|
| **Name** | `sonarqube` ← **exact match to the Jenkinsfile** |
| **Server URL** | `http://10.10.16.5:9000` |
| **Server authentication token** | select `sonarqube-token` |

5. **Save**

> **The `Name` field is the connection.** `withSonarQubeEnv('sonarqube')` looks up a server literally named `sonarqube`. Name it `SonarQube` (capital S) and you get `No SonarQube installation found`.

### Common errors

| Symptom | Cause |
|---|---|
| `No SonarQube installation found` | Name mismatch. Must be lowercase `sonarqube`. |
| Token dropdown empty | You added the token as the wrong kind. Must be **Secret text**. |
| `waitForQualityGate` hangs 5 min then fails | **The webhook from D4.** This is nearly always the cause. |

---

## Section G — Create the pipeline jobs

### Why
A Multibranch Pipeline scans your repo, finds every branch with a `Jenkinsfile`, and creates a job for each. That's how one Jenkinsfile serves `develop` → dev, `staging` → staging, `main` → prod.

### G1 — Push a service repo first

Jenkins needs something to find. Start with `product-catalog` — it has **no dependencies**, so if it breaks, it's your pipeline, not your service graph.

```bash
$ cd ~/enterprise-platform/svc-product-catalog
$ cp -r ~/Downloads/enterprise-platform/svc-product-catalog/. .
$ ls
```

**Expected output:**
```
Dockerfile  Jenkinsfile  README.md  k8s  package.json  scripts
sonar-project.properties  src  tests
```

```bash
$ git checkout develop
$ git add .
$ git commit -m "feat: product catalog service"
$ git push origin develop
```

**Verify nothing sensitive went up:**

```bash
$ git log --all --full-history --name-only -- "*.json" | grep -v package | head
```

**Expected output:** (nothing except package.json / package-lock.json)

### G2 — Create the job

1. Jenkins home → **+ New Item**
2. **Name:** `svc-product-catalog`
3. Select **Multibranch Pipeline** → **OK**
4. **Branch Sources** → **Add source** → **GitHub**:

| Field | Value |
|---|---|
| Credentials | `github-pat` |
| Repository HTTPS URL | `https://github.com/YOUR_ORG/svc-product-catalog` |

5. Click **Validate** → should say **Credentials ok. Connected to ...**

6. **Behaviours** — remove `Discover pull requests from forks` (you don't need it), keep:
   - `Discover branches` → strategy: **All branches**
   - `Discover pull requests from origin` → **Merging the pull request with the current target branch revision**

7. **Build Configuration**:
   - Mode: `by Jenkinsfile`
   - Script Path: `Jenkinsfile`

8. **Scan Multibranch Pipeline Triggers**:
   - ✅ **Periodically if not otherwise run** → Interval: **1 minute**

9. **Save**

> ### The webhook problem, stated honestly
>
> Normally GitHub pushes a webhook to Jenkins the instant you commit. **That can't work here** — your Jenkins has no public IP, so GitHub literally cannot reach it.
>
> So we poll. Your Jenkinsfile has `pollSCM('H/2 * * * *')` and the job scans every minute.
>
> **What it costs:** up to 2 minutes of latency before a build starts, and constant background GitHub API calls whether or not anything changed. At 10 repos that's fine. At 200 repos you'd hit API rate limits.
>
> **What a real enterprise does instead:** an internal load balancer plus VPN/Interconnect so GitHub Enterprise (self-hosted, inside the network) can reach Jenkins; or a self-hosted runner that polls outbound; or moves to GitHub Actions with a private runner. All three were outside this project's constraints.
>
> This is a deliberate trade-off, not an oversight — worth being able to say out loud in an interview.

### G3 — Watch the first scan

Jenkins scans immediately after Save.

**Expected output** (in **Scan Repository Log**):
```
Started by user admin
[Wed Jul 15 09:14:22 IST 2026] Starting branch indexing...
Connecting to https://api.github.com with no credentials, anonymous access
Examining YOUR_ORG/svc-product-catalog
  Checking branches...
  Getting remote branches...
    Checking branch develop
      ‘Jenkinsfile’ found
    Met criteria
Scheduled build for branch: develop
    Checking branch main
      ‘Jenkinsfile’ not found
    Does not meet criteria
  1 branches were processed
[Wed Jul 15 09:14:25 IST 2026] Finished branch indexing.
```

**"‘Jenkinsfile’ found" then "Scheduled build for branch: develop"** — that's the connection working.

`main` says "not found" because you only pushed `develop`. That's correct.

---

## Section H — The first build, and the proof test

### H1 — Watch it run

Click **develop** → the build should already be running. Open **Console Output**.

**Expected output** (abridged, ~4–6 minutes):
```
[Pipeline] node
Running on linux-docker-01 in /home/jenkins/agent/workspace/svc-product-catalog_develop
[Pipeline] stage (Checkout)
Branch develop -> env dev
Image: asia-south1-docker.pkg.dev/my-project-id/dev-microservices/svc-product-catalog:dev-1-a1b2c3d
[Pipeline] stage (Install)
+ npm ci
added 312 packages in 8s
[Pipeline] stage (Unit tests)
+ npm test
 PASS  tests/app.test.js
  products API
    ✓ lists all products (24 ms)
    ✓ 404s on unknown product (3 ms)
    ✓ rejects reservation beyond stock (2 ms)
Tests:       8 passed, 8 total
[Pipeline] stage (SonarQube scan)
INFO: Analysis total time: 12.483 s
INFO: EXECUTION SUCCESS
[Pipeline] stage (Quality gate)
Checking status of SonarQube task 'AZk...' on server 'sonarqube'
SonarQube task 'AZk...' status is 'SUCCESS'
Quality gate status: OK
[Pipeline] stage (Build image)
+ docker build -t asia-south1-docker.pkg.dev/...
Successfully tagged ...
[Pipeline] stage (Trivy scan)
Total: 0 (HIGH: 0, CRITICAL: 0)
[Pipeline] stage (Push to Artifact Registry)
+ docker push ...
Finished: SUCCESS
```

**"Running on linux-docker-01"** — the agent connection works.
**"Quality gate status: OK"** — the webhook works.
**"Finished: SUCCESS"** — the whole chain works.

**Verify the image really landed:**

```bash
$ gcloud artifacts docker images list \
    asia-south1-docker.pkg.dev/$(gcloud config get-value project)/dev-microservices
```

**Expected output:**
```
IMAGE                                    DIGEST         CREATE_TIME
.../svc-product-catalog                  sha256:a1b2..  2026-07-15T09:22:14
```

### H2 — Proof test: make the gate fail on purpose

**A gate you've never seen fail is a gate you don't know works.**

```bash
$ cd ~/enterprise-platform/svc-product-catalog
$ cat >> src/routes.js << 'EOF'

// Deliberate quality violation to test the gate
function badFunction(a, b, c, d, e, f, g, h) {
  var unused = "this is dead code";
  if (a == b) { if (c == d) { if (e == f) { if (g == h) { return true; } } } }
  return false;
}
EOF

$ git add . && git commit -m "test: deliberately fail the quality gate" && git push origin develop
```

Wait ~2 minutes for the poll, then watch the build.

**Expected output:**
```
[Pipeline] stage (Quality gate)
Checking status of SonarQube task 'AZm...' on server 'sonarqube'
SonarQube task 'AZm...' status is 'SUCCESS'
Quality gate status: ERROR
[Pipeline] }
ERROR: Pipeline aborted due to quality gate failure: ERROR
Finished: FAILURE
```

**`Finished: FAILURE` is the success condition here.** The build stopped. No image was built, nothing was pushed, nothing reached your cluster.

Check SonarQube at **http://localhost:9000** → your project → you'll see the exact issues: unused variable, `==` instead of `===`, cognitive complexity.

**Now clean up:**

```bash
$ git revert HEAD --no-edit
$ git push origin develop
```

The next build should go green again.

> **This is the difference between a real pipeline and a demo.** Most tutorial pipelines run Sonar and print a report nobody reads. Yours *stops the build*. Same for Trivy — `--exit-code 1` on HIGH/CRITICAL means a known critical CVE cannot reach production, regardless of anyone's opinion about the deadline.

### H3 — Roll out to the other 9 repos

Repeat G1–G2 for each. Order matters for testing later:

1. `svc-product-catalog` ✅ done
2. `svc-cart`, `svc-order` (need catalog)
3. `svc-payment`, `svc-shipping`, `svc-user-auth`, `svc-notification`, `svc-recommendation`
4. `svc-checkout` (needs almost everything)
5. `svc-frontend` (the front door)

> **The Python repos differ:** their Jenkinsfile creates a venv and runs `pytest`. Same shape, same gates. The first Python build is slower (~7 min) because pip has no cache yet.

### Common errors

| Symptom | Cause |
|---|---|
| Build queues forever, never starts | Agent label mismatch. Check **Nodes** → label is exactly `linux-docker`. |
| `Could not find credentials entry with ID 'gcp-project-id'` | Credential ID typo. Section E. |
| `sonar-scanner: command not found` | Build ran on the controller, not the agent. Check the Console says "Running on linux-docker-01". |
| Quality gate hangs 5 min → timeout | **The SonarQube webhook (D4).** Nearly always this. |
| `denied: Permission "artifactregistry.repositories.uploadArtifacts"` | The agent VM's SA lacks the role — but Terraform grants it. Check the build ran on the agent, not the controller. |
| Trivy fails with HIGH CVEs on a fresh image | Genuine. Base images drift. Rebuild with `--pull`, or bump `node:20-alpine` / `python:3.12-slim`. |
| `npm ci` fails: `package-lock.json` not found | Your `.gitignore` ate it. Confirm the `!package-lock.json` re-include line is present. |

---

## Section I — Checklist

- [ ] IAP tunnel through the bastion reaches both `localhost:8080` and `localhost:9000`
- [ ] Jenkins unlocked, 11 plugins installed, admin user created
- [ ] **Jenkins URL set to `http://10.10.16.3:8080/`**, not localhost
- [ ] SSH key generated on the controller, authorised on the agent
- [ ] Manual SSH controller → agent works and shows Docker
- [ ] Node `linux-docker-01` online with label **`linux-docker`**, 2 executors
- [ ] SonarQube password changed, token generated
- [ ] `Platform Gate` created **and Set as Default**, conditions on **New Code**
- [ ] **SonarQube webhook → `http://10.10.16.3:8080/sonarqube-webhook/`** (trailing slash!)
- [ ] SonarQube VM can `curl` Jenkins and get `200`
- [ ] 5 Jenkins credentials exist with exact IDs
- [ ] SonarQube server in Jenkins named exactly **`sonarqube`**
- [ ] `svc-product-catalog` multibranch job scans and finds the Jenkinsfile
- [ ] First build: **SUCCESS**, image in Artifact Registry
- [ ] **Proof test: deliberately failed the quality gate and the build stopped**
- [ ] Reverted, build green again

### The three connections that break most often

| Connection | Symptom when broken | Fix |
|---|---|---|
| Jenkins ↔ agent | Builds queue forever | Label must be exactly `linux-docker` |
| SonarQube → Jenkins | Quality gate hangs 5 min | Webhook URL with internal IP **and trailing slash** |
| Jenkinsfile → credentials | Instant "could not find credentials" | IDs are case-sensitive |

---

## What's still not connected

Being straight with you about the remaining gaps:

| Gap | Fixed in |
|---|---|
| Nothing deployed to the cluster yet | Part 4 |
| `platform-ops/bootstrap.sh` not run — no namespaces, no default-deny, no monitoring | Part 4 |
| Secret Manager secrets don't exist | Part 4 |
| Alertmanager still has `REPLACE_WITH_SLACK_WEBHOOK` | Part 5 |
| Runbook URLs point at `github.com/YOUR_ORG/...` | Part 5 |
| No Ingress/Gateway — nothing publicly reachable | Part 5 |

---

## Next: Part 4 — Deploy to Kubernetes

Bootstrap the platform foundations **in the right order** (namespaces → quotas → default-deny → monitoring, before any workload), create the Secret Manager secrets, prove Workload Identity actually hands pods a GCP identity, deploy your first service by hand, then let the pipeline do it — and prove the NetworkPolicy really denies what it should.

> **Before you stop for the day:** `terraform destroy` in `environments/dev`. Jenkins config lives on the persistent disk, but the disk is deleted with the VM. If you want Jenkins config to survive, snapshot it first:
> ```bash
> $ gcloud compute disks snapshot dev-jenkins-home --zone=asia-south1-a --snapshot-names=jenkins-home-$(date +%Y%m%d)
> ```
