#!/usr/bin/env bash
# =============================================================================
# fix-tooling.sh — repair the 4 tooling VMs after the Dec-2025 Jenkins changes
#
#   chmod +x fix-tooling.sh && ./fix-tooling.sh
#
# WHY THIS EXISTS
# Jenkins LTS 2.541.1 (Dec 2025) shipped two breaking changes at once:
#   1. Rotated the Debian repo signing key -> jenkins.io-2023.key is dead.
#      apt fails: NO_PUBKEY 7198F4B714ABFC68 ... repository is not signed
#   2. Raised the minimum Java to 21. Java 17 now aborts at startup:
#      "Running with Java 17 ... older than the minimum required (Java 21)"
# The startup scripts baked into your VMs predate both. This repairs the
# running machines in place. Terraform will not re-run startup scripts on an
# existing VM, so this is the fix — not `terraform apply`.
#
# Idempotent. Safe to re-run. Fixes the AGENT too, which would otherwise fail
# the same way at Part 3 Section C.
# =============================================================================
set -uo pipefail

ZONE="asia-south1-a"
PROJECT="full-kubernetas"
JAVA_HOME_21="/usr/lib/jvm/java-21-openjdk-amd64"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
step() { echo; echo "${BLD}==> $*${RST}"; }
ok()   { echo "    ${GRN}OK${RST}    $*"; }
warn() { echo "    ${YLW}WARN${RST}  $*"; }
fail() { echo "    ${RED}FAIL${RST}  $*"; }

ssh_run() {
  gcloud compute ssh "$1" --zone="$ZONE" --project="$PROJECT" \
    --tunnel-through-iap --quiet --command="$2" 2>&1
}

# -----------------------------------------------------------------------------
step "0/5  Preflight"
gcloud config set project "$PROJECT" --quiet 2>/dev/null
for vm in dev-bastion dev-jenkins-controller dev-jenkins-agent-01 dev-sonarqube; do
  if gcloud compute instances describe "$vm" --zone="$ZONE" --project="$PROJECT" \
       --format="value(status)" 2>/dev/null | grep -q RUNNING; then
    ok "$vm RUNNING"
  else
    fail "$vm not RUNNING — run terraform apply first"; exit 1
  fi
done

# -----------------------------------------------------------------------------
step "1/5  Jenkins CONTROLLER — Java 21 + 2026 signing key + install"

ssh_run dev-jenkins-controller '
set -e
echo "--- Java 21 ---"
if ! dpkg -l openjdk-21-jdk >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-21-jdk
fi
sudo update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java
java -version 2>&1 | head -1

echo "--- Jenkins 2026 signing key ---"
sudo curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  -o /usr/share/keyrings/jenkins-keyring.asc
sudo gpg --show-keys /usr/share/keyrings/jenkins-keyring.asc >/dev/null 2>&1 \
  || { echo "FATAL: key invalid. Check https://www.jenkins.io/blog/ for the current key."; exit 1; }
echo "key OK"

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list >/dev/null

echo "--- install ---"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jenkins

echo "--- pin JAVA_HOME for the unit ---"
sudo mkdir -p /etc/systemd/system/jenkins.service.d
printf "[Service]\nEnvironment=\"JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64\"\n" \
  | sudo tee /etc/systemd/system/jenkins.service.d/java21.conf >/dev/null

sudo chown -R jenkins:jenkins /var/lib/jenkins

echo "--- start ---"
sudo systemctl daemon-reload
# systemd gives up after repeated failures ("Start request repeated too
# quickly"). Without reset-failed, restart silently does nothing.
sudo systemctl reset-failed jenkins 2>/dev/null || true
sudo systemctl enable jenkins >/dev/null 2>&1
sudo systemctl restart jenkins
' | sed 's/^/    /'

echo "    waiting 30s for Jenkins to come up..."
sleep 30

STATE=$(ssh_run dev-jenkins-controller 'systemctl is-active jenkins' | tr -d '\r\n ')
if [[ "$STATE" == "active" ]]; then
  ok "jenkins is ACTIVE"
else
  fail "jenkins is '$STATE'. Last 15 log lines:"
  ssh_run dev-jenkins-controller 'sudo journalctl -u jenkins --no-pager -n 15' | sed 's/^/      /'
