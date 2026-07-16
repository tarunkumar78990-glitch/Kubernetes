#!/usr/bin/env bash
# =============================================================================
# setup-dev.sh — one-shot Part 2 for project full-kubernetas (free trial)
#
#   chmod +x setup-dev.sh && ./setup-dev.sh
#
# Idempotent. Safe to re-run after a failure — Terraform reconciles.
# Every step prints what it is doing and stops on the first real error.
# =============================================================================
set -euo pipefail

PROJECT_ID="full-kubernetas"
BUCKET="full-kubernetas-tfstate"
REGION="asia-south1"
ZONE="asia-south1-a"
ENV_DIR="${HOME}/enterprise-platform/platform-infrastructure/environments/dev"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
step() { echo; echo "${BLD}==> $*${RST}"; }
ok()   { echo "    ${GRN}OK${RST}  $*"; }
warn() { echo "    ${YLW}!!${RST}  $*"; }
die()  { echo "    ${RED}ERROR${RST} $*"; exit 1; }

# -----------------------------------------------------------------------------
step "0/8  Preflight"

[[ -d "$ENV_DIR" ]] || die "$ENV_DIR not found. Are you on the right box?"
cd "$ENV_DIR"
ok "working in $ENV_DIR"

command -v terraform >/dev/null || die "terraform not installed"
command -v gcloud    >/dev/null || die "gcloud not installed"
ok "terraform $(terraform version -json | grep -oP '"terraform_version":"\K[^"]+')"

gcloud config set project "$PROJECT_ID" --quiet
ok "project set to $PROJECT_ID"

# The artifact-registry fix from Errata 2+3. If this file still has a heredoc
# description or a toset(), you are on an old copy and apply WILL fail.
VARS_TF="../../modules/artifact-registry/variables.tf"
if grep -q "EOT" "$VARS_TF" 2>/dev/null; then
  die "$VARS_TF still has a heredoc description — you have the pre-Errata-3 copy.
       Re-download the zip, or apply the fix from Part 0 Errata 3."
fi
if grep -q "toset(var.writer_members)" ../../modules/artifact-registry/main.tf 2>/dev/null; then
  die "modules/artifact-registry/main.tf still uses toset() — pre-Errata-2 copy."
fi
ok "artifact-registry module has the Errata 2+3 fixes"

# -----------------------------------------------------------------------------
step "1/8  Enable required APIs (idempotent, ~1 min)"

gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iap.googleapis.com \
  --project="$PROJECT_ID" --quiet
ok "APIs enabled"

# -----------------------------------------------------------------------------
step "2/8  Check quotas against what this profile needs"

echo "    free-trial profile needs: 6.75 vCPU, 0 SSD_TOTAL_GB, ~280 DISKS_TOTAL_GB"
echo
gcloud compute regions describe "$REGION" \
  --format="table[box](quotas.metric,quotas.limit,quotas.usage)" 2>/dev/null \
  | grep -E "METRIC|CPUS|SSD_TOTAL_GB|DISKS_TOTAL_GB|IN_USE_ADDRESSES" || true

CPU_LIMIT=$(gcloud compute regions describe "$REGION" \
  --format="value(quotas.limit)" --flatten="quotas[]" \
  --filter="quotas.metric=CPUS" 2>/dev/null | head -1 | cut -d. -f1)
echo
if [[ -n "${CPU_LIMIT:-}" ]] && (( CPU_LIMIT < 7 )); then
  warn "CPUS limit is ${CPU_LIMIT}. This profile needs 6.75 and may not fit."
  warn "If apply fails on CPU: drop the tooling VMs (see the note at the end)."
else
  ok "CPUS limit ${CPU_LIMIT:-unknown} — 6.75 needed"
fi

# -----------------------------------------------------------------------------
step "3/8  Clear any partial failed apply"

if [[ -f .terraform/terraform.tfstate ]] || [[ -d .terraform ]]; then
  terraform destroy -auto-approve 2>/dev/null || warn "nothing to destroy (fine)"
  ok "clean slate"
else
  ok "no prior state"
fi

# -----------------------------------------------------------------------------
step "4/8  State bucket"

if gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ok "gs://${BUCKET} already exists"
else
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="$PROJECT_ID" --location="$REGION" --uniform-bucket-level-access
  ok "created gs://${BUCKET}"
fi
gcloud storage buckets update "gs://${BUCKET}" --versioning >/dev/null
ok "versioning on — this is your undo button"

# -----------------------------------------------------------------------------
step "5/8  backend.tf"

# Quoted heredoc: nothing here should expand.
cat > backend.tf << 'TFEOF'
terraform {
  backend "gcs" {
    bucket = "full-kubernetas-tfstate"
    prefix = "env/dev"
  }
}
TFEOF
ok "backend -> gs://${BUCKET}/env/dev"

# -----------------------------------------------------------------------------
step "6/8  terraform.tfvars (free-trial profile)"

MYIP="$(curl -s --max-time 10 ifconfig.me || true)"
[[ -n "$MYIP" ]] || die "could not detect public IP. Set cidr_block by hand."
ok "detected public IP: ${MYIP}"

# UNquoted heredoc: ${MYIP} must expand. The others are literal because
# nothing else in here is a shell variable.
cat > terraform.tfvars << TFEOF
project_id = "${PROJECT_ID}"
region     = "${REGION}"
zone       = "${ZONE}"

authorized_cidrs = [
  {
    cidr_block   = "${MYIP}/32"
    display_name = "terraform-vm"
  },
  {
    cidr_block   = "10.10.16.0/24"
    display_name = "tooling-subnet"
  },
]

# ---- FREE TRIAL PROFILE: 6.75 vCPU, 0 SSD ----
# pd-standard counts against DISKS_TOTAL_GB, not SSD_TOTAL_GB.
# That one line takes SSD from 720GB to 0.
disk_type         = "pd-standard"

# 2 nodes, dedicated cores, 16GB across the cluster. e2-medium would save
# 2 vCPU but leave only ~5.8GB allocatable — not enough for 10 services
# plus Prometheus plus Argo CD later.
machine_type      = "e2-standard-2"
node_disk_size_gb = 50

# Shared-core E2 consume FRACTIONAL vCPU quota:
#   e2-micro 0.25 | e2-small 0.5 | e2-medium 1.0
jenkins_controller_machine_type = "e2-small"
jenkins_agent_machine_type      = "e2-medium"
sonarqube_machine_type          = "e2-medium"

jenkins_controller_disk_gb = 20
jenkins_home_disk_gb       = 30
jenkins_agent_disk_gb      = 60
sonarqube_disk_gb          = 20
sonar_data_disk_gb         = 30
TFEOF
ok "terraform.tfvars written"

grep -q "terraform.tfvars" ../../.gitignore 2>/dev/null \
  && ok "terraform.tfvars is gitignored" \
  || warn "terraform.tfvars may not be gitignored — check before committing"

# -----------------------------------------------------------------------------
step "7/8  init + plan"

terraform init -reconfigure -input=false
terraform fmt -recursive ../.. >/dev/null 2>&1 || true
terraform validate || die "validate failed"
ok "config is valid"

terraform plan -out=tfplan -input=false | tail -25

echo
echo "    ${BLD}Quota sanity check — every disk must be pd-standard:${RST}"
terraform show -json tfplan 2>/dev/null \
  | grep -oP '"(disk_)?type":"pd-[a-z]+"' | sort | uniq -c || true

if terraform show -json tfplan 2>/dev/null | grep -q '"pd-balanced"'; then
  die "pd-balanced still present — tfvars did not take. SSD quota will fail."
fi
ok "no pd-balanced anywhere — SSD_TOTAL_GB usage will be 0"

NODES=$(terraform show -json tfplan 2>/dev/null | grep -oP '"node_count":\K\d+' | head -1)
[[ "${NODES:-2}" == "2" ]] && ok "node_count = 2" || warn "node_count = ${NODES}"

# -----------------------------------------------------------------------------
step "8/8  apply"

echo "    This takes 12-18 minutes. The GKE cluster alone is 8-12."
echo "    That is not a hang."
echo
read -rp "    Proceed? [y/N] " yn
[[ "$yn" == "y" || "$yn" == "Y" ]] || { echo "    aborted. Plan saved as ./tfplan"; exit 0; }

terraform apply tfplan

# -----------------------------------------------------------------------------
step "Verify"

eval "$(terraform output -raw kubectl_connect_command)"
echo
echo "    Nodes (must be exactly 2):"
kubectl get nodes
COUNT=$(kubectl get nodes --no-headers | wc -l)
[[ "$COUNT" == "2" ]] && ok "exactly 2 nodes" || warn "got ${COUNT} nodes, expected 2"

echo
echo "    Tooling VMs (EXTERNAL_IP must be empty for all four):"
gcloud compute instances list --project="$PROJECT_ID"

echo
echo "    Dataplane V2 / Cilium (enforces your NetworkPolicies):"
kubectl get pods -n kube-system -l k8s-app=cilium 2>/dev/null | head -3 \
  || kubectl get pods -n kube-system 2>/dev/null | grep -i anetd | head -3 \
  || warn "no anetd/cilium pods found"

echo
echo "${GRN}${BLD}==> Part 2 complete.${RST}"
cat << 'EONOTE'

    NEXT:  Part 3 (Jenkins + SonarQube). Startup scripts are still running —
           give them 5-10 minutes before you tunnel in.

    STOP FOR THE DAY:
           gcloud compute disks snapshot dev-jenkins-home --zone=asia-south1-a \
             --snapshot-names=jenkins-home-$(date +%Y%m%d)
           terraform destroy

    IF APPLY FAILED ON CPU QUOTA:
           Your CPUS limit is below 6.75. Drop the four tooling VMs and run
           the cluster only (4.00 vCPU) — you lose Part 3 but keep Parts 4-6,
           which is the more interesting half:
             # comment out the `module "tooling"` block in main.tf
             terraform apply

    IF SONARQUBE RESTART-LOOPS (4GB is its documented floor):
           gcloud compute ssh dev-sonarqube --zone=asia-south1-a --tunnel-through-iap
           sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
           sudo mkswap /swapfile && sudo swapon /swapfile
           cd /opt && sudo docker compose up -d

EONOTE
