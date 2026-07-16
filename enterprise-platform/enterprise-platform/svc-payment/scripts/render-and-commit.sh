#!/usr/bin/env bash
#
# render-and-commit.sh - the CD half of GitOps.
#
# Replaces deploy.sh in the pipeline. Instead of `kubectl apply`, this renders
# the manifests and COMMITS them to the platform-gitops repo. Argo CD notices
# and applies them.
#
# The important consequence: after this change, Jenkins needs NO cluster
# credentials at all. It writes YAML to a git repo. That is the single biggest
# security win of GitOps - your CI system stops being a path into production.
#
# Usage (from a service repo):
#   IMAGE_URL=... IMAGE_TAG=... PROJECT_ID=... ./scripts/render-and-commit.sh dev
#
set -euo pipefail

ENV_NAME="${1:?usage: render-and-commit.sh <dev|staging|prod>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BASE_DIR="$REPO_ROOT/k8s/base"
ENV_FILE="$REPO_ROOT/k8s/env/${ENV_NAME}.env"

: "${SERVICE_NAME:?SERVICE_NAME not set}"
: "${IMAGE_URL:?IMAGE_URL not set}"
: "${IMAGE_TAG:?IMAGE_TAG not set}"
: "${PROJECT_ID:?PROJECT_ID not set}"
: "${GITOPS_REPO:?GITOPS_REPO not set - e.g. github.com/org/platform-gitops.git}"
: "${GITOPS_CREDS:?GITOPS_CREDS not set - user:token}"

export GIT_COMMIT="${GIT_COMMIT:-unknown}"
export BUILD_NUMBER="${BUILD_NUMBER:-local}"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: no env file at $ENV_FILE"; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---- Render ----
# Same envsubst mechanism as before. The difference is where the output goes:
# to Git, not to the API server.
VARS='${NAMESPACE} ${ENVIRONMENT} ${REPLICAS} ${LOG_LEVEL} ${CPU_REQUEST} ${MEMORY_REQUEST} ${MEMORY_LIMIT} ${HPA_MIN} ${HPA_MAX} ${PDB_MIN_AVAILABLE} ${IMAGE_URL} ${IMAGE_TAG} ${PROJECT_ID} ${GIT_COMMIT} ${BUILD_NUMBER}'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Rendering ${SERVICE_NAME} for ${ENV_NAME}"
mkdir -p "$WORK/rendered"
for f in "$BASE_DIR"/*.yaml; do
  envsubst "$VARS" < "$f" > "$WORK/rendered/$(basename "$f")"
done

# Catch unsubstituted variables here, in CI, rather than letting broken YAML
# reach the GitOps repo where Argo CD would try to apply it.
if grep -rn '\${' "$WORK/rendered" > /dev/null 2>&1; then
  echo "ERROR: unsubstituted variables remain:"
  grep -rn '\${' "$WORK/rendered"
  exit 1
fi

# ---- Clone the GitOps repo ----
echo "==> Cloning GitOps repo"
git clone --depth 1 --quiet \
  "https://${GITOPS_CREDS}@${GITOPS_REPO}" "$WORK/gitops"

TARGET="$WORK/gitops/envs/${ENV_NAME}/${SERVICE_NAME}"
mkdir -p "$TARGET"

# Remove stale files so a deleted manifest actually disappears from Git
# (and therefore, via prune, from the cluster).
rm -f "$TARGET"/*.yaml
cp "$WORK/rendered"/*.yaml "$TARGET/"

# ---- Commit ----
cd "$WORK/gitops"
git config user.email "jenkins@platform.internal"
git config user.name  "Jenkins CI"

if git diff --quiet && git diff --staged --quiet; then
  echo "==> No manifest changes for ${SERVICE_NAME}/${ENV_NAME}. Nothing to commit."
  exit 0
fi

echo "==> Diff being committed:"
git --no-pager diff --stat
git --no-pager diff -- "envs/${ENV_NAME}/${SERVICE_NAME}/deployment.yaml" \
  | grep -E '^[-+].*image:' || true

git add "envs/${ENV_NAME}/${SERVICE_NAME}/"
git commit --quiet -m "deploy(${ENV_NAME}): ${SERVICE_NAME} ${IMAGE_TAG}

Source commit: ${GIT_COMMIT}
Build: ${BUILD_NUMBER}
Image: ${IMAGE_URL}"

# Someone else's build may have pushed while we were working.
for attempt in 1 2 3; do
  if git push --quiet origin main 2>/dev/null; then
    echo "==> Pushed to GitOps repo"
    break
  fi
  echo "    push rejected (concurrent build), rebasing (attempt ${attempt})"
  git pull --rebase --quiet origin main
  [[ $attempt -eq 3 ]] && { echo "ERROR: could not push after 3 attempts"; exit 1; }
done

echo "==> Done. Argo CD will sync ${ENV_NAME}/${SERVICE_NAME} within ~3 minutes."
echo "    Watch: argocd app get ${ENV_NAME}-${SERVICE_NAME}"
