#!/usr/bin/env bash
#
# deploy.sh - render plain YAML with envsubst and apply it.
#
# This is the no-Helm / no-Kustomize path. envsubst is a 40-year-old GNU tool
# that substitutes ${VARS} in a file. That is genuinely all Helm's values
# mechanism does for 90% of teams.
#
# Usage:
#   ./scripts/deploy.sh dev
#   ./scripts/deploy.sh prod --dry-run
#
set -euo pipefail

ENV_NAME="${1:?usage: deploy.sh <dev|staging|prod> [--dry-run]}"
DRY_RUN="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BASE_DIR="$REPO_ROOT/k8s/base"
ENV_FILE="$REPO_ROOT/k8s/env/${ENV_NAME}.env"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: no env file at $ENV_FILE"; exit 1; }

# ---- Load environment values ----
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---- Values the pipeline injects (fail loudly if missing) ----
: "${IMAGE_URL:?IMAGE_URL not set - the pipeline must export this}"
: "${IMAGE_TAG:?IMAGE_TAG not set}"
: "${PROJECT_ID:?PROJECT_ID not set}"
export GIT_COMMIT="${GIT_COMMIT:-unknown}"
export BUILD_NUMBER="${BUILD_NUMBER:-local}"

# ---- envsubst safety ----
# Restrict substitution to OUR variables. Without the explicit list, envsubst
# would happily blank out any $VAR that Kubernetes itself uses in the YAML.
VARS='${NAMESPACE} ${ENVIRONMENT} ${REPLICAS} ${LOG_LEVEL} ${CPU_REQUEST} ${MEMORY_REQUEST} ${MEMORY_LIMIT} ${HPA_MIN} ${HPA_MAX} ${PDB_MIN_AVAILABLE} ${IMAGE_URL} ${IMAGE_TAG} ${PROJECT_ID} ${GIT_COMMIT} ${BUILD_NUMBER}'

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

echo "==> Rendering manifests for ${ENV_NAME}"
for f in "$BASE_DIR"/*.yaml; do
  out="$RENDER_DIR/$(basename "$f")"
  envsubst "$VARS" < "$f" > "$out"
  echo "    rendered $(basename "$f")"
done

# ---- Catch unsubstituted variables before the cluster does ----
if grep -rn '\${' "$RENDER_DIR" > /dev/null 2>&1; then
  echo "ERROR: unsubstituted variables remain:"
  grep -rn '\${' "$RENDER_DIR"
  exit 1
fi

# ---- Server-side validation ----
echo "==> Validating against the live API server"
kubectl apply --dry-run=server -f "$RENDER_DIR/"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  echo "==> Dry run only. Rendered output:"
  cat "$RENDER_DIR"/*.yaml
  exit 0
fi

echo "==> Applying to namespace ${NAMESPACE}"
kubectl apply -f "$RENDER_DIR/"

# ---- Wait for the rollout, and FAIL the build if it doesn't converge ----
DEPLOY_NAME="$(grep -m1 '^  name:' "$RENDER_DIR/deployment.yaml" | awk '{print $2}')"
echo "==> Waiting for rollout of ${DEPLOY_NAME}"

if ! kubectl rollout status "deployment/${DEPLOY_NAME}" \
      -n "${NAMESPACE}" --timeout=5m; then
  echo "ERROR: rollout failed. Recent events:"
  kubectl get events -n "${NAMESPACE}" \
    --sort-by=.lastTimestamp | tail -20
  echo "==> Rolling back"
  kubectl rollout undo "deployment/${DEPLOY_NAME}" -n "${NAMESPACE}"
  exit 1
fi

echo "==> Deployed ${DEPLOY_NAME}:${IMAGE_TAG} to ${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" -l "app=${DEPLOY_NAME}" -o wide