fi

# -----------------------------------------------------------------------------
step "2/5  Jenkins AGENT — Java 21 (would break Part 3 Section C otherwise)"

ssh_run dev-jenkins-agent-01 '
set -e
if ! dpkg -l openjdk-21-jdk >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-21-jdk
fi
sudo update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java
echo -n "java:    "; java -version 2>&1 | head -1
echo -n "docker:  "; sudo -u jenkins docker ps >/dev/null 2>&1 && echo "works as jenkins user" || echo "BROKEN"
echo -n "kubectl: "; which kubectl || echo MISSING
echo -n "trivy:   "; which trivy || echo MISSING
echo -n "scanner: "; which sonar-scanner || echo MISSING
echo -n "envsubst:"; which envsubst || echo MISSING
echo -n "node:    "; node --version 2>/dev/null || echo MISSING
' | sed 's/^/    /'

# -----------------------------------------------------------------------------
step "3/5  SonarQube — containers up?"

ssh_run dev-sonarqube '
sudo docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null || echo "docker not ready"
echo -n "http: "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://localhost:9000 || echo "not responding yet"
free -h | head -2
' | sed 's/^/    /'
warn "SonarQube is slow to boot (Elasticsearch). 000 or 503 right after apply is normal."

# -----------------------------------------------------------------------------
step "4/5  Your real IPs — Part 3 hardcodes different ones"

CTRL=$(gcloud compute instances describe dev-jenkins-controller --zone="$ZONE" \
  --format="value(networkInterfaces[0].networkIP)" 2>/dev/null)
AGENT=$(gcloud compute instances describe dev-jenkins-agent-01 --zone="$ZONE" \
  --format="value(networkInterfaces[0].networkIP)" 2>/dev/null)
SONAR=$(gcloud compute instances describe dev-sonarqube --zone="$ZONE" \
  --format="value(networkInterfaces[0].networkIP)" 2>/dev/null)

cat <<EOF
    ┌──────────────────────┬───────────────┬───────────────┐
    │ host                 │ Part 3 says   │ YOURS         │
    ├──────────────────────┼───────────────┼───────────────┤
    │ jenkins-controller   │ 10.10.16.3    │ ${CTRL}
    │ jenkins-agent-01     │ 10.10.16.4    │ ${AGENT}
    │ sonarqube            │ 10.10.16.5    │ ${SONAR}
    └──────────────────────┴───────────────┴───────────────┘

    Substitute YOURS everywhere Part 3 shows an IP:
      Section B3  Jenkins URL      -> http://${CTRL}:8080/
      Section C5  agent Host       -> ${AGENT}
      Section D4  Sonar webhook    -> http://${CTRL}:8080/sonarqube-webhook/
      Section E   sonarqube-url    -> http://${SONAR}:9000
      Section F   Server URL       -> http://${SONAR}:9000

    Section D4 is the one that matters most: get it wrong and your quality
    gate hangs for 5 minutes and times out with no useful error.
EOF

# -----------------------------------------------------------------------------
step "5/5  Unlock password"

PW=$(ssh_run dev-jenkins-controller 'sudo cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null' | tr -d '\r\n ')
if [[ -n "$PW" && ${#PW} -ge 30 ]]; then
  echo
  echo "    ${BLD}${GRN}${PW}${RST}"
  echo
  ok "save that — it is Part 3 Section B1"
else
  warn "no password yet. Either Jenkins is still starting, or setup is already complete."
fi

# -----------------------------------------------------------------------------
echo
echo "${BLD}==> Next: open the tunnel (Part 3 Section A)${RST}"
cat <<EOF

    gcloud compute ssh dev-bastion --zone=${ZONE} --tunnel-through-iap -- \\
      -L 8080:${CTRL}:8080 \\
      -L 9000:${SONAR}:9000 \\
      -o ServerAliveInterval=30 -N

    Leave that running. In a SECOND terminal:

    curl -s -o /dev/null -w "jenkins:%{http_code}\n" http://localhost:8080/login
    curl -s -o /dev/null -w "sonar:%{http_code}\n"   http://localhost:9000

    Both 200 -> browse to http://localhost:8080 and continue at Part 3 Section B2.

EOF
